import Foundation

/// Quick conversions with Foundation's `Measurement`, plus a parser for "5 km to mi".
public enum UnitCategory: String, CaseIterable, Identifiable, Sendable {
    case length, mass, temperature, volume, speed, area, data, time

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    /// Units offered for this category: (symbol shown, display name, Foundation unit).
    public var units: [UnitChoice] {
        switch self {
        case .length:
            return [.init("mm", "Millimetres", UnitLength.millimeters), .init("cm", "Centimetres", UnitLength.centimeters),
                    .init("m", "Metres", UnitLength.meters), .init("km", "Kilometres", UnitLength.kilometers),
                    .init("in", "Inches", UnitLength.inches), .init("ft", "Feet", UnitLength.feet),
                    .init("yd", "Yards", UnitLength.yards), .init("mi", "Miles", UnitLength.miles)]
        case .mass:
            return [.init("g", "Grams", UnitMass.grams), .init("kg", "Kilograms", UnitMass.kilograms),
                    .init("oz", "Ounces", UnitMass.ounces), .init("lb", "Pounds", UnitMass.pounds),
                    .init("st", "Stones", UnitMass.stones), .init("t", "Tonnes", UnitMass.metricTons)]
        case .temperature:
            return [.init("°C", "Celsius", UnitTemperature.celsius), .init("°F", "Fahrenheit", UnitTemperature.fahrenheit),
                    .init("K", "Kelvin", UnitTemperature.kelvin)]
        case .volume:
            return [.init("ml", "Millilitres", UnitVolume.milliliters), .init("l", "Litres", UnitVolume.liters),
                    .init("tsp", "Teaspoons", UnitVolume.teaspoons), .init("tbsp", "Tablespoons", UnitVolume.tablespoons),
                    .init("cup", "Cups", UnitVolume.cups), .init("floz", "Fluid ounces", UnitVolume.fluidOunces),
                    .init("gal", "Gallons", UnitVolume.gallons)]
        case .speed:
            return [.init("km/h", "Kilometres an hour", UnitSpeed.kilometersPerHour), .init("mph", "Miles an hour", UnitSpeed.milesPerHour),
                    .init("m/s", "Metres a second", UnitSpeed.metersPerSecond), .init("kn", "Knots", UnitSpeed.knots)]
        case .area:
            return [.init("m²", "Square metres", UnitArea.squareMeters), .init("km²", "Square kilometres", UnitArea.squareKilometers),
                    .init("ft²", "Square feet", UnitArea.squareFeet), .init("ac", "Acres", UnitArea.acres),
                    .init("ha", "Hectares", UnitArea.hectares)]
        case .data:
            return [.init("B", "Bytes", UnitInformationStorage.bytes), .init("KB", "Kilobytes", UnitInformationStorage.kilobytes),
                    .init("MB", "Megabytes", UnitInformationStorage.megabytes), .init("GB", "Gigabytes", UnitInformationStorage.gigabytes),
                    .init("TB", "Terabytes", UnitInformationStorage.terabytes), .init("Mb", "Megabits", UnitInformationStorage.megabits)]
        case .time:
            return [.init("s", "Seconds", UnitDuration.seconds), .init("min", "Minutes", UnitDuration.minutes),
                    .init("h", "Hours", UnitDuration.hours)]
        }
    }
}

public struct UnitChoice: Hashable, Identifiable, Sendable {
    public let symbol: String
    public let name: String
    public let unit: Dimension

    public var id: String { symbol }

    init(_ symbol: String, _ name: String, _ unit: Dimension) {
        self.symbol = symbol
        self.name = name
        self.unit = unit
    }

    public static func == (a: UnitChoice, b: UnitChoice) -> Bool { a.symbol == b.symbol }
    public func hash(into hasher: inout Hasher) { hasher.combine(symbol) }
}

public enum UnitConverter {
    public static func convert(_ value: Double, from: UnitChoice, to: UnitChoice) -> Double {
        Measurement(value: value, unit: from.unit).converted(to: to.unit).value
    }

    /// Up to 6 significant digits, no trailing zeros: 3.10686, 1200, 0.000254.
    public static func format(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        if value != 0, abs(value) < 0.0001 || abs(value) >= 1e12 { return String(format: "%.4g", value) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumSignificantDigits = 6
        formatter.usesSignificantDigits = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Finds a unit by symbol or name in any category ("km", "miles", "f", "celsius").
    public static func find(_ text: String) -> (UnitCategory, UnitChoice)? {
        let key = text.lowercased().trimmingCharacters(in: .whitespaces)
        let aliases = ["c": "°c", "f": "°f", "celsius": "°c", "fahrenheit": "°f", "kmh": "km/h", "kph": "km/h",
                       "lbs": "lb", "pound": "lb", "kilo": "kg", "kilos": "kg", "litre": "l", "liter": "l",
                       "liters": "l", "litres": "l", "meter": "m", "meters": "m", "feet": "ft", "foot": "ft",
                       "mile": "mi", "miles": "mi", "inch": "in", "inches": "in", "hour": "h", "hours": "h",
                       "minute": "min", "minutes": "min", "second": "s", "seconds": "s"]
        let wanted = aliases[key] ?? key
        for category in UnitCategory.allCases {
            if let choice = category.units.first(where: { $0.symbol.lowercased() == wanted || $0.name.lowercased() == wanted }) {
                return (category, choice)
            }
        }
        return nil
    }

    /// Parses "5 km to mi", "72f in c", "3.5 kg". Returns value, category and units (target may be nil).
    public static func parse(_ text: String) -> (value: Double, category: UnitCategory, from: UnitChoice, to: UnitChoice?)? {
        let lowered = text.lowercased()
        let pieces = lowered.components(separatedBy: CharacterSet(charactersIn: " ")).filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return nil }
        // Split a leading number from a glued unit: "72f", "5km".
        var tokens: [String] = []
        for piece in pieces {
            if let index = piece.firstIndex(where: { !($0.isNumber || $0 == "." || $0 == "-" || $0 == ",") }), index != piece.startIndex,
               Double(piece[..<index].replacingOccurrences(of: ",", with: "")) != nil {
                tokens.append(String(piece[..<index]))
                tokens.append(String(piece[index...]))
            } else {
                tokens.append(piece)
            }
        }
        guard let value = Double(tokens[0].replacingOccurrences(of: ",", with: "")), tokens.count >= 2 else { return nil }
        var rest = Array(tokens.dropFirst())
        var targetWords: [String] = []
        if let split = rest.firstIndex(where: { $0 == "to" || $0 == "in" || $0 == "=" || $0 == "->" }) {
            targetWords = Array(rest[(split + 1)...])
            rest = Array(rest[..<split])
        }
        guard let (category, from) = find(rest.joined(separator: " ")) else { return nil }
        var to: UnitChoice?
        if !targetWords.isEmpty, let (targetCategory, target) = find(targetWords.joined(separator: " ")), targetCategory == category {
            to = target
        }
        return (value, category, from, to)
    }
}
