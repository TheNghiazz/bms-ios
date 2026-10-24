// Checksums.swift
// Trợ giúp kiểm tra khung truyền cho các hãng.
// - JK: CRC8 = tổng byte [0..<299] & 0xFF so với byte 299.
// - Daly: tổng byte [0..<12] & 0xFF so với byte 12.
// - JBD: parser kiểm cấu trúc/trailer (firmware dùng biến thể CRC khác nhau).
// - ANT: checksum 2-byte big-endian tại offset 138 =
//   sum(byte[4..<138]) & 0xFFFF (parser bắt buộc kiểm).

public enum BMSChecksum {
    /// CRC8 kiểu JK: tổng các byte & 0xFF (calc_crc8 trong bản gốc).
    public static func sum8<S: Sequence>(_ bytes: S) -> Int where S.Element == UInt8 {
        var total = 0
        for byte in bytes { total += Int(byte) }
        return total & 0xFF
    }

    /// Kiểm tra khung JK 300 byte.
    public static func isJKFrameValid(_ frame: [UInt8]) -> Bool {
        guard frame.count >= 300 else { return false }
        return sum8(frame[0..<299]) == Int(frame[299])
    }

    /// Kiểm tra khung Daly 13 byte.
    public static func isDalyFrameValid(_ frame: [UInt8]) -> Bool {
        guard frame.count >= 13 else { return false }
        var total = 0
        for i in 0..<12 { total += Int(frame[i]) }
        return (total & 0xFF) == Int(frame[12])
    }

    /// Checksum 16-bit của khung ANT 140 byte: tổng byte[4..<138] & 0xFFFF,
    /// được ghi big-endian tại offset 138 trong khung của thiết bị thật.
    public static func antChecksum(_ frame: [UInt8]) -> Int {
        var total = 0
        for i in 4..<138 where i + 1 < frame.count {
            total += Int(frame[i])
        }
        return total & 0xFFFF
    }
}
