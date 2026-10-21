// DashboardView.swift
// SVG v1: khung dashboard tối giản nhưng đủ dùng — hiện số liệu live/demo,
// banner ETA, SOC gauge, grid cell, thông tin thiết bị. Phase 5 sẽ nâng cấp
// chi tiết (metric cards xịn như bản Tkinter).

import BMSCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: BMSStore

    var body: some View {
        content
            .background(Color.bmsBg.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        // revision đọc để view biết render lại khi parser đổi
        let _ = store.revision
        let live = store.live
        let eta = store.eta

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statusCard
                infoStrip(live: live)
                etaBanner(live: live, eta: eta)
                socGaugeCard(live: live)
                metricsGrid(live: live)
                cellsGrid(live: live)
                deviceInfoCard
                if let error = store.session.lastError {
                    Text("⚠️ \(error)")
                        .font(.footnote)
                        .foregroundStyle(Color.bmsRose)
                }
                Text("· Dữ liệu demo nếu chưa kết nối BLE thật")
                    .font(.caption2)
                    .foregroundStyle(Color.bmsMuted)
            }
            .padding()
        }
    }

    // --------------------------------------------------------------- cards
    private var statusCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(store.isLive ? Color.bmsGreen : Color.bmsAmber)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading) {
                Text(store.session.status)
                    .font(.footnote)
                    .foregroundStyle(Color.bmsText)
                Text(store.isLive ? "BLE trực tiếp" : "Chế độ demo")
                    .font(.caption2)
                    .foregroundStyle(Color.bmsMuted)
            }
            Spacer()
            Button {
                store.toggleLiveConnection()
            } label: {
                Image(systemName: store.isLive
                        ? "xmark.circle.fill" : "dot.radiowaves.right")
                    .font(.title3)
            }
            .foregroundStyle(store.isLive ? Color.bmsRose : Color.bmsGreen)
        }
        .padding(12)
        .background(Color.bmsCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func infoStrip(live: BMSLiveTelemetry) -> some View {
        HStack {
            Text("Mạch: \(store.parser.bmsBrand) (\(live.protocolVersion))")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.bmsGreen)
            Spacer()
            Text("\(live.activeCellCount)S")
                .font(.footnote.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.bmsCardAlt)
                .clipShape(Capsule())
                .foregroundStyle(Color.bmsBlue)
        }
    }

    private func etaBanner(live: BMSLiveTelemetry, eta: BMSEtaResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("⏱ DỰ TÍNH SẠC ĐẦY / XẢ CẠN")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.bmsMuted)
            Text(etaTitle(eta: eta, live: live))
                .font(.headline)
                .foregroundStyle(Color.bmsGreen)
            Text(etaSubtitle(eta: eta, live: live))
                .font(.caption)
                .foregroundStyle(Color.bmsMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.bmsCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.bmsGreen.opacity(0.4), lineWidth: 1)
        )
    }

    private func socGaugeCard(live: BMSLiveTelemetry) -> some View {
        VStack(spacing: 6) {
            SOCIndicator(percent: live.socPercent,
                         subtitle: String(
                            format: "%.1f / %.1f Ah",
                            live.remainingCapacityAh,
                            live.nominalCapacityAh))
            Text(live.chargingMosOn ? "MOS SẠC: BẬT"
                    : (live.dischargingMosOn ? "MOS XẢ: BẬT" : "STANDBY"))
                .font(.caption2.weight(.bold))
                .foregroundStyle(live.chargingMosOn ? Color.bmsGreen
                                    : (live.dischargingMosOn ? Color.bmsGreen
                                        : Color.bmsMuted))
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color.bmsCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func metricsGrid(live: BMSLiveTelemetry) -> some View {
        let items: [(String, String, Color)] = [
            ("Tổng áp", String(format: "%.3f V", live.totalVoltageV), .bmsText),
            ("Dòng", String(format: "%+.2f A", live.currentA), .bmsAmber),
            ("Công suất", String(format: "%+.1f W", live.powerW), .bmsBlue),
            ("Lệch áp",
             String(format: "%.0f mV", live.deltaCellVoltageV * 1000), .bmsGreen),
            ("Cell MAX", String(format: "#%02d: %.3f V",
                                live.maxVoltageCellNum,
                                live.maxCellVoltageV), .bmsText),
            ("Cell MIN", String(format: "#%02d: %.3f V",
                                live.minVoltageCellNum,
                                live.minCellVoltageV), .bmsText),
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                         spacing: 8) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.0.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.bmsMuted)
                    Text(item.1)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(item.2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.bmsCard)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func cellsGrid(live: BMSLiveTelemetry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ĐIỆN ÁP TỪNG CELL")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.bmsMuted)
            LazyVGrid(columns: adaptiveColumns, spacing: 6) {
                ForEach(Array(live.cellVoltagesV.enumerated()), id: \.offset) { pair in
                    let index = pair.offset
                    let voltage = pair.element
                    let isMax = index + 1 == live.maxVoltageCellNum
                        && live.cellVoltagesV.count > 1
                    let isMin = index + 1 == live.minVoltageCellNum
                        && live.cellVoltagesV.count > 1
                    CellChip(number: index + 1,
                             voltage: voltage,
                             accent: isMax ? .bmsGreen : (isMin ? .bmsAmber : .bmsBorder),
                             boxBackground: isMax ? Color(hex: 0x0d1f1c)
                                : (isMin ? Color(hex: 0x24180d)
                                    : Color(hex: 0x131d2e)))
                }
            }
        }
        .padding(12)
        .background(Color.bmsCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var adaptiveColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 84), spacing: 6)]
    }

    private var deviceInfoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("THÔNG TIN THIẾT BỊ & MẬT KHẨU")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.bmsMuted)
            infoRow("Tên", store.deviceInfo.deviceName)
            infoRow("Model", store.deviceInfo.vendorId)
            infoRow("PIN BLE", store.deviceInfo.devicePasscode)
            infoRow("MK cài đặt", store.deviceInfo.setupPasscode)
            infoRow("Serial", store.deviceInfo.serialNumber)
            infoRow("Phiên bản",
                    "HW \(store.deviceInfo.hardwareVersion) · SW \(store.deviceInfo.softwareVersion)")
            Text("Chạy: "
                + BMSFormatting.formatDuration(seconds: store.deviceInfo.uptimeSeconds))
                .font(.footnote)
                .foregroundStyle(Color.bmsMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.bmsCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Color.bmsMuted)
            Spacer()
            Text(value.isEmpty ? "--" : value)
                .font(.footnote.monospaced())
                .foregroundStyle(Color.bmsText)
        }
    }

    // ------------------------------------------------------------ eta texts
    private func etaTitle(eta: BMSEtaResult, live: BMSLiveTelemetry) -> String {
        switch eta.state {
        case .charging:
            if eta.etaHours == nil { return "Pin đã sạc đầy (100%)" }
            return "Dự kiến sạc đầy sau: ~"
                + BMSFormatting.formatEtaHours(eta.etaHours ?? 0)
        case .discharging:
            return "Dự kiến xả cạn sau: ~"
                + BMSFormatting.formatEtaHours(eta.etaHours ?? 0)
        case .standby:
            return "Trạng thái Chờ (Không sạc / Không xả)"
        }
    }

    private func etaSubtitle(eta: BMSEtaResult, live: BMSLiveTelemetry) -> String {
        switch eta.state {
        case .charging:
            if eta.etaHours == nil {
                return String(format: "Đang duy trì dòng sạc: +%.2f A", live.currentA)
            }
            return String(format: "Đang nạp +%.2f A • cần %.1f/%.1f Ah",
                          live.currentA, live.remainingCapacityAh,
                          live.nominalCapacityAh)
        case .discharging:
            return String(format: "Đang xả %.2f A • còn %.1f Ah",
                          live.currentA, live.remainingCapacityAh)
        case .standby:
            let hours = eta.needAh > 0
                ? BMSFormatting.formatEtaHours((eta.needAh / 5.0) * 1.08)
                : "0 phút"
            return "Cần nạp " + String(format: "%.2f Ah (%.0f Wh)", eta.needAh, eta.needWh)
                + " · nếu sạc 5A ~" + hours
        }
    }
}

