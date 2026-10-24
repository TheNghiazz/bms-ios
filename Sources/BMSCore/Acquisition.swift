// Acquisition.swift
// Logic thuần (không CoreBluetooth) để chọn đúng kênh dữ liệu/ghi của BMS.
//
// Vì sao cần: trên JK-BMS, service FFE0 thường có FFE1 (dữ liệu + ghi lệnh)
// và FFE2 (log debug, chỉ notify). Nếu chọn "characteristic notify đầu tiên"
// như bản Python gốc thì rất dễ trúng FFE2 hoặc Battery Level (2A19) và app
// sẽ báo đã kết nối nhưng không bao giờ nhận được khung BMS.
//
// Bộ chọn dưới đây chấm điểm theo:
//   1. tên thiết bị quảng cáo (JK/JBD/Daly/ANT),
//   2. UUID đã biết của từng hãng,
//   3. cùng service với characteristic ghi,
//   4. loại bỏ characteristic debug FFE2 và các service GATT chuẩn.

import Foundation

/// Hãng BMS mà app có bộ giải mã.
public enum BMSBrand: String, CaseIterable, Sendable {
    case jk = "JK-BMS"
    case ant = "ANT-BMS"
    case jbd = "JBD BMS"
    case daly = "Daly BMS"

    /// Đoán hãng từ tên quảng cáo BLE (không phân biệt hoa thường).
    /// Chỉ là gợi ý; parser vẫn phải xác thực bằng khung có checksum.
    public static func detect(fromDeviceName raw: String) -> BMSBrand? {
        let name = raw.lowercased()
        if name.contains("jbd") || name.contains("xiaoxiang")
            || name.contains("overkill") || name.contains("jiabaida")
            || name.contains("sp04s") || name.contains("sp15s") {
            return .jbd
        }
        if name.contains("daly") {
            return .daly
        }
        if name.contains("jk-bms") || name.contains("jk_bms")
            || name.contains("jk02") || name.contains("jikong")
            || name.hasPrefix("jk") {
            return .jk
        }
        if name.contains("ant-bms") || name.contains("ant bms")
            || name.contains("mayi") || name.contains("jfnf") {
            return .ant
        }
        return nil
    }

    /// UUID characteristic thường chứa khung dữ liệu (dạng 4 ký tự).
    public var dataUUIDs: [String] {
        switch self {
        case .jk: return ["ffe1"]
        case .ant: return ["ffe1", "ff01"]
        case .jbd: return ["ff01", "ffe1"]
        case .daly: return ["fff1"]
        }
    }

    /// UUID characteristic nhận lệnh ghi (dạng 4 ký tự).
    public var writeUUIDs: [String] {
        switch self {
        case .jk: return ["ffe1"]
        case .ant: return ["ffe1", "ff02"]
        case .jbd: return ["ff02"]
        case .daly: return ["fff2"]
        }
    }

    /// UUID service đặc trưng (dạng 4 ký tự).
    public var serviceUUIDs: [String] {
        switch self {
        case .jk: return ["ffe0"]
        case .ant: return ["ffe0"]
        case .jbd: return ["ff00"]
        case .daly: return ["fff0"]
        }
    }
}

/// Ảnh chụp thuộc tính một characteristic, đủ để chọn kênh mà không cần
/// import CoreBluetooth vào BMSCore.
public struct GATTCharacteristicInfo: Hashable, Sendable {
    public let uuid: String
    public let serviceUUID: String
    public let canRead: Bool
    public let canWrite: Bool
    public let canWriteWithoutResponse: Bool
    public let canNotify: Bool
    public let canIndicate: Bool

    public init(
        uuid: String,
        serviceUUID: String,
        canRead: Bool = false,
        canWrite: Bool = false,
        canWriteWithoutResponse: Bool = false,
        canNotify: Bool = false,
        canIndicate: Bool = false
    ) {
        self.uuid = uuid
        self.serviceUUID = serviceUUID
        self.canRead = canRead
        self.canWrite = canWrite
        self.canWriteWithoutResponse = canWriteWithoutResponse
        self.canNotify = canNotify
        self.canIndicate = canIndicate
    }

    public var isDataCapable: Bool { canNotify || canIndicate }
    public var isWritable: Bool { canWrite || canWriteWithoutResponse }

    /// Khóa duy nhất trong một thiết bị: cùng UUID có thể nằm ở nhiều service.
    public var key: String {
        serviceUUID.lowercased() + "/" + uuid.lowercased()
    }
}

