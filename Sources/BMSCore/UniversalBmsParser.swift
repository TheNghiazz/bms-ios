// UniversalBmsParser.swift
// Port của UniversalBmsParser trong bản gốc (dòng 212-540 Python).
// Logic đồng bộ khung trượt (sliding buffer) được giữ y nguyên; khác biệt
// duy nhất (có chủ đích, xem docs/protocol.md):
//   1. feed() xử lý HẾT buffer và trả về toàn bộ frame nhận được — bản gốc
//      `return` sau frame đầu nên frame kế bị đợi lượt feed sau.
//   2. Namespaced enum BmsFrameEvent thay cho chuỗi trả về.

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

    public private(set) var buffer: [UInt8] = []
    public private(set) var deviceInfo = BMSDeviceInfo()
    public private(set) var settingsInfo = BMSSettingsInfo()
    public private(set) var live = BMSLiveTelemetry()

    public private(set) var hasDeviceInfo = false
    public private(set) var hasSettingsInfo = false
    public private(set) var hasCellInfo = false
    public private(set) var bmsBrand: String = Self.unknownBrand

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
    }

    /// Nhận một mảnh dữ liệu BLE ( hoặc toàn bộ một frame) rồi xử lý
    /// hết buffer. Trả về danh sách loại frame được giải mã theo thứ tự.
    @discardableResult
    public func feed(_ chunk: Data) -> [BmsFrameEvent] {
        buffer.append(contentsOf: chunk)
        var events: [BmsFrameEvent] = []

        while buffer.count >= 13 {
            // 1. Khung JK-BMS (300 byte, 55 AA EB 90, CRC8 cuối)
            if buffer[0] == 0x55 && buffer[1] == 0xAA
                && buffer[2] == 0xEB && buffer[3] == 0x90 {
                if buffer.count < 300 { break }
                let frame = Array(buffer[0..<300])
                if BMSChecksum.sum8(frame[0..<299]) == Int(frame[299]) {
                    buffer.removeFirst(300)
                    decodeJK(frame)
                    events.append(.jk)
                } else {
                    buffer.removeFirst(1)   // CRC sai -> trượt 1 byte
                }
                continue
            }

            // 2. Khung ANT-BMS (140 byte, AA 55 AA FF)
            // (Bản gốc KHÔNG kiểm checksum; giữ nguyên hành vi.)
            if buffer[0] == 0xAA && buffer[1] == 0x55
                && buffer[2] == 0xAA && buffer[3] == 0xFF {
                if buffer.count < 140 { break }
                let frame = Array(buffer[0..<140])
                buffer.removeFirst(140)
                decodeANT(frame)
                events.append(.ant)
                continue
            }

            // 3. Khung JBD (DD ... 77), độ dài = data[3] + 7
            if buffer[0] == 0xDD {
                guard buffer.count >= 7 else { break }
                let dataLength = Int(buffer[3])
                let packetLength = dataLength + 7
                if buffer.count < packetLength {
                    if packetLength > 300 {
                        buffer.removeFirst(1)   // độ dài vô lý -> trượt 1 byte
                        continue
                    }
                    break                       // đợi thêm dữ liệu
                }
                if buffer[packetLength - 1] == 0x77 {
                    let frame = Array(buffer[0..<packetLength])
                    buffer.removeFirst(packetLength)
                    decodeJBD(frame)
                    events.append(.jbd)
                } else {
                    buffer.removeFirst(1)       // trailer sai -> trượt
                }
                continue
            }

            // 4. Khung Daly (A5 01/40, 13 byte, checksum cuối)
            if buffer[0] == 0xA5 && (buffer[1] == 0x01 || buffer[1] == 0x40) {
                if buffer.count < 13 { break }
                var total = 0
                for i in 0..<12 { total += Int(buffer[i]) }
                if (total & 0xFF) == Int(buffer[12]) {
                    let frame = Array(buffer[0..<13])
                    buffer.removeFirst(13)
                    decodeDaly(frame)
                    events.append(.daly)
                } else {
                    buffer.removeFirst(1)
                }
                continue
            }

            // 5. Trượt tìm byte mào đầu tiềm năng (giống bản gốc)
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

        if buffer.count > 2048 { buffer.removeAll(keepingCapacity: false) }
        return events
    }
}
