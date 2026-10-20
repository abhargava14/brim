import Foundation

/// Marketing / CFBundleShortVersionString. Bump when cutting a GitHub Release.
public enum BrimVersion {
    public static let string = "0.2.1"

    /// Compare dotted versions (`1.2.3`, optional pre-release suffix ignored for ordering).
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let left = components(a)
        let right = components(b)
        let count = max(left.count, right.count)
        for i in 0..<count {
            let l = i < left.count ? left[i] : 0
            let r = i < right.count ? right[i] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func components(_ version: String) -> [Int] {
        let core = version.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? version
        return core.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    }
}
