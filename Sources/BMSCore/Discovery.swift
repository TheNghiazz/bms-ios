// Discovery.swift
// Lọc thiết bị BLE khi quét: chỉ hiện những thiết bị có khả năng là mạch BMS.
//
// Các app của hãng (JK BMS, JBD/Xiaoxiang, Daly…) thường không "thấy" mọi
// thiết bị Bluetooth xung quanh. Họ lọc ngay từ gói quảng cáo (advertisement)
// theo một trong các dấu hiệu:
//   1. tên thiết bị (tiền tố/thương hiệu: JK, JBD, Xiaoxiang, Daly, ANT…),
//   2. service UUID 16-bit đặc trưng được quảng cáo (FFE0, FF00, FFF0…),
//   3. company/manufacturer ID,
//   4. quét có chọn service (`scanForPeripherals(withServices:)`).
//
// iOS không cho đọc MAC và một số mạch không quảng cáo service UUID, nên app
// này quét tất cả rồi lọc bằng phần mềm (tên + service UUID). Người dùng vẫn
// có công tắc "Hiện tất cả" cho trường hợp mạch đã được đổi tên lạ.

import Foundation

/// Kết quả nhận diện một thiết bị quảng cáo có phải mạch BMS hay không.
public struct BMSDiscoveryMatch: Hashable, Sendable {
    /// Hãng đoán được (nil nếu chỉ biết "có thể là BMS").
    public let brand: BMSBrand?
    /// Lý do khớp, hiển thị ở màn hình quét/chẩn đoán.
    public let reason: String
    /// Điểm tin cậy càng cao càng chắc chắn (dùng để xếp hạng/hiển thị).
    public let score: Int

    public init(brand: BMSBrand?, reason: String, score: Int) {
        self.brand = brand
        self.reason = reason
        self.score = score
    }
}

public enum BMSScanFilter {

    /// Từ khóa chung (ngoài tên hãng đã biết) thường xuất hiện ở mạch BMS.
    public static let genericNameKeywords: [String] = [
        "bms", "smart bms", "lifepo", "lifepo4", "li-ion", "liion",
        "battery monitor", "battery management", "smart battery",
        "sp04s", "sp15s", "energy storage",
    ]

    /// Service UUID (dạng 4 ký tự) mà mạch BMS thường quảng cáo.
    /// Lưu ý FFE0 là service phổ biến của JK/ANT và cả một số module BLE giá rẻ,
    /// nên nó chỉ được coi là "có thể là BMS", không khẳng định hãng.
    public static let knownServiceUUIDs: [String] = [
        "ffe0", "ff00", "fff0",
    ]

    /// Service do đúng hãng dùng, theo thứ tự ưu tiên cố định (tránh phụ thuộc
    /// thứ tự duyệt của Set).
    private static let serviceBrands: [(uuid: String, brand: BMSBrand)] = [
        ("ff00", .jbd),
        ("fff0", .daly),
        ("fff1", .daly),
        ("ffe1", .jk),
    ]

    /// Trả về `nil` nếu thiết bị không có dấu hiệu nào của mạch BMS.
    public static func match(
        name rawName: String?,
        serviceUUIDs: [String] = []
    ) -> BMSDiscoveryMatch? {
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowered = name.lowercased()
        let services = Set(serviceUUIDs.map(BLEEndpointSelector.shortUUID))

        // 1. Tên đúng thương hiệu đã biết.
        if !lowered.isEmpty, let brand = BMSBrand.detect(fromDeviceName: lowered) {
            return BMSDiscoveryMatch(
                brand: brand,
                reason: "Tên thiết bị khớp \(brand.rawValue)",
                score: 100)
        }

        // 2. Từ khóa BMS chung trong tên.
        if let keyword = genericNameKeywords.first(where: { lowered.contains($0) }) {
            return BMSDiscoveryMatch(
                brand: brandFromServices(services),
                reason: "Tên chứa “\(keyword)”",
                score: 80)
        }

        // 3. Service UUID đặc trưng của hãng.
        if let brand = brandFromServices(services) {
            return BMSDiscoveryMatch(
                brand: brand,
                reason: "Quảng cáo service \(shortService(for: brand))",
                score: 90)
        }

        // 4. FFE0: JK/ANT và một số mạch khác dùng chung; chỉ là gợi ý.
        if services.contains("ffe0") {
            return BMSDiscoveryMatch(
                brand: nil,
                reason: "Quảng cáo service FFE0 (JK/ANT)",
                score: 70)
        }

        return nil
    }

    /// Có nên hiển thị thiết bị này ở danh sách mặc định (chỉ mạch BMS)?
    public static func isLikelyBMS(name: String?, serviceUUIDs: [String] = []) -> Bool {
        match(name: name, serviceUUIDs: serviceUUIDs) != nil
    }

    private static func brandFromServices(_ services: Set<String>) -> BMSBrand? {
        for entry in serviceBrands where services.contains(entry.uuid) {
            return entry.brand
        }
        return nil
    }

    private static func shortService(for brand: BMSBrand) -> String {
        brand.serviceUUIDs.first?.uppercased() ?? "?"
    }
}
