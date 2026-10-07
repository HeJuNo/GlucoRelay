import XCTest

final class GATTParserTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testSFLOAT() {
        XCTAssertEqual(GATTParser.sfloat(0xB078)!, 0.00120, accuracy: 1e-9) // 120 × 10^-5
        XCTAssertEqual(GATTParser.sfloat(0x0064)!, 100, accuracy: 1e-9)
        XCTAssertEqual(GATTParser.sfloat(0xFFFF)!, -0.1, accuracy: 1e-9)    // mantissa -1, exp -1
        XCTAssertNil(GATTParser.sfloat(0x07FF))
        XCTAssertNil(GATTParser.sfloat(0x0800))
        XCTAssertNil(GATTParser.sfloat(0x07FE))
    }

    /// Typical Accu-Chek Guide record: time offset + kg/L concentration, capillary blood, finger.
    func testMeasurementKgPerL() throws {
        let data = Data([0x03,                   // flags: time offset + concentration, kg/L
                         0x2A, 0x01,             // seq 298
                         0xEA, 0x07, 0x0A, 0x07, // 2026-10-07
                         0x0A, 0x1E, 0x05,       // 10:30:05
                         0x3C, 0x00,             // +60 min
                         0x78, 0xB0,             // 120e-5 kg/L
                         0x11])                  // type 1, location 1
        let m = try GATTParser.parseMeasurement(data, calendar: utc)
        XCTAssertEqual(m.sequenceNumber, 298)
        XCTAssertEqual(m.mgdL!, 120, accuracy: 0.001)
        XCTAssertEqual(m.sampleType, 1)
        XCTAssertEqual(m.sampleLocation, 1)
        XCTAssertFalse(m.isControlSolution)
        let expected = utc.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 11, minute: 30, second: 5))!
        XCTAssertEqual(m.timestamp, expected)
    }

    func testMeasurementMolPerLWithStatus() throws {
        // 6.7 mmol/L = 0.0067 mol/L = 67 × 10^-4 → exponent -4 (0xC), mantissa 0x043
        let data = Data([0x0E,                   // concentration, mol/L, status
                         0x05, 0x00,
                         0xEA, 0x07, 0x01, 0x02, 0x03, 0x04, 0x05,
                         0x43, 0xC0,
                         0x1A,                   // type 0xA control solution (low nibble), location 1 finger
                         0x00, 0x00])
        let m = try GATTParser.parseMeasurement(data, calendar: utc)
        XCTAssertEqual(m.sequenceNumber, 5)
        XCTAssertEqual(m.mgdL!, 6.7 * 18.0182, accuracy: 0.01)
        XCTAssertTrue(m.isControlSolution)
        XCTAssertEqual(m.sensorStatus, 0)
    }

    func testHiLoValueHasNoConcentration() throws {
        let data = Data([0x02, 0x01, 0x00, 0xEA, 0x07, 0x01, 0x01, 0x00, 0x00, 0x00, 0xFE, 0x07, 0x11])
        XCTAssertNil(try GATTParser.parseMeasurement(data, calendar: utc).mgdL)
    }

    func testTooShort() {
        XCTAssertThrowsError(try GATTParser.parseMeasurement(Data([0x03, 0x01, 0x00]), calendar: utc))
        XCTAssertThrowsError(try GATTParser.parseMeasurement(
            Data([0x03, 0x01, 0x00, 0xEA, 0x07, 0x01, 0x01, 0, 0, 0, 0x00]), calendar: utc))
    }

    func testRACP() {
        XCTAssertEqual(RACP.reportAfter(sequence: -1), Data([0x01, 0x01]))
        XCTAssertEqual(RACP.reportAfter(sequence: 298), Data([0x01, 0x03, 0x01, 0x2B, 0x01]))
        XCTAssertEqual(RACP.parse(Data([0x06, 0x00, 0x01, 0x01])), .completed(success: true, noRecords: false, code: 1))
        XCTAssertEqual(RACP.parse(Data([0x06, 0x00, 0x01, 0x06])), .completed(success: false, noRecords: true, code: 6))
        XCTAssertEqual(RACP.parse(Data([0x05, 0x00, 0x0A, 0x00])), .numberOfRecords(10))
    }

    func testSerial() {
        XCTAssertEqual(GATTParser.parseSerial(Data("92345678\0\0".utf8)), "92345678")
        XCTAssertNil(GATTParser.parseSerial(Data()))
    }
}