/// Vòng cung SOC đặt ở giữa.
struct SOCIndicator: View {
    let percent: Int
    let subtitle: String

    private var accent: Color {
        percent >= 50 ? .bmsGreen : (percent >= 20 ? .bmsAmber : .bmsRose)
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.0, to: 0.667)               // cung 240°
                .stroke(Color.bmsBorder, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(150))             // bắt đầu 150° = canvas "start=-30"
            Circle()
                .trim(from: 0.0, to: 0.667 * Double(max(0, min(100, percent))) / 100.0)
                .stroke(accent, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(150))
            VStack(spacing: 2) {
                Text("\(percent)%")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.bmsText)
                Text(subtitle)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.bmsBlue)
            }
        }
        .frame(width: 190, height: 190)
    }
}

struct CellChip: View {
    let number: Int
    let voltage: Double
    let accent: Color
    let boxBackground: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("#\(number)")
                    .font(.caption2)
                    .foregroundStyle(Color.bmsMuted)
                Spacer()
            }
            Text(String(format: "%.3f V", voltage))
                .font(.footnote.weight(.bold).monospaced())
                .foregroundStyle(Color.bmsText)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.bmsBorder.opacity(0.5))
                    Capsule()
                        .fill(accent)
                        .frame(width: max(4, geo.size.width * 0.55 * 0.9))
                }
            }
            .frame(height: 4)
        }
        .padding(6)
        .background(boxBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(accent.opacity(0.7), lineWidth: 0.5)
        )
    }
}

