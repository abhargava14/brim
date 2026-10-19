import Foundation

/// Small, forgiving accessors over `JSONSerialization` output.
enum JSON {
    static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func string(_ dict: [String: Any]?, _ key: String) -> String? {
        guard let value = dict?[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// A non-negative integer, or 0 when missing or malformed.
    static func int(_ dict: [String: Any]?, _ key: String) -> Int64 {
        guard let number = dict?[key] as? NSNumber else { return 0 }
        let value = number.int64Value
        return value > 0 ? value : 0
    }

    static func double(_ dict: [String: Any]?, _ key: String) -> Double? {
        guard let number = dict?[key] as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return isoFractional.date(from: text) ?? isoPlain.date(from: text)
    }

    /// A number given as a JSON number or as a numeric string (protobuf JSON writes 64-bit ints as strings).
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, !(value is Bool) { return number.doubleValue.isFinite ? number.doubleValue : nil }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// `2026-11-01`, an ISO 8601 timestamp, or Unix seconds/milliseconds.
    static func dayOrISODate(_ value: Any?) -> Date? {
        if let text = value as? String {
            if let date = date(text) { return date }
            if let date = dayFormatter.date(from: text) { return date }
            guard let seconds = Double(text) else { return nil }
            return seconds > 100_000_000_000 ? Date(timeIntervalSince1970: seconds / 1000) : Date(timeIntervalSince1970: seconds)
        }
        if let seconds = number(value) {
            return seconds > 100_000_000_000 ? Date(timeIntervalSince1970: seconds / 1000) : Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    /// The first value stored under `key`, searching nested objects and arrays depth-first.
    static func find(_ key: String, in value: Any) -> Any? {
        if let dict = value as? [String: Any] {
            if let hit = dict[key] { return hit }
            for child in dict.values {
                if let hit = find(key, in: child) { return hit }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let hit = find(key, in: child) { return hit }
            }
        }
        return nil
    }

    /// Unix seconds as a date, or nil when missing or implausible.
    static func unixDate(_ dict: [String: Any]?, _ key: String) -> Date? {
        guard let seconds = double(dict, key), seconds > 0, seconds < 32_503_680_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// The last folder of a working directory, e.g. `/Users/me/code/app` -> `app`.
public func projectName(fromPath path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    let name = trimmed.split(separator: "/").last.map(String.init)
    return name?.isEmpty == false ? name : nil
}
