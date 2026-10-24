// AcquisitionTests.swift
// Kiểm tra phần "lấy thông tin" đã siết: chọn đúng characteristic JK/JBD/Daly,
// không chọn log debug FFE2 hay GATT chuẩn, và parser không khóa nhầm hãng.

import XCTest
@testable import BMSCore

final class AcquisitionTests: XCTestCase {

    // ------------------------------------------------------ endpoint selector
    func testJK_prefersFFE1_overDebugAndBattery() {
        let chars = [
            GATTCharacteristicInfo(uuid: "2A19", serviceUUID: "180F",
                                   canRead: true, canNotify: true),
            GATTCharacteristicInfo(uuid: "2A00", serviceUUID: "1800",
                                   canRead: true, canWrite: true),
            GATTCharacteristicInfo(uuid: "FFE2", serviceUUID: "FFE0",
                                   canNotify: true),
            GATTCharacteristicInfo(uuid: "FFE1", serviceUUID: "FFE0",
                                   canWriteWithoutResponse: true, canNotify: true),
        ]
        let selection = BLEEndpointSelector.select(from: chars, advertisedName: "JK-BMS")

        XCTAssertEqual(selection.brandHint, BMSBrand.jk)
        XCTAssertEqual(short(selection.data?.uuid), "ffe1")
        XCTAssertEqual(short(selection.write?.uuid), "ffe1")
        XCTAssertEqual(selection.dataCandidates.count, 1)
    }

    func testJK_infersBrandFromFFE2WhenNameIsGeneric() {
        let chars = [
            GATTCharacteristicInfo(uuid: "FFE1", serviceUUID: "FFE0",
                                   canWriteWithoutResponse: true, canNotify: true),
            GATTCharacteristicInfo(uuid: "FFE2", serviceUUID: "FFE0",
                                   canNotify: true),
        ]
        let selection = BLEEndpointSelector.select(from: chars, advertisedName: "BMS-1234")

        XCTAssertEqual(selection.brandHint, BMSBrand.jk)
        XCTAssertEqual(short(selection.data?.uuid), "ffe1")
        XCTAssertEqual(short(selection.write?.uuid), "ffe1")
    }

    func testJBD_selectsFF01DataAndFF02Write() {
        let chars = [
            GATTCharacteristicInfo(uuid: "FF01", serviceUUID: "FF00",
                                   canNotify: true),
            GATTCharacteristicInfo(uuid: "FF02", serviceUUID: "FF00",
                                   canWriteWithoutResponse: true),
            GATTCharacteristicInfo(uuid: "2A19", serviceUUID: "180F",
                                   canRead: true, canNotify: true),
        ]
        let selection = BLEEndpointSelector.select(from: chars,
                                                   advertisedName: "JBD-SP04S")
        XCTAssertEqual(selection.brandHint, BMSBrand.jbd)
        XCTAssertEqual(short(selection.data?.uuid), "ff01")
        XCTAssertEqual(short(selection.write?.uuid), "ff02")
    }

    func testDaly_selectsFFF1DataAndFFF2Write() {
        let chars = [
            GATTCharacteristicInfo(uuid: "FFF1", serviceUUID: "FFF0",
                                   canNotify: true),
            GATTCharacteristicInfo(uuid: "FFF2", serviceUUID: "FFF0",
                                   canWriteWithoutResponse: true),
        ]
        let selection = BLEEndpointSelector.select(from: chars,
                                                   advertisedName: "Daly BMS")
        XCTAssertEqual(selection.brandHint, BMSBrand.daly)
        XCTAssertEqual(short(selection.data?.uuid), "fff1")
        XCTAssertEqual(short(selection.write?.uuid), "fff2")
    }

    func testStandardGATTOnly_isNotTreatedAsBMSData() {
        let chars = [
            GATTCharacteristicInfo(uuid: "2A19", serviceUUID: "180F",
                                   canRead: true, canNotify: true),
            GATTCharacteristicInfo(uuid: "2A00", serviceUUID: "1800",
                                   canRead: true, canWrite: true),
        ]
        let selection = BLEEndpointSelector.select(from: chars,
                                                   advertisedName: "Headphones")
        XCTAssertNil(selection.data)
        XCTAssertNil(selection.write)
    }

