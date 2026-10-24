import Foundation

/// Exchange rates against one base currency, from Frankfurter (open data, no key;
/// https://api.frankfurter.dev/v2). Saved so conversions work offline with the last rates.
public struct ExchangeRates: Codable, Equatable, Sendable {
    public var base: String
    /// Quote code → units of that currency for one unit of `base`.
    public var rates: [String: Double]
    /// Code → name ("Indian Rupee").
    public var names: [String: String]
    /// Code → symbol ("₹").
    public var symbols: [String: String]
    /// Newest rate date in the set ("2026-10-25").
    public var date: String
    public var fetchedAt: Date

    public init(base: String, rates: [String: Double], names: [String: String] = [:], symbols: [String: String] = [:],
                date: String = "", fetchedAt: Date = Date()) {
        self.base = base
        self.rates = rates
        self.names = names
        self.symbols = symbols
        self.date = date
        self.fetchedAt = fetchedAt
    }

    public static let ratesURL = URL(string: "https://api.frankfurter.dev/v2/rates?base=EUR")!
    public static let currenciesURL = URL(string: "https://api.frankfurter.dev/v2/currencies")!

    /// The ones most people want, shown as quick picks.
    public static let popular = ["USD", "EUR", "INR", "GBP", "JPY", "CAD", "AUD", "CHF", "CNY", "SGD", "AED"]

    /// Every code with a rate, popular first, then alphabetical.
    public var codes: [String] {
        let all = Set(rates.keys).union([base])
        return Self.popular.filter(all.contains) + all.subtracting(Self.popular).sorted()
    }

    /// Converts between any two codes through the base. Nil if either is unknown.
    public func convert(_ amount: Double, from: String, to: String) -> Double? {
        guard let a = rate(from), let b = rate(to), a > 0 else { return nil }
        return amount / a * b
    }

    func rate(_ code: String) -> Double? {
        let code = code.uppercased()
        return code == base ? 1 : rates[code]
    }

    public func name(_ code: String) -> String { names[code.uppercased()] ?? code.uppercased() }

    /// Older than a day: refresh when online.
    public func isStale(now: Date = Date()) -> Bool { now.timeIntervalSince(fetchedAt) > 12 * 3600 }

    /// Reads `/v2/rates?base=…`: an array of `{date, base, quote, rate}`.
    public static func parseRates(_ data: Data) -> ExchangeRates? {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !rows.isEmpty else { return nil }
        var rates: [String: Double] = [:]
        var base = "EUR"
        var newest = ""
        for row in rows {
            guard let quote = row["quote"] as? String, let rate = (row["rate"] as? NSNumber)?.doubleValue, rate > 0 else { continue }
            rates[quote.uppercased()] = rate
            if let b = row["base"] as? String { base = b.uppercased() }
            if let date = row["date"] as? String, date > newest { newest = date }
        }
        guard !rates.isEmpty else { return nil }
        return ExchangeRates(base: base, rates: rates, date: newest)
    }

    /// Reads `/v2/currencies` into names and symbols.
    public static func parseCurrencies(_ data: Data) -> (names: [String: String], symbols: [String: String]) {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return ([:], [:]) }
        var names: [String: String] = [:], symbols: [String: String] = [:]
        for row in rows {
            guard let code = (row["iso_code"] as? String)?.uppercased() else { continue }
            if let name = row["name"] as? String { names[code] = name }
            if let symbol = row["symbol"] as? String { symbols[code] = symbol }
        }
        return (names, symbols)
    }

    /// Symbols people type instead of codes.
    static let symbolCodes: [String: String] = ["$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₹": "INR", "₩": "KRW",
                                                "₽": "RUB", "₺": "TRY", "₪": "ILS", "฿": "THB", "₫": "VND", "₱": "PHP"]
    static let wordCodes: [String: String] = ["dollar": "USD", "dollars": "USD", "euro": "EUR", "euros": "EUR",
                                              "pound": "GBP", "pounds": "GBP", "yen": "JPY", "rupee": "INR", "rupees": "INR",
                                              "rs": "INR", "yuan": "CNY", "franc": "CHF", "francs": "CHF", "dirham": "AED"]

    /// Parses "100 usd to inr", "$20 in €", "2500 rupees". Returns amount and codes (target may be nil).
    public func parse(_ text: String) -> (amount: Double, from: String, to: String?)? {
        var cleaned = text.lowercased()
        for (symbol, code) in Self.symbolCodes { cleaned = cleaned.replacingOccurrences(of: symbol, with: " \(code.lowercased()) ") }
        let tokens = cleaned.split { $0 == " " }.map(String.init)
        guard let numberIndex = tokens.firstIndex(where: { Double($0.replacingOccurrences(of: ",", with: "")) != nil }),
              let amount = Double(tokens[numberIndex].replacingOccurrences(of: ",", with: "")) else { return nil }
        let words = tokens.enumerated().filter { $0.offset != numberIndex && !["to", "in", "=", "->", "into"].contains($0.element) }.map(\.element)
        let codes = words.compactMap(code(for:))
        guard let from = codes.first else { return nil }
        return (amount, from, codes.count > 1 ? codes[1] : nil)
    }

    func code(for word: String) -> String? {
        if let mapped = Self.wordCodes[word] { return mapped }
        let upper = word.uppercased()
        return upper.count == 3 && rate(upper) != nil ? upper : nil
    }

    /// "₹8,312.40" or "8,312.40 XYZ" with sensible decimals (none for JPY-like large values).
    public func format(_ amount: Double, _ code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = amount >= 1000 ? 0 : amount >= 1 ? 2 : 4
        formatter.minimumFractionDigits = amount >= 1000 ? 0 : amount >= 1 ? 2 : 0
        let number = formatter.string(from: NSNumber(value: amount)) ?? String(amount)
        if let symbol = symbols[code.uppercased()], symbol.count <= 2, symbol != code { return symbol + number }
        return number + " " + code.uppercased()
    }
}
