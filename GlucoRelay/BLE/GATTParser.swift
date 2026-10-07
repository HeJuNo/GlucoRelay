import Foundation

/// A decoded GATT Glucose Measurement (characteristic 0x2A18).
struct GlucoseMeasurement: Sendable, Equatable {
    var sequenceNumber: Int
    /// Base time + time offset, interpreted in the phone's current time zone.
    var timestamp: Date
    /// Glucose concentration converted to mg/dL; nil if absent or a special value (HI/LO/NaN).
    var mgdL: Double?
    /// Sample type nibble (0x1 = capillary whole blood, 0xA = control solution …).
    var sampleType: Int?
    var sampleLocation: Int?
    var sensorStatus: UInt16?
    var contextInformationFollows: Bool

    var isControlSolution: Bool { sampleType == 0x0A }
}

enum GATTParserError: Error, Equatable {
    case tooShort(Int)
    case invalidDate
}

/// Record Access Control Point (0x2A52) commands and responses.
enum RACP {
    static let opReportStoredRecords: UInt8 = 0x01
    static let opNumberOfRecordsResponse: UInt8 = 0x05
    static let opResponseCode: UInt8 = 0x06

    static let operatorAll: UInt8 = 0x01
    static let operatorGreaterOrEqual: UInt8 = 0x03
    static let operatorLast: UInt8 = 0x06
    static let filterSequenceNumber: UInt8 = 0x01

    static let responseSuccess: UInt8 = 0x01
    static let responseNoRecords: UInt8 = 0x06

    static func reportAll() -> Data { Data([opReportStoredRecords, operatorAll]) }
    static func reportLast() -> Data { Data([opReportStoredRecords, operatorLast]) }

    /// "Report records with sequence number > `lastSequence`" (RACP only knows ≥, so we ask for ≥ last+1).
    static func reportAfter(sequence lastSequence: Int) -> Data {
        guard lastSequence >= 0 else { return reportAll() }
        let next = UInt16(clamping: lastSequence + 1)
        return Data([opReportStoredRecords, operatorGreaterOrEqual, filterSequenceNumber,
                     UInt8(next & 0xFF), UInt8(next >> 8)])
    }

    enum Response: Equatable {
        /// Request finished. `success` false carries the RACP response code.
        case completed(success: Bool, noRecords: Bool, code: UInt8)
        case numberOfRecords(Int)
        case unknown
    }

    static func parse(_ data: Data) -> Response {
        let b = [UInt8](data)
        guard b.count >= 2 else { return .unknown }
        switch b[0] {
        case opResponseCode where b.count >= 4:
            return .completed(success: b[3] == responseSuccess, noRecords: b[3] == responseNoRecords, code: b[3])
        case opNumberOfRecordsResponse where b.count >= 4:
            return .numberOfRecords(Int(b[2]) | Int(b[3]) << 8)
        default:
            return .unknown
        }
    }
}

/// Parser for the Bluetooth SIG Glucose Profile.
///
/// Glucose Measurement layout (little-endian):
/// ```
/// [0]      flags  bit0 time offset present
///                 bit1 concentration + type/sample location present
///                 bit2 concentration unit: 0 = kg/L, 1 = mol/L
///                 bit3 sensor status annunciation present
///                 bit4 context information follows
/// [1-2]    sequence number (uint16)
/// [3-9]    base time: year uint16, month, day, hours, minutes, seconds
/// [+2]     time offset sint16 minutes          (bit0)
/// [+2]     concentration SFLOAT                (bit1)
/// [+1]     type (low nibble) / location (high) (bit1)
/// [+2]     sensor status annunciation uint16   (bit3)
/// ```
enum GATTParser {
    static let mgdLPerKgL = 100_000.0        // 1 kg/L = 100 000 mg/dL
    static let mmolLPerMolL = 1_000.0        // 1 mol/L = 1000 mmol/L
    static let mgdLPerMmolL = 18.0182

    static func parseMeasurement(_ data: Data, calendar: Calendar = .current) throws -> GlucoseMeasurement {
        let b = [UInt8](data)
        guard b.count >= 10 else { throw GATTParserError.tooShort(b.count) }

        let flags = b[0]
        let hasTimeOffset = flags & 0x01 != 0
        let hasConcentration = flags & 0x02 != 0
        let unitIsMolPerL = flags & 0x04 != 0
        let hasStatus = flags & 0x08 != 0
        let contextFollows = flags & 0x10 != 0

        var required = 10
        if hasTimeOffset { required += 2 }
        if hasConcentration { required += 3 }
        if hasStatus { required += 2 }
        guard b.count >= required else { throw GATTParserError.tooShort(b.count) }

        let sequence = Int(uint16(b, 1))

        var comps = DateComponents()
        comps.calendar = calendar
        comps.timeZone = calendar.timeZone
        comps.year = Int(uint16(b, 3))
        comps.month = Int(b[5])
        comps.day = Int(b[6])
        comps.hour = Int(b[7])
        comps.minute = Int(b[8])
        comps.second = Int(b[9])
        guard var date = calendar.date(from: comps) else { throw GATTParserError.invalidDate }

        var offset = 10
        if hasTimeOffset {
            let minutes = Int16(bitPattern: uint16(b, offset))
            date = date.addingTimeInterval(TimeInterval(minutes) * 60)
            offset += 2
        }

        var mgdL: Double?
        var sampleType: Int?
        var sampleLocation: Int?
        if hasConcentration {
            if let raw = sfloat(uint16(b, offset)) {
                mgdL = unitIsMolPerL
                    ? raw * mmolLPerMolL * mgdLPerMmolL
                    : raw * mgdLPerKgL
            }
            sampleType = Int(b[offset + 2] & 0x0F)
            sampleLocation = Int(b[offset + 2] >> 4)
            offset += 3
        }

        var status: UInt16?
        if hasStatus {
            status = uint16(b, offset)
            offset += 2
        }

        return GlucoseMeasurement(sequenceNumber: sequence, timestamp: date, mgdL: mgdL,
                                  sampleType: sampleType, sampleLocation: sampleLocation,
                                  sensorStatus: status, contextInformationFollows: contextFollows)
    }

    /// IEEE 11073-20601 16-bit SFLOAT: signed 4-bit exponent (high nibble), signed 12-bit mantissa.
    /// Returns nil for the reserved special values (NaN, NRes, ±INFINITY, reserved).
    static func sfloat(_ raw: UInt16) -> Double? {
        switch raw {
        case 0x07FF, 0x0800, 0x07FE, 0x0802, 0x0801: return nil
        default: break
        }
        var mantissa = Int(raw & 0x0FFF)
        if mantissa >= 0x0800 { mantissa -= 0x1000 }
        var exponent = Int(raw >> 12)
        if exponent >= 0x8 { exponent -= 0x10 }
        return Double(mantissa) * pow(10.0, Double(exponent))
    }

    /// Serial Number String (0x2A25) – UTF-8, sometimes NUL-padded.
    static func parseSerial(_ data: Data) -> String? {
        let s = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        return s.isEmpty ? nil : s
    }

    private static func uint16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }
}
