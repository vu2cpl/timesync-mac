import Foundation

struct GPRMC {
    enum Status { case active, void }
    let utc: Date?           // Combined date + time. Nil if either is missing.
    let status: Status
}

struct GPZDA {
    let utc: Date
}

struct GPGSV {
    let satellitesInView: Int
}

enum NMEASentence {
    case rmc(GPRMC)
    case zda(GPZDA)
    case gsv(GPGSV)
    case other(String)                 // talker+type, e.g. "GPGGA"
    case invalid(String, reason: String)
}

/// Streaming NMEA parser. Feed bytes as they arrive; receive parsed sentences
/// along with a timestamp marking when the leading '$' of each sentence arrived.
final class NMEAParser {
    private var partial: [UInt8] = []
    private var partialStart: Date?

    /// Bytes guard against runaway input on a noisy line.
    private let maxSentenceBytes = 256

    /// (sentence, arrivalTimeOfFirstByte)
    var onSentence: ((NMEASentence, Date) -> Void)?

    func feed(_ data: Data, arrivedAt: Date) {
        for byte in data {
            switch byte {
            case 0x24: // '$' — start of a new sentence
                partial.removeAll(keepingCapacity: true)
                partial.append(byte)
                partialStart = arrivedAt
            case 0x0A: // LF — end of sentence
                if !partial.isEmpty, let start = partialStart {
                    let text = String(decoding: partial, as: UTF8.self)
                    let sentence = Self.parse(text)
                    onSentence?(sentence, start)
                }
                partial.removeAll(keepingCapacity: true)
                partialStart = nil
            case 0x0D: // CR — ignore
                continue
            default:
                if partialStart != nil {
                    partial.append(byte)
                    if partial.count > maxSentenceBytes {
                        partial.removeAll(keepingCapacity: true)
                        partialStart = nil
                    }
                }
                // Bytes before any '$' are noise — drop.
            }
        }
    }

    // MARK: - Parsing

    static func parse(_ raw: String) -> NMEASentence {
        // raw is "$GPRMC,...,...*7E" (no trailing CRLF)
        guard raw.first == "$" else {
            return .invalid(raw, reason: "missing leading $")
        }
        guard let starIdx = raw.firstIndex(of: "*") else {
            return .invalid(raw, reason: "no checksum delimiter")
        }
        let body = raw[raw.index(after: raw.startIndex)..<starIdx]
        let cksum = raw[raw.index(after: starIdx)...]

        // Checksum is the first two hex chars after '*'. Some sources append CR or extra chars.
        let cksumStr = String(cksum.prefix(2))
        guard cksumStr.count == 2, let provided = UInt8(cksumStr, radix: 16) else {
            return .invalid(raw, reason: "bad checksum hex")
        }
        var calc: UInt8 = 0
        for u in body.utf8 { calc ^= u }
        if calc != provided {
            return .invalid(raw, reason: String(format: "checksum %02X != %02X", calc, provided))
        }

        let fields = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let head = fields.first, head.count == 5 else {
            return .invalid(raw, reason: "no head")
        }
        let type = head.suffix(3)
        switch type {
        case "RMC": return parseRMC(fields)
        case "ZDA": return parseZDA(fields)
        case "GSV": return parseGSV(fields)
        default:    return .other(head)
        }
    }

    private static func parseRMC(_ f: [String]) -> NMEASentence {
        // 0:type, 1:hhmmss(.ss), 2:status, 3-4:lat, 5-6:lon, 7:speed, 8:course, 9:ddmmyy, ...
        guard f.count >= 10 else {
            return .invalid("RMC", reason: "too few fields (\(f.count))")
        }
        let status: GPRMC.Status = (f[2] == "A") ? .active : .void
        let utc = parseDateTime(timeField: f[1], dateField: f[9])
        return .rmc(GPRMC(utc: utc, status: status))
    }

    private static func parseZDA(_ f: [String]) -> NMEASentence {
        // 0:type, 1:hhmmss(.ss), 2:dd, 3:mm, 4:yyyy, 5:tz_h, 6:tz_min
        guard f.count >= 5 else {
            return .invalid("ZDA", reason: "too few fields (\(f.count))")
        }
        guard let day = Int(f[2]), let month = Int(f[3]), let year = Int(f[4]) else {
            return .invalid("ZDA", reason: "bad date fields")
        }
        guard let utc = composeDate(time: f[1], year: year, month: month, day: day) else {
            return .invalid("ZDA", reason: "bad time")
        }
        return .zda(GPZDA(utc: utc))
    }

    private static func parseGSV(_ f: [String]) -> NMEASentence {
        // 0:type, 1:total_msgs, 2:msg_num, 3:sats_in_view, then 4-tuples...
        guard f.count >= 4, let sats = Int(f[3]) else {
            return .invalid("GSV", reason: "bad sats field")
        }
        return .gsv(GPGSV(satellitesInView: sats))
    }

    // MARK: - Date/time helpers

    private static func parseDateTime(timeField: String, dateField: String) -> Date? {
        guard timeField.count >= 6, dateField.count == 6 else { return nil }
        let day   = Int(dateField.prefix(2))
        let month = Int(dateField.dropFirst(2).prefix(2))
        let year2 = Int(dateField.dropFirst(4).prefix(2))
        guard let day, let month, let year2 else { return nil }
        let year = 2000 + year2  // 2-digit year; valid until 2100
        return composeDate(time: timeField, year: year, month: month, day: day)
    }

    private static func composeDate(time: String, year: Int, month: Int, day: Int) -> Date? {
        guard time.count >= 6 else { return nil }
        let hh = Int(time.prefix(2))
        let mm = Int(time.dropFirst(2).prefix(2))
        let secStr = time.dropFirst(4)        // "ss" or "ss.ss…"
        let sec = Double(secStr)
        guard let hh, let mm, let sec else { return nil }

        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hh
        comps.minute = mm
        comps.second = Int(sec.rounded(.down))
        comps.nanosecond = Int((sec - Double(Int(sec.rounded(.down)))) * 1_000_000_000)
        comps.timeZone = TimeZone(identifier: "UTC")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)
    }
}
