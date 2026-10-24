// DeviceInfoView.swift
// Màn hình chính: chỉ tập trung vào DỮ LIỆU LẤY TỪ MẠCH — hãng/mạch BMS,
// thông tin thiết bị và mật khẩu. Không hiển thị dung lượng pin, điện áp,
// dòng điện hay % pin.
//
// Chuyển động: card hiện lần lượt khi mở app, quầng sáng nền trôi chậm,
// chấm trạng thái nhấp nháy, giá trị đổi mượt (contentTransition) và hiện/ẩn
// mật khẩu có animation. Tất cả tự tắt khi bật "Reduce Motion".

import BMSCore
import SwiftUI
import UIKit

struct DeviceInfoView: View {
    @ObservedObject var store: BMSStore
    var onConnect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        let _ = store.revision
        let live = store.live

        ScrollView {
            VStack(spacing: 18) {
                hero(live: live)
                    .reveal(appeared, delay: 0, reduceMotion: reduceMotion)

                section("Mạch BMS",
                        icon: "cpu",
                        showRefresh: store.isLive) {
                    group(boardRows(live: live))
                }
                .reveal(appeared, delay: 0.06, reduceMotion: reduceMotion)

                if store.isLive && !store.session.isStreaming {
                    waitingCard
                        .reveal(appeared, delay: 0.09, reduceMotion: reduceMotion)
                }

                section("Thông tin thiết bị", icon: "memorychip") {
                    group(deviceRows)
                }
                .reveal(appeared, delay: 0.12, reduceMotion: reduceMotion)

                section("Mật khẩu", icon: "key.fill") {
                    group(passwordRows)
                }
                .reveal(appeared, delay: 0.18, reduceMotion: reduceMotion)

                Text("Chạm biểu tượng để sao chép, nhấn 👁 để hiện mật khẩu.")
                    .font(.caption2)
                    .foregroundStyle(Color.bmsMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .reveal(appeared, delay: 0.22, reduceMotion: reduceMotion)

                if !live.errorMessages.isEmpty {
                    warnings(live.errorMessages)
                        .reveal(appeared, delay: 0.24, reduceMotion: reduceMotion)
                }

                if let error = store.session.lastError {
                    errorCard(error)
                        .reveal(appeared, delay: 0.26, reduceMotion: reduceMotion)
                }

                footer
                    .reveal(appeared, delay: 0.28, reduceMotion: reduceMotion)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(backdrop)
        .preferredColorScheme(.dark)
        .tint(Color.bmsGreen)
        .animation(.snappy(duration: 0.3), value: store.session.lastError)
        .animation(.snappy(duration: 0.3), value: live.errorMessages)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.snappy(duration: 0.5)) { appeared = true }
            }
        }
    }

    // --------------------------------------------------------------- hero
    private func hero(live: BMSLiveTelemetry) -> some View {
        let session = store.session
        let statusColor: Color
        let statusLabel: String

        if session.isStreaming {
            statusColor = .bmsGreen
            statusLabel = "BLE TRỰC TIẾP"
        } else if session.isConnected {
            statusColor = .bmsAmber
            statusLabel = "ĐÃ KẾT NỐI · CHỜ DỮ LIỆU"
        } else if store.isDemo {
            statusColor = .bmsAmber
            statusLabel = "CHẾ ĐỘ DEMO"
        } else {
            statusColor = .bmsRose
            statusLabel = "CHƯA CÓ KẾT NỐI"
        }

        let statusText = store.isDemo
            ? "Dữ liệu mẫu — chưa kết nối mạch"
            : session.status

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                PulsingDot(color: statusColor,
                           animated: !reduceMotion && (session.isStreaming || session.isScanning))
                Text(statusLabel)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(statusColor)
                Spacer()
                connectButton(statusColor: statusColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(store.parser.bmsBrand)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.bmsText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.opacity)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(Color.bmsMuted)
                    .lineLimit(2)
                    .contentTransition(.opacity)
            }
            .animation(.snappy(duration: 0.3), value: store.parser.bmsBrand)
            .animation(.snappy(duration: 0.3), value: session.status)

            HStack(spacing: 8) {
                HeroChip(icon: "point.3.connected.trianglepath.dotted",
                         text: live.protocolVersion,
                         tint: .bmsBlue)
                if live.activeCellCount > 0 {
                    HeroChip(icon: "square.stack.3d.up",
                             text: "\(live.activeCellCount)S",
                             tint: .bmsGreen)
                }
                if store.isLive {
                    HeroChip(icon: "waveform.path.ecg",
                             text: session.readMode.rawValue,
                             tint: .bmsMuted)
                }
                if let age = session.secondsSinceData, session.isStreaming {
                    HeroChip(icon: "clock",
                             text: age == 0 ? "vừa nhận" : "\(age)s trước",
                             tint: age <= 3 ? .bmsGreen : .bmsAmber)
                }
            }
        }
        .padding(18)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.bmsCard)
                AmbientGlow(leading: statusColor,
                            trailing: .bmsBlue,
                            reduceMotion: reduceMotion)
                LinearGradient(
                    colors: [statusColor.opacity(0.16), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), Color.white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: statusColor.opacity(0.18), radius: 22, y: 10)
        .animation(.snappy(duration: 0.35), value: store.isLive)
        .animation(.snappy(duration: 0.35), value: session.isStreaming)
    }

    private func connectButton(statusColor: Color) -> some View {
        let connected = store.session.isConnected
        let label = connected ? "Ngắt" : (store.isDemo ? "Kết nối" : "Kết nối lại")
        return Button {
            if connected {
                store.toggleLiveConnection()
            } else {
                onConnect()
            }
        } label: {
            Label(label,
                  systemImage: connected ? "xmark" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(statusColor)
                .background(Capsule().fill(statusColor.opacity(0.14)))
                .overlay(Capsule().strokeBorder(statusColor.opacity(0.35), lineWidth: 1))
                .contentTransition(.opacity)
        }
        .buttonStyle(.plain)
    }

    // ---------------------------------------------------------- waiting card
    private var waitingCard: some View {
        let session = store.session
        let color: Color = session.phase == .failed ? .bmsRose : .bmsAmber
        let message: String

        if !session.isConnected {
            message = "Chưa kết nối mạch. Mở Quét & kết nối để chọn thiết bị BLE."
        } else if session.rawPacketCount == 0 {
            message = "Đã kết nối nhưng chưa nhận được byte nào trên "
                + "\(session.selectedDataUUID.isEmpty ? "kênh dữ liệu" : session.selectedDataUUID)"
                + ". App đang chờ notify từ mạch."
        } else {
            message = "Đã nhận \(session.rawByteCount) byte nhưng chưa có khung BMS hợp lệ. "
                + "Có thể chọn sai characteristic hoặc mạch dùng giao thức khác."
        }

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: session.phase == .failed
                      ? "exclamationmark.triangle.fill" : "hourglass")
                Text(session.phase.rawValue.uppercased())
                    .tracking(1.2)
                Spacer()
                if session.isConnected {
                    Button("Gửi lại lệnh") { session.requestDeviceInfo() }
                        .font(.caption2.weight(.semibold))
                }
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)

            Text(message)
                .font(.footnote)
                .foregroundStyle(Color.bmsText)
                .fixedSize(horizontal: false, vertical: true)

            Text("Kênh: \(session.selectedDataUUID.isEmpty ? "—" : session.selectedDataUUID)"
                 + " · ghi: \(session.selectedWriteUUID.isEmpty ? "—" : session.selectedWriteUUID)"
                 + " · nhận \(session.rawPacketCount) gói / \(session.rawByteCount) B"
                 + " · hợp lệ \(session.validFrameCount)")
                .font(.caption2.monospaced())
                .foregroundStyle(Color.bmsMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(color.opacity(0.25), lineWidth: 1)
        )
    }

    // ------------------------------------------------------------- cards
    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        icon: String,
        showRefresh: Bool = false,
        @ViewBuilder rows: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.bmsBlue.opacity(0.85))
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Color.bmsMuted)
                Spacer()
                if showRefresh {
                    Button { store.session.pollNow() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.bmsBlue)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 4)
            .animation(.snappy(duration: 0.25), value: showRefresh)

            VStack(spacing: 0) { rows() }
                .padding(.horizontal, 14)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.bmsCard.opacity(0.92))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
        }
    }

    private func group(_ specs: [RowSpec]) -> some View {
        ForEach(specs.indices, id: \.self) { index in
            if index > 0 {
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 1)
                    .padding(.leading, 26)
            }
            let spec = specs[index]
            DataRow(icon: spec.icon,
                    label: spec.label,
                    value: spec.value,
                    secret: spec.secret,
                    tint: spec.tint)
        }
    }

    // -------------------------------------------------------------- rows
    private func boardRows(live: BMSLiveTelemetry) -> [RowSpec] {
        let configured = store.settingsInfo.cellCountConfigured
        return [
            RowSpec(icon: "cpu", label: "Hãng", value: store.parser.bmsBrand),
            RowSpec(icon: "antenna.radiowaves.left.and.right",
                    label: "Giao thức", value: live.protocolVersion),
            RowSpec(icon: "square.stack.3d.up",
                    label: "Cell cấu hình",
                    value: configured > 0 ? "\(configured)S" : ""),
            RowSpec(icon: "square.stack.3d.up.fill",
                    label: "Cell đọc được",
                    value: live.activeCellCount > 0 ? "\(live.activeCellCount)S" : ""),
            RowSpec(icon: "arrow.left.arrow.right",
                    label: "Cách đọc",
                    value: store.isLive ? store.session.readMode.rawValue : "Dữ liệu mẫu"),
        ]
    }

    private var deviceRows: [RowSpec] {
        let info = store.deviceInfo
        return [
            RowSpec(icon: "tag", label: "Tên",
                    value: value(info.deviceName, .deviceName)),
            RowSpec(icon: "shippingbox", label: "Model",
                    value: value(info.vendorId, .vendorId)),
            RowSpec(icon: "barcode", label: "Serial",
                    value: value(info.serialNumber, .serialNumber)),
            RowSpec(icon: "calendar", label: "Ngày SX",
                    value: value(info.manufacturingDate, .manufacturingDate)),
            RowSpec(icon: "numbers", label: "Phiên bản", value: versionText(info)),
            RowSpec(icon: "person.text.rectangle", label: "Dữ liệu",
                    value: value(info.userData, .userData)),
            RowSpec(icon: "clock", label: "Hoạt động", value: activityText(info)),
        ]
    }

    private var passwordRows: [RowSpec] {
        let info = store.deviceInfo
        return [
            RowSpec(icon: "key.fill", label: "PIN BLE",
                    value: value(info.devicePasscode, .devicePasscode),
                    secret: true),
            RowSpec(icon: "lock.rotation", label: "MK cài đặt",
                    value: value(info.setupPasscode, .setupPasscode),
                    secret: true),
            RowSpec(icon: "lock.fill", label: "MK kết nối",
                    value: value(info.passcode, .passcode),
                    secret: true),
        ]
    }

    /// Dữ liệu demo hiển thị đầy đủ (có nhãn DEMO). Với mạch thật, chỉ hiển
    /// thị trường thực sự có trong khung — không biến giá trị mặc định của
    /// decoder thành "đọc được từ mạch".
    private func value(_ raw: String, _ field: BMSDeviceInfoProvenance.Field) -> String {
        if store.isDemo { return raw }
        return store.provenance.has(field) ? raw : ""
    }

    private func versionText(_ info: BMSDeviceInfo) -> String {
        var parts: [String] = []
        if !info.hardwareVersion.isEmpty,
           store.isDemo || store.provenance.has(.hardwareVersion) {
            parts.append("HW \(info.hardwareVersion)")
        }
        if !info.softwareVersion.isEmpty,
           store.isDemo || store.provenance.has(.softwareVersion) {
            parts.append("SW \(info.softwareVersion)")
        }
        return parts.joined(separator: " · ")
    }

    private func activityText(_ info: BMSDeviceInfo) -> String {
        var parts: [String] = []
        let showUptime = store.isDemo || store.provenance.has(.uptimeSeconds)
        let showPowerOn = store.isDemo || store.provenance.has(.powerOnCount)
        if showUptime, info.uptimeSeconds > 0 {
            parts.append(BMSFormatting.formatDuration(seconds: info.uptimeSeconds))
        }
        if showPowerOn, info.powerOnCount > 0 {
            parts.append("bật \(info.powerOnCount) lần")
        }
        return parts.joined(separator: " · ")
    }

    // ---------------------------------------------------------- banners
    private func warnings(_ messages: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("CẢNH BÁO TỪ MẠCH")
                    .tracking(1.2)
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.bmsRose)
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(messages, id: \.self) { message in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Color.bmsRose)
                            .frame(width: 5, height: 5)
                            .padding(.top, 5)
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(Color.bmsText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.bmsRose.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.bmsRose.opacity(0.25), lineWidth: 1)
            )
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func errorCard(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.footnote)
                .foregroundStyle(Color.bmsRose)
            Text(error)
                .font(.footnote)
                .foregroundStyle(Color.bmsText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.bmsCard.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.bmsRose.opacity(0.25), lineWidth: 1)
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var footer: some View {
        Text(footerText)
            .font(.caption2)
            .foregroundStyle(Color.bmsMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
    }

    private var footerText: String {
        let session = store.session
        if store.isDemo {
            return "Đang xem dữ liệu mẫu — kết nối BLE để đọc mạch thật."
        }
        if !session.isConnected {
            return "Chưa kết nối mạch. Dữ liệu bên trên (nếu có) là lần đọc cuối."
        }
        if !session.isStreaming {
            return "Đã kết nối nhưng chưa có khung hợp lệ — mở Quét & kết nối để xem chẩn đoán."
        }
        return "Dữ liệu đọc trực tiếp từ mạch qua BLE · kênh \(session.selectedDataUUID)."
    }

    private var backdrop: some View {
        ZStack {
            Color.bmsBg
            RadialGradient(colors: [Color.bmsGreen.opacity(0.10), .clear],
                           center: .topTrailing,
                           startRadius: 0,
                           endRadius: 460)
            RadialGradient(colors: [Color.bmsBlue.opacity(0.08), .clear],
                           center: .bottomLeading,
                           startRadius: 0,
                           endRadius: 460)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Row model

struct RowSpec {
    let icon: String
    let label: String
    let value: String
    var secret = false
    var tint: Color? = nil
}

// MARK: - Row

struct DataRow: View {
    let icon: String
    let label: String
    let value: String
    var secret = false
    var tint: Color? = nil

    @State private var revealed = false
    @State private var copied = false

    private var isEmpty: Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shown: String {
        if isEmpty { return "--" }
        if secret && !revealed {
            return String(repeating: "•", count: max(6, min(value.count, 10)))
        }
        return value
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.bmsBlue.opacity(0.8))
                .frame(width: 16)

            Text(label)
                .font(.footnote)
                .foregroundStyle(Color.bmsMuted)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(shown)
                .font(.footnote.weight(.semibold).monospaced())
                .foregroundStyle(isEmpty ? Color.bmsMuted.opacity(0.5) : (tint ?? Color.bmsText))
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.interpolate)
                .animation(.snappy(duration: 0.25), value: shown)

            if !isEmpty {
                if secret {
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { revealed.toggle() }
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.bmsMuted)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealed ? "Ẩn mật khẩu" : "Hiện mật khẩu")
                }

                Button(action: copyValue) {
                    Image(systemName: copied ? "checkmark" : "square.on.square")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(copied ? Color.bmsGreen : Color.bmsMuted.opacity(0.70))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sao chép \(label)")
            }
        }
        .padding(.vertical, 10)
        .sensoryFeedback(.success, trigger: copied) { _, newValue in newValue }
    }

    private func copyValue() {
        UIPasteboard.general.string = value
        withAnimation(.snappy(duration: 0.2)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.snappy(duration: 0.2)) { copied = false }
        }
    }
}

