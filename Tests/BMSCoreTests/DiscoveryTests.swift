// DiscoveryTests.swift
// Kiểm tra bộ lọc quét: chỉ nhận thiết bị có dấu hiệu mạch BMS (tên hãng,
// từ khóa BMS, hoặc service UUID đặc trưng) và loại thiết bị Bluetooth khác.

import XCTest
@testable import BMSCore

final class DiscoveryTests: XCTestCase {

    func testJKName_isMatched() {
        let match = BMSScanFilter.match(name: "JK-B2A24S20P", serviceUUIDs: [])
        XCTAssertEqual(match?.brand, .jk)
        XCTAssertEqual(match?.score, 100)
    }

    func testJBDName_isMatched() {
        XCTAssertEqual(BMSScanFilter.match(name: "JBD-SP04S")?.brand, .jbd)
        XCTAssertEqual(BMSScanFilter.match(name: "xiaoxiang bms")?.brand, .jbd)
    }

    func testDalyAndANTNames_areMatched() {
        XCTAssertEqual(BMSScanFilter.match(name: "Daly Smart BMS")?.brand, .daly)
        XCTAssertEqual(BMSScanFilter.match(name: "ANT-BMS")?.brand, .ant)
    }

    func testJBDSourceService_isMatchedEvenWithUnknownName() {
        let match = BMSScanFilter.match(name: nil, serviceUUIDs: ["FF00"])
        XCTAssertEqual(match?.brand, .jbd)
        XCTAssertEqual(match?.score, 90)
    }

    func testDalyFull128BitService_isMatched() {
        let uuid = "0000fff0-0000-1000-8000-00805f9b34fb"
        XCTAssertEqual(BMSScanFilter.match(name: nil, serviceUUIDs: [uuid])?.brand, .daly)
    }

    func testFFE0_isTreatedAsPossibleJKOrANT() {
        let match = BMSScanFilter.match(name: "HMSoft", serviceUUIDs: ["FFE0"])
        XCTAssertNotNil(match)
        XCTAssertNil(match?.brand)
        XCTAssertTrue(match?.reason.contains("FFE0") == true)
    }

    func testGenericBMSKeyword_isMatchedWithoutBrand() {
        let match = BMSScanFilter.match(name: "BMS-1234", serviceUUIDs: [])
        XCTAssertNotNil(match)
        XCTAssertNil(match?.brand)
        XCTAssertEqual(match?.score, 80)
    }

    func testGenericKeywordWithJBDServlet_infersBrand() {
        let match = BMSScanFilter.match(name: "battery bms", serviceUUIDs: ["FF00"])
        XCTAssertEqual(match?.brand, .jbd)
    }

    func testUnrelatedDevices_areRejected() {
        XCTAssertNil(BMSScanFilter.match(name: "Mi Band 8", serviceUUIDs: ["180F", "180A"]))
        XCTAssertNil(BMSScanFilter.match(name: "AirPods Pro", serviceUUIDs: []))
        XCTAssertNil(BMSScanFilter.match(name: nil, serviceUUIDs: []))
        XCTAssertNil(BMSScanFilter.match(name: "Smart Watch", serviceUUIDs: ["180D"]))
    }

    func testIsLikelyBMS_helper() {
        XCTAssertTrue(BMSScanFilter.isLikelyBMS(name: "JK-BMS"))
        XCTAssertFalse(BMSScanFilter.isLikelyBMS(name: "Keyboard"))
    }
}
