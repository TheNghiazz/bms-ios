// Formatting.swift
// Port của format_duration / format_eta_hours (dòng 192-206 Python gốc)
// và logic ETA của GUI (dòng 992-1016) dưới dạng hàm thuần để test được.
// Đã SỬA bug c.socPercent (dòng 998 bản gốc) -> socPercent.

import Foundation

public enum BMSFormatting {
    /// "2 ngày 03:30:00"
    public static func formatDuration(seconds: Int) -> String {
        let total = max(0, seconds)
        let days = total / 86_400
        let rem = total % 86_400
        let hours = rem / 3_600
        let minutes = (rem % 3_600) / 60
        let secs = rem % 60
        return String(format: "%d ngày %02d:%02d:%02d", days, hours, minutes, secs)
    }

    /// "1 giờ 05 phút" / "45 phút" / "0 phút"
    public static func formatEtaHours(_ hours: Double) -> String {
        guard hours > 0, hours < 9_999 else { return "0 phút" }   // 0 < h < 9999
        let totalMinutes: Int
        totalMinutes = Int((hours * 60.0).rounded())
        let hrs = totalMinutes / 60
        let mins = totalMinutes % 60
        if hrs > 0 {
            return String(format: "%d giờ %02d phút", hrs, mins)
        }
        return "\(mins) phút"
    }
}

public enum BMSEtaState: Equatable, Sendable {
    case charging
    case discharging
    case standby
}

public struct BMSEtaResult: Equatable, Sendable {
    public let state: BMSEtaState
    /// Dòng cần nạp/xả thêm (Ah) và năng lượng tương ứng (Wh)
    public let needAh: Double
    public let needWh: Double
    /// Dòng điện đã trừ của kết quả ETA tính bằng giờ (nil khi standby/không xác định)
    public let etaHours: Double?
}

public enum BMSEtaEstimator {
    /// Chạy chuẩn: bản gốc dùng hệ số 1.08 cho hiệu suất sạc.
    public static func estimate(_ live: BMSLiveTelemetry) -> BMSEtaResult {
        estimate(live, chargeEfficiencyFactor: 1.08)
    }

    public static func estimate(
        _ live: BMSLiveTelemetry,
        chargeEfficiencyFactor: Double
    ) -> BMSEtaResult {
        let needAh = max(0.0, live.nominalCapacityAh - live.remainingCapacityAh)
        let needWh = needAh * live.totalVoltageV

        if live.currentA > 0.05 {
            // Đang sạc
            let etaHours: Double?
            if needAh <= 0.05 || live.socPercent >= 100 {
                etaHours = nil        // đã sạc đầy
            } else {
                etaHours = (needAh / live.currentA) * chargeEfficiencyFactor
            }
            return BMSEtaResult(state: .charging, needAh: needAh, needWh: needWh, etaHours: etaHours)

        } else if live.currentA < -0.05 {
            // Đang xả
            let etaHours = live.remainingCapacityAh / abs(live.currentA)
            return BMSEtaResult(state: .discharging, needAh: needAh, needWh: needWh, etaHours: etaHours)

        } else {
            // Chờ
            return BMSEtaResult(state: .standby, needAh: needAh, needWh: needWh, etaHours: nil)
        }
    }
}