/// Kết quả chọn kênh, kèm lý do để hiển thị ở màn hình chẩn đoán.
public struct BLEEndpointSelection: Sendable {
    public let data: GATTCharacteristicInfo?
    public let write: GATTCharacteristicInfo?
    public let poll: GATTCharacteristicInfo?
    public let dataCandidates: [GATTCharacteristicInfo]
    public let brandHint: BMSBrand?
    public let reasons: [String]
}

public enum BLEEndpointSelector {

    private struct Scored {
        let info: GATTCharacteristicInfo
        let score: Int
    }

    /// Chọn kênh dữ liệu/ghi từ toàn bộ characteristic đã khám phá.
    public static func select(
        from characteristics: [GATTCharacteristicInfo],
        advertisedName: String?
    ) -> BLEEndpointSelection {
        let nameBrand = advertisedName.flatMap(BMSBrand.detect(fromDeviceName:))
        let serviceBrand = inferBrandFromServices(characteristics)
        let brandHint: BMSBrand? = nameBrand ?? serviceBrand

        var reasons: [String] = []
        if let nameBrand {
            reasons.append("Tên thiết bị gợi ý hãng: \(nameBrand.rawValue)")
        } else if let serviceBrand {
            reasons.append("Service GATT gợi ý hãng: \(serviceBrand.rawValue)")
        }

        var writable: [GATTCharacteristicInfo] = []
        var readable: [GATTCharacteristicInfo] = []
        for c in characteristics {
            if c.isWritable { writable.append(c) }
            if c.canRead { readable.append(c) }
        }

        var dataRanked: [Scored] = []
        for c in characteristics where c.isDataCapable {
            let score = dataScore(c, brand: brandHint, writable: writable)
            dataRanked.append(Scored(info: c, score: score))
        }
        dataRanked = sortScored(dataRanked)

        // Điểm dưới -100 nghĩa là characteristic chuẩn/debug, không dùng làm
        // kênh BMS. Không fallback sang Battery Level/Device Name.
        var dataCandidates: [GATTCharacteristicInfo] = []
        for item in dataRanked where item.score > -100 {
            dataCandidates.append(item.info)
        }
        let data: GATTCharacteristicInfo? = dataCandidates.first

        var writeRanked: [Scored] = []
        for c in writable {
            let score = writeScore(c, brand: brandHint, data: data)
            writeRanked.append(Scored(info: c, score: score))
        }
        writeRanked = sortScored(writeRanked)
        var write: GATTCharacteristicInfo?
        for item in writeRanked where item.score > -100 {
            write = item.info
            break
        }
        if write == nil, let data, data.isWritable {
            write = data
        }

        var pollRanked: [Scored] = []
        for c in readable {
            let score = pollScore(c, brand: brandHint, write: write)
            pollRanked.append(Scored(info: c, score: score))
        }
        pollRanked = sortScored(pollRanked)
        var poll: GATTCharacteristicInfo?
        for item in pollRanked where item.score > -100 {
            poll = item.info
            break
        }

        if let data {
            let score = dataScore(data, brand: brandHint, writable: writable)
            let kind = data.canNotify ? "notify" : "indicate"
            reasons.append(
                "Chọn dữ liệu \(shortUUID(data.uuid)) (\(kind), score \(score))")
        } else {
            reasons.append("Không có characteristic notify/indicate phù hợp")
        }
        if let write {
            let score = writeScore(write, brand: brandHint, data: data)
            reasons.append("Chọn ghi \(shortUUID(write.uuid)) (score \(score))")
        } else {
            reasons.append("Không có characteristic ghi phù hợp")
        }
        if let poll {
            reasons.append("Dự phòng đọc \(shortUUID(poll.uuid))")
        }

        return BLEEndpointSelection(
            data: data,
            write: write,
            poll: poll,
            dataCandidates: dataCandidates,
            brandHint: brandHint,
            reasons: reasons)
    }

