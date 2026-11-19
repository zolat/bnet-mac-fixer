import Foundation

/// Locale-independent formatting shared by the CLI and menu bar.
public enum Format {
    /// "45s", "12m", "6h 12m", "2d 3h".
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }

    /// 2740 -> "2,740".
    public static func count(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return n < 0 ? "-" + out : out
    }

    /// "1 sleep", "3 sleeps".
    public static func plural(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count(n)) \(n == 1 ? singular : plural ?? singular + "s")"
    }

    public static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}
