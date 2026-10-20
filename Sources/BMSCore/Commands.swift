// Commands.swift
// Khung lệnh gửi xuống BMS + UUID các service/characteristic BLE.

public enum BLEServiceIDs {
    /// JK-BMS: service FFE0, notify/write FFE1, hint log FFE2
    public static let jkFFE0 = "0000ffe0-0000-1000-8000-00805f9b34fb"
    public static let jkFFE1 = "0000ffe1-0000-1000-8000-00805f9b34fb"
    public static let jkFFE2 = "0000ffe2-0000-1000-8000-00805f9b34fb"

    /// Daly: service FFF0
    public static let dalyFFF0 = "0000fff0-0000-1000-8000-00805f9b34fb"

    /// JBD / Xiaoxiang: service FF00 (characteristic FF01/FF02 tuỳ firmware)
    public static let jbdFF00 = "0000ff00-0000-1000-8000-00805f9b34fb"

    /// ANT-BMS dùng service/characteristic do thiết bị tự kê khai
    /// (chọn characteristic đầu tiên có notify như logic trong GUI gốc).
}

public enum BMSCommand {
    /// Lệnh đánh thức ANT-BMS (CMD_ANT_WAKEUP): 5A 5A 00 00 00 00
    public static let antWakeup: [UInt8] = [0x5A, 0x5A, 0x00, 0x00, 0x00, 0x00]

    /// Mã lệnh JK: 0x96 = cell info (dữ liệu live), 0x97 = device info.
    public static let jkCellInfoCmd: UInt8 = 0x96
    public static let jkDeviceInfoCmd: UInt8 = 0x97

    /// Dựng khung lệnh JK 20 byte (build_jk_command_frame trong bản gốc):
    /// AA 55 90 EB | cmd | 00 ...(114 byte đệm)... | counter @16 | CRC @19
    public static func jkFrame(cmd: UInt8, counter: UInt8 = 1) -> [UInt8] {
        var frame = [UInt8](repeating: 0x00, count: 20)
        frame[0] = 0xAA
        frame[1] = 0x55
        frame[2] = 0x90
        frame[3] = 0xEB
        frame[4] = cmd & 0xFF
        frame[16] = counter & 0xFF
        frame[19] = UInt8(BMSChecksum.sum8(frame[0..<19]))
        return frame
    }
}
