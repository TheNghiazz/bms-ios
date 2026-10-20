// ByteIO.swift
// Trợ giúp đọc số liệu theo đúng ngữ nghĩa của struct.unpack_from trong Python.
// Lưu ý: các hàm trả về 0 khi đọc ra ngoài phạm vi (phòng chống crash) —
// các decoder bắt buộc tự guard độ dài trước khi gọi.

@inline(__always) func le16u(_ b: [UInt8], _ o: Int) -> UInt16 {
    guard o >= 0, o + 1 < b.count else { return 0 }
    return UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
}

@inline(__always) func le16(_ b: [UInt8], _ o: Int) -> Int {
    guard o >= 0, o + 1 < b.count else { return 0 }
    return Int(b[o]) | (Int(b[o + 1]) << 8)      // giống "<H": khối không dấu
}

@inline(__always) func i16le(_ b: [UInt8], _ o: Int) -> Int {
    guard o >= 0, o + 1 < b.count else { return 0 }
    return Int(Int16(bitPattern: le16u(b, o)))   // giống "<h"
}

@inline(__always) func le32u(_ b: [UInt8], _ o: Int) -> UInt32 {
    guard o >= 0, o + 3 < b.count else { return 0 }
    return UInt32(b[o]) | (UInt32(b[o + 1]) << 8)
        | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
}

@inline(__always) func le32(_ b: [UInt8], _ o: Int) -> Int {
    guard o >= 0, o + 3 < b.count else { return 0 }
    return Int(le32u(b, o))                      // giống "<I": không dấu
}

@inline(__always) func i32le(_ b: [UInt8], _ o: Int) -> Int {
    guard o >= 0, o + 3 < b.count else { return 0 }
    return Int(Int32(bitPattern: le32u(b, o)))   // giống "<i"
}

@inline(__always) func be16u(_ b: [UInt8], _ o: Int) -> UInt16 {
    guard o >= 0, o + 1 < b.count else { return 0 }
    return (UInt16(b[o]) << 8) | UInt16(b[o + 1])
}

@inline(__always) func be16(_ b: [UInt8], _ o: Int) -> Int {
    guard o >= 0, o + 1 < b.count else { return 0 }
    return (Int(b[o]) << 8) | Int(b[o + 1])      // giống ">H"
}

@inline(__always) func i16be(_ b: [UInt8], _ o: Int) -> Int {
    guard o >= 0, o + 1 < b.count else { return 0 }
    return Int(Int16(bitPattern: be16u(b, o)))   // giống ">h"
}

@inline(__always) func be32u(_ b: [UInt8], _ o: Int) -> UInt32 {
    guard o >= 0, o + 3 < b.count else { return 0 }
    return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16)
        | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
}

@inline(__always) func be32(_ b: [UInt8], _ o: Int) -> Int {
    guard o >= 0, o + 3 < b.count else { return 0 }
    return Int(be32u(b, o))                      // giống ">I"
}

@inline(__always) func i32be(_ b: [UInt8], _ o: Int) -> Int {
    guard o >= 0, o + 3 < b.count else { return 0 }
    return Int(Int32(bitPattern: be32u(b, o)))   // giống ">i"
}

/// Đọc chuỗi ASCII kết thúc bằng \0, loại khoảng trắng hai đầu (giống
/// read_c_string: decode utf-8 (errors=replace) + .strip()).
func readCString(_ b: [UInt8], _ start: Int, _ maxLength: Int) -> String {
    guard start >= 0, start < b.count else { return "" }
    let upper = min(start + max(0, maxLength), b.count)
    var raw = Array(b[start..<upper])
    if let nullPos = raw.firstIndex(of: 0) {
        raw = Array(raw[..<nullPos])
    }
    let text = String(decoding: raw, as: UTF8.self)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Chuỗi rỗng -> giá trị mặc định (giống `x or default` của Python).
@inline(__always) func nonEmpty(_ value: String, _ fallback: String) -> String {
    return value.isEmpty ? fallback : value
}

/// Làm tròn kiểu Python round(x, n) cho n = 1..3 (IEEE double ở cả hai
/// ngôn ngữ, bước nhân/chia là phép nhân số nguyên nên kết quả trùng khớp).
@inline(__always) func roundTo(_ x: Double, _ digits: Int) -> Double {
    switch digits {
    case 0: return x.rounded()
    case 1: return (x * 10.0).rounded() / 10.0
    case 2: return (x * 100.0).rounded() / 100.0
    case 3: return (x * 1000.0).rounded() / 1000.0
    default: return x
    }
}

@inline(__always) func round1(_ x: Double) -> Double { roundTo(x, 1) }
@inline(__always) func round2(_ x: Double) -> Double { roundTo(x, 2) }
@inline(__always) func round3(_ x: Double) -> Double { roundTo(x, 3) }
