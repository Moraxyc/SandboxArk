/// One instant rendered both ways SandboxArk/1 needs it: the DOS date/time fields a ZIP
/// member carries and the RFC 3339 UTC string the hash index records. DOS fields clamp
/// to 1980-2107; the RFC 3339 string keeps the real instant.
struct SKZipTimestamp: Equatable, Sendable {
    let dosDate: UInt16
    let dosTime: UInt16
    let rfc3339: String

    /// Used when a source instant cannot be represented, so headers stay well formed.
    static let dosFloor = SKZipTimestamp(dosDate: 0x0021, dosTime: 0, rfc3339: "1980-01-01T00:00:00Z")
    private static let dosCeilingDate: UInt16 = (127 << 9) | (12 << 5) | 31
    private static let dosCeilingTime: UInt16 = (23 << 11) | (59 << 5) | 29

    init(dosDate: UInt16, dosTime: UInt16, rfc3339: String) {
        self.dosDate = dosDate
        self.dosTime = dosTime
        self.rfc3339 = rfc3339
    }

    init?(_ timestamp: SKFileTimestamp) {
        self.init(seconds: timestamp.seconds)
    }

    /// Representable range is 1970-01-01 through 9999-12-31; outside it is unrepresentable.
    init?(seconds: Int64) {
        guard let text = SKRFC3339.text(seconds: seconds) else { return nil }
        rfc3339 = text

        let days = seconds / 86_400
        let secondOfDay = seconds % 86_400
        let (year, month, day) = SKRFC3339.civilFromDays(days)
        let hour = secondOfDay / 3_600
        let minute = secondOfDay % 3_600 / 60
        let second = secondOfDay % 60

        guard year >= 1980 else {
            dosDate = SKZipTimestamp.dosFloor.dosDate
            dosTime = SKZipTimestamp.dosFloor.dosTime
            return
        }
        guard year <= 2107 else {
            dosDate = SKZipTimestamp.dosCeilingDate
            dosTime = SKZipTimestamp.dosCeilingTime
            return
        }
        dosDate = UInt16((year - 1980) << 9 | month << 5 | day)
        dosTime = UInt16(hour << 11 | minute << 5 | second / 2)
    }
}

/// RFC 3339 text as SandboxArk/1 writes it, and the parser the strict reader needs.
/// Output is always canonical UTC; input also accepts a numeric offset and fractional
/// seconds, which are normalised away because the format stores whole seconds.
enum SKRFC3339 {
    /// 9999-12-31T23:59:59Z; the last instant the calendar text form can express.
    static let maximumSeconds: Int64 = 253_402_300_799

    static func text(seconds: Int64) -> String? {
        guard seconds >= 0, seconds <= maximumSeconds else { return nil }
        let (year, month, day) = civilFromDays(seconds / 86_400)
        guard year >= 1, year <= 9999 else { return nil }
        let secondOfDay = seconds % 86_400
        return padded(year, 4) + "-" + padded(month, 2) + "-" + padded(day, 2)
            + "T" + padded(secondOfDay / 3_600, 2) + ":" + padded(secondOfDay % 3_600 / 60, 2)
            + ":" + padded(secondOfDay % 60, 2) + "Z"
    }

    /// Whole seconds since the Unix epoch, or nil when `value` is not a representable timestamp.
    static func seconds(of value: String) -> Int64? {
        let bytes = Array(value.utf8)
        guard bytes.count >= 20 else { return nil }
        guard let year = number(bytes, 0, 4), let month = number(bytes, 5, 2), let day = number(bytes, 8, 2),
              bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54 || bytes[10] == 0x74,
              let hour = number(bytes, 11, 2), let minute = number(bytes, 14, 2), let second = number(bytes, 17, 2),
              bytes[13] == 0x3A, bytes[16] == 0x3A else { return nil }
        guard year >= 1, year <= 9999, (1...12).contains(month), (1...daysInMonth(year, month)).contains(day),
              hour <= 23, minute <= 59, second <= 59 else { return nil }

        var index = 19
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            let start = index
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            guard index > start else { return nil }
        }
        guard index < bytes.count else { return nil }

        var offsetSeconds = 0
        switch bytes[index] {
        case 0x5A, 0x7A:
            index += 1
        case 0x2B, 0x2D:
            guard let offsetHour = number(bytes, index + 1, 2), let offsetMinute = number(bytes, index + 4, 2),
                  index + 6 < bytes.count, bytes[index + 3] == 0x3A,
                  offsetHour <= 23, offsetMinute <= 59 else { return nil }
            offsetSeconds = Int(offsetHour) * 3_600 + Int(offsetMinute) * 60
            if bytes[index] == 0x2D { offsetSeconds = -offsetSeconds }
            index += 6
        default:
            return nil
        }
        guard index == bytes.count else { return nil }

        let days = daysFromCivil(year: Int64(year), month: Int64(month), day: Int64(day))
        let total = days * 86_400 + Int64(hour) * 3_600 + Int64(minute) * 60 + Int64(second) - Int64(offsetSeconds)
        guard total >= 0, total <= maximumSeconds else { return nil }
        return total
    }

    /// Howard Hinnant's civil-from-days conversion, valid for the whole representable range.
    static func civilFromDays(_ days: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPart = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPart + 2) / 5 + 1
        let month = monthPart < 10 ? monthPart + 3 : monthPart - 9
        return (year + (month <= 2 ? 1 : 0), month, day)
    }

    private static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
        let adjustedYear = month <= 2 ? year - 1 : year
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let monthPart = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * monthPart + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        }
    }

    private static func number(_ bytes: [UInt8], _ start: Int, _ count: Int) -> Int? {
        guard start + count <= bytes.count else { return nil }
        var value = 0
        for index in start..<(start + count) {
            guard isDigit(bytes[index]) else { return nil }
            value = value * 10 + Int(bytes[index] - 0x30)
        }
        return value
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    private static func padded(_ value: Int64, _ width: Int) -> String {
        var text = String(value)
        while text.utf8.count < width { text = "0" + text }
        return text
    }
}
