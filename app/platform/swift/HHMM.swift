import Foundation

/// Parsing + validation for a daily "HH:MM" time (1-2 digit hour, 2-digit
/// minute), range-checked to a real clock time (00:00-23:59). The single Swift
/// home for HH:MM, mirroring `triggers.parseTimeOfDay` on the Lua side -- so the
/// host never accepts a time the engine would reject ("29:99", "8:5").
enum HHMM {
    /// (hour, minute) for a valid, in-range HH:MM; nil for anything malformed
    /// or out of range.
    static func parse(_ s: String) -> (hour: Int, minute: Int)? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// Whether `s` is a valid 24-hour HH:MM.
    static func isValid(_ s: String) -> Bool { parse(s) != nil }

    /// Minutes since midnight for a valid HH:MM; nil otherwise.
    static func minutesOfDay(_ s: String) -> Int? {
        guard let t = parse(s) else { return nil }
        return t.hour * 60 + t.minute
    }
}