    func testBrandDetectionFromNames() {
        XCTAssertEqual(BMSBrand.detect(fromDeviceName: "JK-BMS"), BMSBrand.jk)
        XCTAssertEqual(BMSBrand.detect(fromDeviceName: "JBD-SP04S"), BMSBrand.jbd)
        XCTAssertEqual(BMSBrand.detect(fromDeviceName: "Xiaoxiang BMS"), BMSBrand.jbd)
        XCTAssertEqual(BMSBrand.detect(fromDeviceName: "Daly Smart BMS"), BMSBrand.daly)
        XCTAssertEqual(BMSBrand.detect(fromDeviceName: "ANT-BMS"), BMSBrand.ant)
        XCTAssertNil(BMSBrand.detect(fromDeviceName: "Mi Band 8"))
    }

    // --------------------------------------------------------- parser strict
    func testJBD_unknownCommandDoesNotLockBrand() {
        let parser = UniversalBmsParser()
        parser.feed(Data([0xDD, 0x99, 0x00, 0x05, 1, 2, 3, 4, 5, 0x77]))
        XCTAssertEqual(parser.bmsBrand, UniversalBmsParser.unknownBrand)
        XCTAssertFalse(parser.hasAcceptedFrame)
        XCTAssertGreaterThan(parser.rejectedFrames, 0)
    }

    func testANT_badChecksumIsRejectedThenGoodFrameAccepted() throws {
        let cases = try GoldenVectorStore.loadCases()
        guard let ant = cases.first(where: { $0.name == "ant_17s_demo" }),
              let frame = GoldenVectorCheck.makeData(hex: ant.frames[0]) else {
            return XCTFail("Thiếu golden ANT")
        }

        let parser = UniversalBmsParser()
        var bad = [UInt8](frame)
        bad[139] ^= 0xFF
        parser.feed(Data(bad))
        XCTAssertEqual(parser.bmsBrand, UniversalBmsParser.unknownBrand)
        XCTAssertFalse(parser.hasAcceptedFrame)

        parser.feed(frame)
        XCTAssertEqual(parser.bmsBrand, "ANT-BMS")
        XCTAssertTrue(parser.hasAcceptedFrame)
    }

    func testJBD_deviceNameFrameSetsProvenance() {
        let name = "SP04S-123"
        var frame: [UInt8] = [0xDD, 0x05, 0x00, UInt8(name.count)]
        frame.append(contentsOf: name.utf8)
        frame.append(contentsOf: [0x00, 0x00])   // checksum 16-bit (JBD)
        frame.append(0x77)

        let parser = UniversalBmsParser()
        parser.feed(Data(frame))
        XCTAssertEqual(parser.bmsBrand, "JBD BMS")
        XCTAssertEqual(parser.deviceInfo.deviceName, name)
        XCTAssertTrue(parser.deviceInfoProvenance.has(.deviceName))
        XCTAssertTrue(parser.hasDeviceInfo)
    }

    func testBrandLock_rejectsOtherFamilyFrame() throws {
        let cases = try GoldenVectorStore.loadCases()
        guard let ant = cases.first(where: { $0.name == "ant_17s_demo" }),
              let antFrame = GoldenVectorCheck.makeData(hex: ant.frames[0]),
              let jbd = cases.first(where: { $0.name == "jbd_basic_and_cells" }),
              let jbdFrame = GoldenVectorCheck.makeData(hex: jbd.frames[0]) else {
            return XCTFail("Thiếu golden vector")
        }

        let parser = UniversalBmsParser()
        parser.feed(antFrame)
        XCTAssertEqual(parser.bmsBrand, "ANT-BMS")
        let accepted = parser.acceptedFrames

        parser.feed(jbdFrame)
        XCTAssertEqual(parser.bmsBrand, "ANT-BMS")
        XCTAssertEqual(parser.acceptedFrames, accepted)
        XCTAssertGreaterThan(parser.rejectedFrames, 0)
    }

    // ---------------------------------------------------------------- helper
    private func short(_ uuid: String?) -> String? {
        uuid.map(BLEEndpointSelector.shortUUID)
    }
}
