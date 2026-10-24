// JBDDecoder.swift
// Port của decode_jbd_frame (dòng 499-528 Python gốc).
// Khung: DD <cmd> <status> <len> <data...> 77  (trailer 0x77 là kiểm tra duy nhất).
// LƯU Ý: bản gốc không set vùng min/max cell cho JBD (max/minVoltageCellNumber
// giữ 0) — port giữ đúng hành vi để khớp golden vectors.

extension UniversalBmsParser {

    func decodeJBD(_ data: [UInt8]) {
        guard data.count >= 4 else { return }
        let cmd = data[1]
        bmsBrand = "JBD BMS"
        live.detectedBrand = "JBD BMS"
        deviceInfo.vendorId = "JBD / Xiaoxiang BMS"

        var c = live

        if cmd == 0x03 {
            guard data.count >= 25 else { return }    // cần tới data[24]
            c.totalVoltageV = round3(Double(be16(data, 4)) * 0.01)
            c.currentA = round2(Double(i16be(data, 6)) * 0.01)
            c.powerW = round1(c.totalVoltageV * c.currentA)
            c.remainingCapacityAh = round2(Double(be16(data, 8)) * 0.01)
            c.nominalCapacityAh = round2(Double(be16(data, 10)) * 0.01)
            c.cycleCount = be16(data, 12)
            c.socPercent = Int(data[23])
            let mos = Int(data[24])
            c.chargingMosOn = (mos & 0x01) != 0
            c.dischargingMosOn = (mos & 0x02) != 0
            live = c
            hasCellInfo = true

        } else if cmd == 0x04 {
            let cellCount = Int(data[3]) / 2
            guard cellCount > 0, data.count >= 4 + cellCount * 2 else { return }
            let raw: [Double] = (0..<cellCount).map {
                round3(Double(be16(data, 4 + $0 * 2)) * 0.001)
            }
            c.cellVoltagesV = raw.filter { $0 > 0.05 }
            c.activeCellCount = c.cellVoltagesV.count
            if !c.cellVoltagesV.isEmpty {
                c.averageCellVoltageV =
                    round3(c.cellVoltagesV.reduce(0.0, +) / Double(c.cellVoltagesV.count))
                c.minCellVoltageV = c.cellVoltagesV.min() ?? 0.0
                c.maxCellVoltageV = c.cellVoltagesV.max() ?? 0.0
                c.deltaCellVoltageV = round3(c.maxCellVoltageV - c.minCellVoltageV)
            }
            live = c
            hasCellInfo = true

        } else if cmd == 0x05 {
            // 0x05: tên thiết bị dạng chuỗi ASCII.
            let length = Int(data[3])
            guard length > 0, data.count >= 4 + length else { return }
            let name = readCString(data, 4, length)
            guard !name.isEmpty else { return }
            deviceInfo.deviceName = name
            var prov = deviceInfoProvenance
            prov.markString(.deviceName, name)
            deviceInfoProvenance = prov
            hasDeviceInfo = true
        }
    }
}
