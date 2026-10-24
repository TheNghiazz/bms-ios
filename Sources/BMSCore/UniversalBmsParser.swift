// UniversalBmsParser.swift
// Port của UniversalBmsParser trong bản gốc (dòng 212-540 Python), nhưng
// phần nhận khung đã được SIẾT CHẶT để dùng với mạch thật:
//
//   1. Mọi khung phải qua kiểm tra cấu trúc/checksum trước khi giải mã:
//      JK = CRC8, ANT = checksum 16-bit @138, Daly = sum8, JBD = cmd/status/
//      length/trailer + kiểm tra điện áp/SOC hợp lý.
//   2. Không đặt tên hãng chỉ vì tình cờ thấy header. JBD trước đây nhận mọi
//      khung bắt đầu bằng 0xDD; nay chỉ nhận 0x03/0x04/0x05.
//   3. Khóa hãng sau khung hợp lệ đầu tiên: nhiễu/khung lạ không thể ghi đè
//      dữ liệu của mạch đang đọc.
//   4. Có bộ đếm/byte cuối để UI phân biệt "không nhận được byte nào" với
//      "có byte nhưng không khớp khung".
//
// feed() vẫn xử lý hết buffer và trả về toàn bộ frame nhận được (khác bản
// gốc `return` sau frame đầu).

import Foundation

public enum BmsFrameEvent: Equatable, Sendable {
    case jk
    case ant
    case jbd
    case daly
}

public final class UniversalBmsParser: @unchecked Sendable {

    public enum Mode: String, Sendable {
        case auto            // hiện chỉ dùng auto; lưu để mở rộng sau
        case jk
        case ant
        case jbd
        case daly
    }

    public let mode: Mode

    /// Giá trị BRAND khi chưa nhận diện được hãng nào.
    public static let unknownBrand = "Tự động nhận diện"

    public internal(set) var buffer: [UInt8] = []
    public internal(set) var deviceInfo = BMSDeviceInfo()
    public internal(set) var settingsInfo = BMSSettingsInfo()
    public internal(set) var live = BMSLiveTelemetry()

    public internal(set) var hasDeviceInfo = false
    public internal(set) var hasSettingsInfo = false
    public internal(set) var hasCellInfo = false
    public internal(set) var bmsBrand: String = UniversalBmsParser.unknownBrand

    /// Trường nào thực sự có trong khung (dùng cho UI, không ảnh hưởng golden).
    public internal(set) var deviceInfoProvenance = BMSDeviceInfoProvenance()

    // ------------------------------------------------------- chẩn đoán BLE
    /// Tổng số byte đã được đẩy vào parser.
    public internal(set) var totalBytes = 0
    /// Số khung đã qua kiểm tra và được giải mã.
    public internal(set) var acceptedFrames = 0
    /// Số khung có header nhưng sai checksum/cấu trúc (đã bị loại).
    public internal(set) var rejectedFrames = 0
    public internal(set) var lastFrameAt: Date?
    public internal(set) var lastRejectReason: String?

    public var hasAcceptedFrame: Bool { acceptedFrames > 0 }

    /// Hãng đã khóa sau khung hợp lệ đầu tiên.
    private var lockedBrand: String?

    public init(mode: Mode = .auto) {
        self.mode = mode
    }

    public func reset() {
        buffer.removeAll(keepingCapacity: false)
        deviceInfo = BMSDeviceInfo()
        settingsInfo = BMSSettingsInfo()
        live = BMSLiveTelemetry()
        hasDeviceInfo = false
        hasSettingsInfo = false
        hasCellInfo = false
        bmsBrand = Self.unknownBrand
        deviceInfoProvenance = BMSDeviceInfoProvenance()
        lockedBrand = nil
        totalBytes = 0
        acceptedFrames = 0
        rejectedFrames = 0
        lastFrameAt = nil
        lastRejectReason = nil
    }

