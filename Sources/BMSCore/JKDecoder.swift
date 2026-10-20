// JKDecoder.swift
// Port của decode_jk_frame (dòng 313-429 Python gốc).
// Khung 300 byte: header 55 AA EB 90, CRC8. Loại tăng [4]:
//   0x03 device info, 0x01 settings, 0x02 cell info.
// Nhánh JK02_32S (SW chứa "11." hoặc "12.") dịch các offset của frame 0x02:
//   offset1 = +16 (khối nội trở), offset2 = +32 (các trường diện rộng).

import Foundation   // chỉ dùng Double.rounded

extension UniversalBmsParser {

    func decodeJK(_ data: [UInt8]) {
        guard data.count >= 300 else { return }   // khung phải đủ 300 byte
        let frameType = data[4]
        bmsBrand = "JK-BMS"
        live.detectedBrand = "JK-BMS"

        if frameType == 0x03 {
            let d = deviceInfo
            var updated = d
            updated.vendorId = nonEmpty(readCString(data, 6, 16), "JK-BMS")
            updated.hardwareVersion = nonEmpty(readCString(data, 22, 8), "N/A")
            updated.softwareVersion = nonEmpty(readCString(data, 30, 8), "N/A")
            updated.uptimeSeconds = le32(data, 38)
            updated.powerOnCount = le32(data, 42)
            updated.deviceName = nonEmpty(readCString(data, 46, 16), "JK-BMS")
            updated.devicePasscode = nonEmpty(readCString(data, 62, 16), "1234")

            let mfg = readCString(data, 78, 8)
            if mfg.count == 6 && mfg.allSatisfy({ $0.isASCII && $0.isNumber }) {
                let yy = String(mfg.prefix(2))
                let mm = String(mfg.dropFirst(2).prefix(2))
                let dd = String(mfg.dropFirst(4).prefix(2))
                updated.manufacturingDate = "20\(yy)-\(mm)-\(dd)"
            } else {
                updated.manufacturingDate = mfg
            }
            updated.serialNumber = nonEmpty(readCString(data, 86, 11), "N/A")
            updated.passcode = nonEmpty(readCString(data, 97, 5), "0000")
            updated.userData = nonEmpty(readCString(data, 102, 16), "N/A")
            updated.setupPasscode = nonEmpty(readCString(data, 118, 16), "123456")
            deviceInfo = updated

            let sw = updated.softwareVersion
            live.protocolVersion =
                (sw.contains("11.") || sw.contains("12.")) ? "JK02_32S" : "JK02_24S"
            hasDeviceInfo = true

        } else if frameType == 0x01 {
            guard data.count >= 142 else { return }   // 138+4
            var s = settingsInfo
            s.smartSleepVoltageV = round3(Double(le32(data, 6)) * 0.001)
            s.cellUvpV = round3(Double(le32(data, 10)) * 0.001)
            s.cellUvprV = round3(Double(le32(data, 14)) * 0.001)
            s.cellOvpV = round3(Double(le32(data, 18)) * 0.001)
            s.cellOvprV = round3(Double(le32(data, 22)) * 0.001)
            s.balanceTriggerVoltageV = round3(Double(le32(data, 26)) * 0.001)
            s.powerOffVoltageV = round3(Double(le32(data, 46)) * 0.001)
            s.maxChargeCurrentA = round3(Double(le32(data, 50)) * 0.001)
            s.maxDischargeCurrentA = round3(Double(le32(data, 62)) * 0.001)
            s.maxBalanceCurrentA = round3(Double(le32(data, 78)) * 0.001)
            s.cellCountConfigured = Int(data[114])
            s.chargeSwitchEnabled = data[118] != 0
            s.dischargeSwitchEnabled = data[122] != 0
            s.balancerSwitchEnabled = data[126] != 0
            s.nominalCapacityAh = round3(Double(le32(data, 130)) * 0.001)
            s.startBalanceVoltageV = round3(Double(le32(data, 138)) * 0.001)
            settingsInfo = s
            hasSettingsInfo = true

        } else if frameType == 0x02 {
            let is32S = live.protocolVersion == "JK02_32S"
            let offset1 = is32S ? 16 : 0      // dịch khối nội trở
            let offset2 = is32S ? 32 : 0      // dịch các trường còn lại
            let maxCells = is32S ? 32 : 24
            // Chỉ số cao nhất dùng: 168+offset2 (flags) -> cần >= 169+offset2
            guard data.count >= (is32S ? 201 : 169) else { return }

            var volts: [Double] = []
            var resistances: [Double] = []
            var minV = 999.0
            var maxV = -999.0
            var minIdx = 0
            var maxIdx = 0

            for idx in 0..<maxCells {
                let v = round3(Double(le16(data, 6 + idx * 2)) * 0.001)
                let r = round3(Double(le16(data, 64 + offset1 + idx * 2)) * 0.001)
                if v > 0.05 {
                    volts.append(v)
                    resistances.append(r)
                    if v < minV { minV = v; minIdx = idx + 1 }
                    if v > maxV { maxV = v; maxIdx = idx + 1 }
                }
            }

            var c = live
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

            c.totalVoltageV = round3(Double(le32(data, 118 + offset2)) * 0.001)
            c.currentA = round3(Double(i32le(data, 126 + offset2)) * 0.001)
            c.powerW = round2(c.totalVoltageV * c.currentA)

            c.tempSensor1C = round1(Double(i16le(data, 130 + offset2)) * 0.1)
            c.tempSensor2C = round1(Double(i16le(data, 132 + offset2)) * 0.1)

            let maxErrBits: Int
            if is32S {
                c.mosfetTempC = round1(Double(i16le(data, 112 + offset2)) * 0.1)
                c.errorsBitmask = le32(data, 134 + offset2)
                maxErrBits = 32
            } else {
                c.mosfetTempC = round1(Double(i16le(data, 134 + offset2)) * 0.1)
                c.errorsBitmask = le16(data, 136 + offset2)
                maxErrBits = 16
            }

            c.errorMessages = (0..<maxErrBits)
                .filter { (c.errorsBitmask & (1 << $0)) != 0 }
                .map { BMSErrorBit.label(for: $0) }

            c.balanceCurrentA = round3(Double(i16le(data, 138 + offset2)) * 0.001)
            c.balancingAction = Int(data[140 + offset2])
            c.balancingStatusText =
                c.balancingAction == 1 ? "CB Nạp"
                : (c.balancingAction == 2 ? "CB Xả" : "Tắt (Idle)")
            c.socPercent = Int(data[141 + offset2])
            c.remainingCapacityAh = round3(Double(le32(data, 142 + offset2)) * 0.001)
            c.nominalCapacityAh = round3(Double(le32(data, 146 + offset2)) * 0.001)
            c.cycleCount = le32(data, 150 + offset2)
            c.totalCycleCapacityAh = round3(Double(le32(data, 154 + offset2)) * 0.001)
            c.sohPercent = Int(data[158 + offset2])
            c.runtimeSeconds = le32(data, 162 + offset2)

            c.chargingMosOn = data[166 + offset2] != 0
            c.dischargingMosOn = data[167 + offset2] != 0
            c.prechargingOn = data[168 + offset2] != 0
            live = c
            hasCellInfo = true
        }
    }
}
