// DalyDecoder.swift
// Port của decode_daly_frame (dòng 530-540 Python gốc).
// Khung 13 byte: A5 <0x01|0x40> <cmd> ... checksum byte cuối = tổng [0..<12] & 0xFF.
// Hiện chỉ đọc khung 0x90 (điện áp / dòng / SOC); chưa có cell voltage.

extension UniversalBmsParser {

    func decodeDaly(_ data: [UInt8]) {
        guard data.count >= 13 else { return }
        let cmd = data[2]
        guard cmd == 0x90 else { return }   // khung khác 0x90: bỏ qua (giữ nguyên)
        bmsBrand = "Daly BMS"
        live.detectedBrand = "Daly BMS"

        var c = live
        let voltage10 = (Int(data[4]) << 8) | Int(data[5])
        let currentRaw = (Int(data[8]) << 8) | Int(data[9])
        let socRaw = (Int(data[10]) << 8) | Int(data[11])

        c.totalVoltageV = round2(Double(voltage10) * 0.1)
        c.currentA = round2(Double(currentRaw - 30000) * 0.1)
        c.powerW = round1(c.totalVoltageV * c.currentA)
        c.socPercent = Int((Double(socRaw) * 0.1).rounded())
        live = c
        hasCellInfo = true
    }
}
