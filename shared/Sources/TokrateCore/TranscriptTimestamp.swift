import Foundation

/// Parses the RFC 3339 / ISO-8601 timestamps of Codex, Claude Code and Grok Build transcripts.
///
/// A replay parses one or more timestamps per transcript line, and `ISO8601DateFormatter` (even a
/// shared one) costs far more than the rest of the line's work, so the canonical shapes are scanned
/// by hand. Anything else goes to the formatter, so no string the formatter accepts is ever rejected.
enum TranscriptTimestamp {
    /// `ISO8601DateFormatter` is documented thread-safe and these are never mutated after creation, so
    /// one instance per option set is shared (it is not `Sendable`, hence `nonisolated(unsafe)`).
    private nonisolated(unsafe) static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private nonisolated(unsafe) static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ string: String) -> Date? {
        var string = string
        // Contiguous after bridging, so the scan never walks `Character`s.
        if let date = string.withUTF8({ scan($0) }) { return date }
        return fractionalFormatter.date(from: string) ?? wholeSecondFormatter.date(from: string)
    }

    /// Accepts only `YYYY-MM-DDTHH:MM:SS[.f{1,9}](Z|±HH:MM|±HHMM)` naming a real date and time from the
    /// year 1600 on (the formatter's Gregorian calendar switches to Julian before 1583). Nil leaves the
    /// string to the formatter, which is more lenient (trailing text, a missing separator, February 30).
    private static func scan(_ bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        var index = 0
        func digits(_ count: Int) -> Int? {
            guard index + count <= bytes.count else { return nil }
            var value = 0
            for offset in 0..<count {
                let digit = Int(bytes[index + offset]) &- 0x30
                guard digit >= 0, digit <= 9 else { return nil }
                value = value * 10 + digit
            }
            index += count
            return value
        }
        func skip(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        guard let year = digits(4), year >= 1600, skip(0x2D),
              let month = digits(2), (1...12).contains(month), skip(0x2D),
              let day = digits(2), day >= 1, day <= daysInMonth(year: year, month: month), skip(0x54),
              let hour = digits(2), hour < 24, skip(0x3A),
              let minute = digits(2), minute < 60, skip(0x3A),
              let second = digits(2), second < 60
        else { return nil }

        var fraction = 0.0
        if skip(0x2E) {
            var numerator = 0
            var count = 0
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                guard count < 9 else { return nil }
                numerator = numerator * 10 + Int(bytes[index] - 0x30)
                count += 1
                index += 1
            }
            guard count > 0 else { return nil }
            fraction = Double(numerator) / powersOfTen[count]
        }

        var offsetSeconds = 0
        if skip(0x5A) {
            // UTC.
        } else if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
            let sign = bytes[index] == 0x2B ? 1 : -1
            index += 1
            guard let offsetHour = digits(2), offsetHour < 24 else { return nil }
            _ = skip(0x3A)
            guard let offsetMinute = digits(2), offsetMinute < 60 else { return nil }
            offsetSeconds = sign * (offsetHour * 3_600 + offsetMinute * 60)
        } else {
            return nil
        }
        guard index == bytes.count else { return nil }

        let wholeSeconds = daysFromCivil(year: year, month: month, day: day) * 86_400
            + hour * 3_600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(wholeSeconds) + fraction)
    }

    private static let powersOfTen: [Double] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000]

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Days from 1970-01-01 to the proleptic Gregorian date (Howard Hinnant's `days_from_civil`).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = y / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
