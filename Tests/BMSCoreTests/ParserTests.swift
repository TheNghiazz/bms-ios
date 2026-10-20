// ParserTests.swift
// Chạy toàn bộ golden vectors qua parser Swift ở cả 2 cách nhận dữ liệu:
//  - mỗi frame một lần feed (separate)
//  - dán nối rồi chia chunk ngẫu nhiên theo chu kỳ (chunked)
// Kết quả phải khớp 100% bộ giải mã Python gốc.

import XCTest
@testable import BMSCore

final class ParserTests: XCTestCase {

    func testGoldenVectors_separateFrames() {
        let failures = GoldenVectorCheck.runAll(mode: .separate)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n---\n"))
    }

    func testGoldenVectors_chunkedStream() {
        let failures = GoldenVectorCheck.runAll(mode: .chunked)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n---\n"))
    }

    func testVectorCount_matchesExpectedCases() {
        XCTAssertEqual(GoldenVectorCheck.caseCount(), 9)
    }

    // ------------------------------------------------------------------ ETA
    func testEta_charging() {
        var live = BMSLiveTelemetry()
        live.currentA = 5.0
        live.nominalCapacityAh = 30.0
        live.remainingCapacityAh = 20.0
        live.socPercent = 67
        let eta = BMSEtaEstimator.estimate(live)
        XCTAssertEqual(eta.state, .charging)
        XCTAssertEqual(eta.needAh, 10.0, accuracy: 1e-9)
        // (10 Ah / 5 A) * 1.08 = 2.16 h
        XCTAssertEqual(eta.etaHours ?? -1, 2.16, accuracy: 1e-9)
    }

    func testEta_chargingFullFixesOriginalSocTypo() {
        var live = BMSLiveTelemetry()
        live.currentA = 5.0
        live.nominalCapacityAh = 30.0
        live.remainingCapacityAh = 29.99   // need = 0.01 <= 0.05
        live.socPercent = 100
        let eta = BMSEtaEstimator.estimate(live)
        XCTAssertEqual(eta.state, .charging)
        XCTAssertNil(eta.etaHours, "Đã đầy -> không còn ETA Crash như bug socPercent gốc")
    }

    func testEta_discharging() {
        var live = BMSLiveTelemetry()
        live.currentA = -12.5
        live.remainingCapacityAh = 25.0
        let eta = BMSEtaEstimator.estimate(live)
        XCTAssertEqual(eta.state, .discharging)
        XCTAssertEqual(eta.etaHours ?? -1, 2.0, accuracy: 1e-9)
    }

    func testEta_standby() {
        var live = BMSLiveTelemetry()
        live.currentA = 0.0
        let eta = BMSEtaEstimator.estimate(live)
        XCTAssertEqual(eta.state, .standby)
        XCTAssertNil(eta.etaHours)
    }

    // ------------------------------------------------------------ formatting
    func testFormatDuration() {
        XCTAssertEqual(BMSFormatting.formatDuration(seconds: 185_400),
                       "2 ngày 03:30:00")
        XCTAssertEqual(BMSFormatting.formatDuration(seconds: -5),
                       "0 ngày 00:00:00")
    }

    func testFormatEtaHours() {
        XCTAssertEqual(BMSFormatting.formatEtaHours(2.16), "2 giờ 10 phút")
        XCTAssertEqual(BMSFormatting.formatEtaHours(0.5), "30 phút")
        XCTAssertEqual(BMSFormatting.formatEtaHours(0.0), "0 phút")
        XCTAssertEqual(BMSFormatting.formatEtaHours(9_999.5), "0 phút")
    }

    // ------------------------------------------------------------- commands
    func testJKCommandFrame() {
        let frame = BMSCommand.jkFrame(cmd: 0x96, counter: 1)
        XCTAssertEqual(frame.count, 20)
        XCTAssertEqual(Array(frame[0..<4]), [0xAA, 0x55, 0x90, 0xEB])
        XCTAssertEqual(frame[4], 0x96)
        XCTAssertEqual(frame[16], 1)
        XCTAssertEqual(frame[19], UInt8(BMSChecksum.sum8(frame[0..<19])))
    }

    // ------------------------------------------------------------- assemble
    func testFrameRejection_stopsAtResync() {
        let parser = UniversalBmsParser()
        parser.feed(Data([0x01, 0x02, 0x03]))      // rác
        parser.feed(Data([0x00]))                  // dồn dập but no header
        XCTAssertEqual(parser.bmsBrand, UniversalBmsParser.unknownBrand)
        XCTAssertFalse(parser.hasCellInfo)
    }

    func testHexParsing() {
        let data = GoldenVectorCheck.makeData(hex: "55aaeb90")
        XCTAssertEqual(Array(data ?? Data()), [0x55, 0xAA, 0xEB, 0x90])
        XCTAssertNil(GoldenVectorCheck.makeData(hex: "abc"))
    }
}