    private static func sortScored(_ items: [Scored]) -> [Scored] {
        return items.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.info.key < rhs.info.key
        }
    }

    // ------------------------------------------------------------- scoring

    private static func dataScore(
        _ c: GATTCharacteristicInfo,
        brand: BMSBrand?,
        writable: [GATTCharacteristicInfo]
    ) -> Int {
        let uuid = shortUUID(c.uuid)
        let service = shortUUID(c.serviceUUID)
        var score = 0
        if c.canNotify { score += 20 }
        if c.canIndicate { score += 8 }

        if let brand, brand.dataUUIDs.contains(uuid) {
            score += 200
        }
        if brand == nil {
            if service == "ffe0", uuid == "ffe1" { score += 80 }
            if service == "ff00", uuid == "ff01" { score += 80 }
            if service == "fff0", uuid == "fff1" { score += 80 }
        }

        // FFE2 trên JK là log debug, không phải khung BMS.
        if uuid == "ffe2", (brand == .jk || service == "ffe0") {
            score -= 300
        }
        if isStandardGATT(uuid: uuid, service: service) { score -= 200 }

        // Ưu tiên characteristic cùng service với một kênh ghi được.
        var hasWritablePeer = false
        for w in writable where w.serviceUUID == c.serviceUUID {
            hasWritablePeer = true
            break
        }
        if hasWritablePeer { score += 30 }
        return score
    }

    private static func writeScore(
        _ c: GATTCharacteristicInfo,
        brand: BMSBrand?,
        data: GATTCharacteristicInfo?
    ) -> Int {
        let uuid = shortUUID(c.uuid)
        let service = shortUUID(c.serviceUUID)
        var score = 0
        if c.canWriteWithoutResponse { score += 15 }
        if c.canWrite { score += 10 }

        if let brand, brand.writeUUIDs.contains(uuid) {
            score += 200
        }
        if uuid == "ffe2", (brand == .jk || service == "ffe0") {
            score -= 300
        }
        if isStandardGATT(uuid: uuid, service: service) { score -= 200 }

        if let data {
            if c.serviceUUID == data.serviceUUID {
                score += 60
            }
            if c.key == data.key { score += 40 }
        }
        return score
    }

    private static func pollScore(
        _ c: GATTCharacteristicInfo,
        brand: BMSBrand?,
        write: GATTCharacteristicInfo?
    ) -> Int {
        let uuid = shortUUID(c.uuid)
        let service = shortUUID(c.serviceUUID)
        var score = 0
        if let brand, brand.dataUUIDs.contains(uuid) {
            score += 100
        }
        if uuid == "ffe2", (brand == .jk || service == "ffe0") {
            score -= 300
        }
        if isStandardGATT(uuid: uuid, service: service) { score -= 200 }
        if let write, c.serviceUUID == write.serviceUUID {
            score += 40
        }
        return score
    }

    // ------------------------------------------------------------ helpers

    /// Đoán hãng chỉ từ service/characteristic, không dựa vào tên.
    private static func inferBrandFromServices(
        _ characteristics: [GATTCharacteristicInfo]
    ) -> BMSBrand? {
        var shorts = Set<String>()
        for c in characteristics {
            shorts.insert(shortUUID(c.uuid))
            shorts.insert(shortUUID(c.serviceUUID))
        }
        if shorts.contains("ff00"), shorts.contains("ff01") {
            return .jbd
        }
        if shorts.contains("fff0"),
           shorts.contains("fff1") || shorts.contains("fff2") {
            return .daly
        }
        // JK có FFE2 (log). ANT cũng dùng FFE0/FFE1 nhưng không có FFE2,
        // nên nếu chỉ thấy FFE0/FFE1 thì để parser tự nhận diện.
        if shorts.contains("ffe0"), shorts.contains("ffe1"), shorts.contains("ffe2") {
            return .jk
        }
        return nil
    }

    private static func isStandardGATT(uuid: String, service: String) -> Bool {
        let standardServices: Set<String> = ["1800", "1801", "180a", "180f", "1812", "181c"]
        if standardServices.contains(service) { return true }
        let standardChars: Set<String> = [
            "2a00", "2a01", "2a04", "2a05", "2a19",
            "2a24", "2a25", "2a26", "2a27", "2a28", "2a29",
        ]
        return standardChars.contains(uuid)
    }

    /// Rút UUID về dạng 4 ký tự nếu là UUID Bluetooth SIG chuẩn.
    public static func shortUUID(_ raw: String) -> String {
        let compact = raw.lowercased().replacingOccurrences(of: "-", with: "")
        if compact.count == 4 { return compact }
        let baseSuffix = "00001000800000805f9b34fb"
        if compact.count == 32,
           compact.hasPrefix("0000"),
           compact.hasSuffix(baseSuffix) {
            let start = compact.index(compact.startIndex, offsetBy: 4)
            let end = compact.index(start, offsetBy: 4)
            return String(compact[start..<end])
        }
        return compact
    }
}