    /// Nhận một mảnh dữ liệu BLE (hoặc toàn bộ một frame) rồi xử lý hết
    /// buffer. Trả về danh sách loại frame được giải mã theo thứ tự.
    @discardableResult
    public func feed(_ chunk: Data) -> [BmsFrameEvent] {
        totalBytes += chunk.count
        buffer.append(contentsOf: chunk)
        var events: [BmsFrameEvent] = []

        while buffer.count >= 7 {

            // 1. Khung JK-BMS (300 byte, 55 AA EB 90, CRC8 cuối).
            if buffer[0] == 0x55 && buffer[1] == 0xAA
                && buffer[2] == 0xEB && buffer[3] == 0x90 {
                if buffer.count < 300 { break }
                let frame = Array(buffer[0..<300])
                guard BMSChecksum.isJKFrameValid(frame) else {
                    reject("JK: CRC8 sai")
                    buffer.removeFirst(1)
                    continue
                }
                guard canAccept(.jk) else {
                    reject("JK: đang khóa hãng khác")
                    buffer.removeFirst(300)
                    continue
                }
                buffer.removeFirst(300)
                decodeJK(frame)
                markAccepted(.jk)
                events.append(.jk)
                continue
            }

            // 2. Khung ANT-BMS (140 byte, AA 55 AA FF, checksum 16-bit @138).
            if buffer[0] == 0xAA && buffer[1] == 0x55
                && buffer[2] == 0xAA && buffer[3] == 0xFF {
                if buffer.count < 140 { break }
                let frame = Array(buffer[0..<140])
                let stored = be16(frame, 138)
                guard stored == BMSChecksum.antChecksum(frame) else {
                    reject("ANT: checksum 16-bit sai")
                    buffer.removeFirst(1)
                    continue
                }
                guard canAccept(.ant) else {
                    reject("ANT: đang khóa hãng khác")
                    buffer.removeFirst(140)
                    continue
                }
                buffer.removeFirst(140)
                decodeANT(frame)
                markAccepted(.ant)
                events.append(.ant)
                continue
            }

            // 3. Khung JBD (DD <cmd> <status> <len> <data> 77).
            // Chỉ nhận đúng 3 lệnh đã biết; trước đây mọi khung 0xDD đều
            // bị coi là JBD nên nhiễu có thể khóa nhầm hãng.
            if buffer[0] == 0xDD {
                let cmd = buffer[1]
                let status = buffer[2]
                guard cmd == 0x03 || cmd == 0x04 || cmd == 0x05,
                      status <= 1 else {
                    reject("JBD: cmd/status không hợp lệ")
                    buffer.removeFirst(1)
                    continue
                }
                let dataLength = Int(buffer[3])
                let packetLength = dataLength + 7
                guard dataLength > 0, dataLength <= 64 else {
                    reject("JBD: độ dài vô lý (\(dataLength))")
                    buffer.removeFirst(1)
                    continue
                }
                if buffer.count < packetLength {
                    break                       // đợi thêm dữ liệu
                }
                guard buffer[packetLength - 1] == 0x77 else {
                    reject("JBD: thiếu trailer 0x77")
                    buffer.removeFirst(1)
                    continue
                }
                if cmd == 0x04 && dataLength % 2 != 0 {
                    reject("JBD 0x04: độ dài cell lẻ")
                    buffer.removeFirst(1)
                    continue
                }
                if cmd == 0x03 && dataLength < 21 {
                    reject("JBD 0x03: khung quá ngắn")
                    buffer.removeFirst(1)
                    continue
                }
                let frame = Array(buffer[0..<packetLength])

                if cmd == 0x03 {
                    // Kiểm tra hợp lý tối thiểu trước khi khóa hãng.
                    let total = Double(be16(frame, 4)) * 0.01
                    let soc = Int(frame[23])
                    guard total > 0, total <= 120, soc <= 100 else {
                        reject("JBD 0x03: điện áp/SOC không hợp lý")
                        buffer.removeFirst(1)
                        continue
                    }
                }
                if cmd == 0x05 {
                    let name = readCString(frame, 4, dataLength)
                    guard !name.isEmpty,
                          name.unicodeScalars.allSatisfy(\.isASCII) else {
                        reject("JBD 0x05: tên thiết bị không hợp lệ")
                        buffer.removeFirst(1)
                        continue
                    }
                }

                guard canAccept(.jbd) else {
                    reject("JBD: đang khóa hãng khác")
                    buffer.removeFirst(packetLength)
                    continue
                }
                buffer.removeFirst(packetLength)
                decodeJBD(frame)
                markAccepted(.jbd)
                events.append(.jbd)
                continue
            }

            // 4. Khung Daly (A5 01/40, 13 byte, checksum cuối).
            if buffer[0] == 0xA5 && (buffer[1] == 0x01 || buffer[1] == 0x40) {
                if buffer.count < 13 { break }
                let frame = Array(buffer[0..<13])
                var total = 0
                for i in 0..<12 { total += Int(frame[i]) }
                let checksumOK = (total & 0xFF) == Int(frame[12])
                let cmd = frame[2]
                let voltage = Double(be16(frame, 4)) * 0.1
                let socRaw = be16(frame, 10)
                guard checksumOK, cmd == 0x90,
                      voltage > 0, voltage <= 120, socRaw <= 1000 else {
                    reject("Daly: checksum/cmd/dữ liệu không hợp lệ")
                    buffer.removeFirst(1)
                    continue
                }
                guard canAccept(.daly) else {
                    reject("Daly: đang khóa hãng khác")
                    buffer.removeFirst(13)
                    continue
                }
                buffer.removeFirst(13)
                decodeDaly(frame)
                markAccepted(.daly)
                events.append(.daly)
                continue
            }

            // 5. Trượt tìm byte mào đầu tiềm năng (giống bản gốc).
            var found = -1
            for idx in 1..<buffer.count {
                let byteData = buffer[idx]
                if byteData == 0x55 || byteData == 0xAA
                    || byteData == 0xDD || byteData == 0xA5 {
                    found = idx
                    break
                }
            }
            if found > 0 {
                buffer.removeFirst(found)
            } else {
                if buffer.count > 3 { buffer.removeFirst(buffer.count - 3) }
                break
            }
        }

        if buffer.count > 2048 {
            lastRejectReason = "Buffer vượt 2048 byte — đã xóa để đồng bộ lại"
            buffer.removeAll(keepingCapacity: false)
        }
        return events
    }

    // ------------------------------------------------------------- private

    private func brandName(for event: BmsFrameEvent) -> String {
        switch event {
        case .jk: return "JK-BMS"
        case .ant: return "ANT-BMS"
        case .jbd: return "JBD BMS"
        case .daly: return "Daly BMS"
        }
    }

    private func canAccept(_ event: BmsFrameEvent) -> Bool {
        guard let lockedBrand else { return true }
        return lockedBrand == brandName(for: event)
    }

    private func markAccepted(_ event: BmsFrameEvent) {
        if lockedBrand == nil {
            lockedBrand = brandName(for: event)
        }
        acceptedFrames += 1
        lastFrameAt = Date()
    }

    private func reject(_ reason: String) {
        rejectedFrames += 1
        lastRejectReason = reason
    }
}
