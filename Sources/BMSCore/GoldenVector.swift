// GoldenVector.swift
// Tải golden_vectors.json (được sinh từ bộ giải mã Python gốc) và checkpoint
// parser Swift bằng chính byte đó. Dùng chung cho XCTest (CI/macOS) và
// executable bmscore-check (Windows/Linux, khi chưa có XCTest).

import Foundation

public enum GoldenVectorMode: String, Sendable {
    /// Mỗi frame là một lần feed riêng (giống GUI gốc).
    case separate
    /// Dán nối các frame thành một dòng byte, chia chunk [1,3,7,13,20,64,182]
    /// theo chu kỳ rồi feed — mô phỏng notification BLE bị chia nhỏ.
    case chunked
}

public struct GoldenCase: Codable, Equatable, Sendable {
    public struct Snapshot: Codable, Equatable, Sendable {
        public struct Expectation: Codable, Equatable, Sendable {
            public let brand: String
            public let hasCellInfo: Bool
            public let hasDeviceInfo: Bool
            public let hasSettingsInfo: Bool
            public let live: BMSLiveTelemetry
            public let deviceInfo: BMSDeviceInfo
            public let settingsInfo: BMSSettingsInfo
        }
        public let name: String
        public let frames: [String]
        public let expect: Expectation
    }
    public let version: Int
    public let cases: [Snapshot]
}

public enum GoldenVectorStore {

    /// Đọc và giải mã fixtures.
    public static func loadCases() throws -> [GoldenCase.Snapshot] {
        guard let url = Bundle.module.url(
            forResource: "golden_vectors", withExtension: "json") else {
            throw NSError(
                domain: "GoldenVectors", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Không tìm thấy golden_vectors.json trong Bundle.module"])
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GoldenCase.self, from: data).cases
    }

    /// Lấy danh sách frame hex của một case theo tên (phục vụ chế độ demo app).
    public static func framesHex(named name: String) -> [String]? {
        guard let cases = try? loadCases() else { return nil }
        return cases.first { $0.name == name }?.frames
    }
}

public enum GoldenVectorCheck {

    /// Danh sách mô tả lỗi; rãng (empty) khi mọi case đạt.
    public static func runAll(mode: GoldenVectorMode) -> [String] {
        do {
            let cases = try GoldenVectorStore.loadCases()
            var failures: [String] = []
            for snapshot in cases {
                failures.append(contentsOf: check(snapshot, mode: mode))
            }
            return failures
        } catch {
            return ["Không tải golden_vectors.json: \(error)"]
        }
    }

    /// Số case trong fixtures (hiển thị khi pass).
    public static func caseCount() -> Int {
        (try? GoldenVectorStore.loadCases())?.count ?? 0
    }

    static func check(_ snapshot: GoldenCase.Snapshot, mode: GoldenVectorMode) -> [String] {
        var failures: [String] = []
        var frames: [Data] = []

        for hex in snapshot.frames {
            guard let data = makeData(hex: hex) else {
                failures.append("\(snapshot.name): frame hex sai định dạng")
                return failures
            }
            frames.append(data)
        }

        let parser = UniversalBmsParser(mode: .auto)
        switch mode {
        case .separate:
            for data in frames { parser.feed(data) }
        case .chunked:
            var bytes: [UInt8] = []
            for data in frames { bytes.append(contentsOf: data) }
            let sizes = [1, 3, 7, 13, 20, 64, 182]
            var index = 0
            var cycle = 0
            while index < bytes.count {
                let take = min(sizes[cycle % sizes.count], bytes.count - index)
                parser.feed(Data(bytes[index..<(index + take)]))
                index += take
                cycle += 1
            }
        }

        let expected = snapshot.expect
        let modeTag = mode.rawValue
        if parser.bmsBrand != expected.brand {
            failures.append(
                "\(snapshot.name) [\(modeTag)]: brand "
                + "\"\(parser.bmsBrand)\" != \"\(expected.brand)\"")
        }
        if parser.hasCellInfo != expected.hasCellInfo {
            failures.append(
                "\(snapshot.name) [\(modeTag)]: hasCellInfo "
                + "\(parser.hasCellInfo) != \(expected.hasCellInfo)")
        }
        if parser.hasDeviceInfo != expected.hasDeviceInfo {
            failures.append(
                "\(snapshot.name) [\(modeTag)]: hasDeviceInfo "
                + "\(parser.hasDeviceInfo) != \(expected.hasDeviceInfo)")
        }
        if parser.hasSettingsInfo != expected.hasSettingsInfo {
            failures.append(
                "\(snapshot.name) [\(modeTag)]: hasSettingsInfo "
                + "\(parser.hasSettingsInfo) != \(expected.hasSettingsInfo)")
        }
        if parser.live != expected.live {
            failures.append(
                "\(snapshot.name) [\(modeTag)]: live khác; "
                + "expected=\(encode(expected.live)); actual=\(encode(parser.live))")
        }
        if parser.deviceInfo != expected.deviceInfo {
            failures.append(
                "\(snapshot.name) [\(modeTag)]: deviceInfo khác: "
                + "expected=\(encode(expected.deviceInfo)); actual=\(encode(parser.deviceInfo))")
        }
        if parser.settingsInfo != expected.settingsInfo {
            failures.append(
                "\(snapshot.name) [\(modeTag)]: settingsInfo khác: "
                + "expected=\(encode(expected.settingsInfo)); actual=\(encode(parser.settingsInfo))")
        }
        return failures
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "<lỗi encode>" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func makeData(hex string: String) -> Data? {
        let chars = Array(string)
        guard chars.count % 2 == 0, !chars.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = chars[index].hexValue4,
                  let low = chars[index + 1].hexValue4 else { return nil }
            bytes.append((high << 4) | low)
            index += 2
        }
        return Data(bytes)
    }
}

extension Character {
    /// Hex digit 0-15 cho ký tự nếu là hex, ngược lại nil.
    var hexValue4: UInt8? {
        guard let scalar = unicodeScalars.first, scalar.value < 128,
              let v = UInt8(String(scalar), radix: 16) else { return nil }
        return v
    }
}
