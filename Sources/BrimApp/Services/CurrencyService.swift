import Combine
import Foundation
import IslandCore

/// Daily exchange rates for the Units tab, kept on disk so conversions work offline.
@MainActor
final class CurrencyService: ObservableObject {
    @Published private(set) var rates: ExchangeRates?
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    private let file = JSONFile<ExchangeRates>("currency-rates.json", directory: LocalData.directory)

    init() {
        rates = file.load()
        if AppSettings.isSnapshot { rates = Self.sample }
    }

    /// Fetches new rates when the saved ones are missing or older than 12 hours.
    func refreshIfNeeded() {
        guard !AppSettings.isSnapshot, !loading, rates?.isStale() ?? true else { return }
        refresh()
    }

    func refresh() {
        loading = true
        Task {
            defer { loading = false }
            do {
                let (data, response) = try await URLSession.shared.data(from: ExchangeRates.ratesURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200, var next = ExchangeRates.parseRates(data) else {
                    failed = true
                    return
                }
                if let (names, _) = try? await URLSession.shared.data(from: ExchangeRates.currenciesURL) {
                    let extra = ExchangeRates.parseCurrencies(names)
                    next.names = extra.names
                    next.symbols = extra.symbols
                } else if let old = rates {
                    next.names = old.names
                    next.symbols = old.symbols
                }
                rates = next
                failed = false
                file.save(next)
            } catch {
                failed = true
            }
        }
    }

    static let sample = ExchangeRates(
        base: "EUR",
        rates: ["USD": 1.08, "INR": 106.27, "GBP": 0.837, "JPY": 175.51, "CAD": 1.566, "AUD": 1.594, "CHF": 0.923,
                "CNY": 7.466, "SGD": 1.452, "AED": 4.121],
        names: ["USD": "United States Dollar", "EUR": "Euro", "INR": "Indian Rupee", "GBP": "British Pound", "JPY": "Japanese Yen",
                "CAD": "Canadian Dollar", "AUD": "Australian Dollar", "CHF": "Swiss Franc", "CNY": "Chinese Yuan",
                "SGD": "Singapore Dollar", "AED": "UAE Dirham"],
        symbols: ["USD": "$", "EUR": "€", "INR": "₹", "GBP": "£", "JPY": "¥"],
        date: "2026-10-23", fetchedAt: Date())
}
