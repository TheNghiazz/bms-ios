// ANTDecoder.swift
// Port của decode_ant_frame (dòng 431-497 Python gốc).
// Khung 140 byte big-endian, header AA 55 AA FF (bản gốc KHÔNG kiểm checksum).

extension UniversalBmsParser {

    func decodeANT(_ data: [UInt8]) {
        guard data.count >= 140 else { return }
        bmsBrand = "ANT-BMS"
        live.detectedBrand = "ANT-BMS"
        live.protocolVersion = "ANT-BMS (140B)"

        deviceInfo.vendorId = "ANT-BMS (Mayi/JNFN)"
        if deviceInfo.deviceName.isEmpty { deviceInfo.deviceName = "ANT-BMS" }
        deviceInfo.devicePasscode = "123456 (Mặc định)"
        deviceInfo.setupPasscode = "123456 (Mặc định)"

        var c = live
        c.totalVoltageV = round3(Double(be16(data, 4)) * 0.1)

        var volts: [Double] = []
        var resistances: [Double] = []
        var minV = 999.0
        var maxV = -999.0
        var minIdx = 0
        var maxIdx = 0

        for i in 0..<32 {
            let v = round3(Double(be16(data, 6 + i * 2)) * 0.001)
            if v > 0.05 && v < 5.0 {
                volts.append(v)
                resistances.append(0.04)      // ANT không gửi nội trở thật
                if v < minV { minV = v; minIdx = i + 1 }
                if v > maxV { maxV = v; maxIdx = i + 1 }
            }
        }

        c.cellVoltagesV = volts
        c.cellResistancesOhm = resistances
        c.activeCellCount = volts.count
        if !volts.isEmpty {
            c.averageCellVoltageV = round3(volts.reduce(0.0, +) / Double(volts.count))
            c.minCellVoltageV = minV
            c.maxCellVoltageV = maxV
            c.deltaCellVoltageV = round3(maxV - minV)
            c.minVoltageCellNum = minIdx
            c.maxVoltageCellNum = maxIdx
        }

        c.currentA = round2(Double(i32be(data, 70)) * 0.1)
        c.powerW = round1(c.totalVoltageV * c.currentA)
        c.socPercent = min(100, max(0, Int(data[74])))

        let nomRaw = be32(data, 75)
        let remRaw = be32(data, 79)
        let nom = nomRaw > 500000 ? Double(nomRaw) * 0.000001
            : (nomRaw > 1000 ? Double(nomRaw) * 0.001 : Double(nomRaw))
        let rem = remRaw > 500000 ? Double(remRaw) * 0.000001
            : (remRaw > 1000 ? Double(remRaw) * 0.001 : Double(remRaw))
        c.nominalCapacityAh = round2(nom > 0 ? nom : 30.0)
        c.remainingCapacityAh = round2(rem > 0 ? rem : 25.0)

        c.cycleCount = be32(data, 83)
        c.runtimeSeconds = be32(data, 87)
        deviceInfo.uptimeSeconds = c.runtimeSeconds

        c.tempSensor1C = Double(i16be(data, 91))
        c.tempSensor2C = Double(i16be(data, 93))
        c.mosfetTempC = Double(i16be(data, 99))

        c.chargingMosOn = data[101] != 0
        c.dischargingMosOn = data[102] != 0
        c.balancingAction = Int(data[103])
        c.balancingStatusText = c.balancingAction != 0 ? "Đang cân bằng" : "Tắt (Idle)"
        c.sohPercent = 100

        live = c
        hasCellInfo = true
        hasDeviceInfo = true
    }
}