// MARK: - Small pieces

struct PulsingDot: View {
    let color: Color
    var animated = true

    @State private var pulse = false

    var body: some View {
        ZStack {
            if animated {
                Circle()
                    .stroke(color.opacity(0.55), lineWidth: 1)
                    .scaleEffect(pulse ? 2.4 : 1)
                    .opacity(pulse ? 0 : 1)
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .frame(width: 8, height: 8)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
        .accessibilityHidden(true)
    }
}

struct HeroChip: View {
    let icon: String
    let text: String
    var tint: Color = .bmsMuted

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }
}

/// Hai quầng sáng trôi chậm phía sau card hero.
struct AmbientGlow: View {
    var leading: Color = .bmsGreen
    var trailing: Color = .bmsBlue
    var reduceMotion: Bool = false

    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(leading.opacity(0.42))
                    .frame(width: geo.size.width * 0.70)
                    .blur(radius: 70)
                    .offset(x: drift ? geo.size.width * 0.22 : -geo.size.width * 0.18,
                            y: -geo.size.height * 0.20)
                Circle()
                    .fill(trailing.opacity(0.34))
                    .frame(width: geo.size.width * 0.55)
                    .blur(radius: 80)
                    .offset(x: drift ? -geo.size.width * 0.20 : geo.size.width * 0.24,
                            y: geo.size.height * 0.30)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 9).repeatForever(autoreverses: true),
                       value: drift)
            .onAppear { drift = !reduceMotion }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Entrance helper

extension View {
    /// Fade + trượt nhẹ lên khi card xuất hiện, lệch nhịp theo `delay`.
    func reveal(_ visible: Bool, delay: Double, reduceMotion: Bool) -> some View {
        self
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 16)
            .animation(reduceMotion
                       ? nil
                       : .snappy(duration: 0.55, extraBounce: 0.06).delay(delay),
                       value: visible)
    }
}
