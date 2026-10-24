// DeviceInfoView.swift
// Trạng thái "đã kết nối": header gọn của thiết bị + nút Ngắt, sau đó là
// danh sách thông tin đọc trực tiếp từ mạch. Không còn dữ liệu mẫu.
//
// Chuyển động: khi vừa kết nối, header và từng card lần lượt "bung" ra từ
// phía nút kết nối (burstOut, so le theo index), quầng sáng nền trôi chậm,
// chấm trạng thái nhấp nháy, giá trị đổi mượt và hiện/ẩn mật khẩu có animation.
// Tất cả tự tắt khi bật "Giảm chuyển động".

import BMSCore
import SwiftUI
import UIKit

struct DeviceInfoView: View {
    @ObservedObject var store: BMSStore
    var onDisconnect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        let _ = store.revision
        let live = store.live

        ScrollView {
            VStack(spacing: 18) {
                header(live: live)
                    .burstOut(appeared, index: 0, reduceMotion: reduceMotion)

                if !store.session.isStreaming {
                    waitingCard
                        .burstOut(appeared, index: 1, reduceMotion: reduceMotion)
                }

                section("Mạch BMS",
                        icon: "cpu",
                        showRefresh: store.session.readMode == .polling) {
                    group(boardRows(live: live))
                }
                .burstOut(appeared, index: 2, reduceMotion: reduceMotion)

                section("Thông tin thiết bị", icon: "memorychip") {
                    group(deviceRows)
                }
                .burstOut(appeared, index: 3, reduceMotion: reduceMotion)

                section("Mật khẩu", icon: "key.fill") {
                    group(passwordRows)
                }
                .burstOut(appeared, index: 4, reduceMotion: reduceMotion)

                Text("Chạm biểu tượng để sao chép, nhấn 👁 để hiện mật khẩu.")
                    .font(.caption2)
                    .foregroundStyle(Color.bmsMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .burstOut(appeared, index: 5, reduceMotion: reduceMotion)

                if !live.errorMessages.isEmpty {
                    warnings(live.errorMessages)
                        .burstOut(appeared, index: 6, reduceMotion: reduceMotion)
                }

                if let error = store.session.lastError {
                    errorCard(error)
                        .burstOut(appeared, index: 7, reduceMotion: reduceMotion)
                }

                footer
                    .burstOut(appeared, index: 8, reduceMotion: reduceMotion)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(BMSBackdrop())
        .preferredColorScheme(.dark)
        .tint(Color.bmsGreen)
        .animation(.snappy(duration: 0.3), value: store.session.lastError)
        .animation(.snappy(duration: 0.3), value: live.errorMessages)
        .onAppear {
            guard !appeared else { return }
            appeared = true
        }
    }

    // -------------------------------------------------------------- header
    private func header(live: BMSLiveTelemetry) -> some View {
        let session = store.session
        let statusColor: Color = session.isStreaming ? .bmsGreen : .bmsAmber
        let statusLabel = session.isStreaming
            ? "BLE TRỰC TIẾP"
            : session.phase.rawValue.uppercased()
        let name = session.connectedDeviceName.isEmpty
            ? store.parser.bmsBrand
            : session.connectedDeviceName

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                PulsingDot(color: statusColor,
                           animated: !reduceMotion && (session.isStreaming || session.isScanning))
                Text(statusLabel)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(statusColor)
                Spacer()
                Button(action: onDisconnect) {
                    Label("Ngắt", systemImage: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundStyle(Color.bmsRose)
                        .background(Capsule().fill(Color.bmsRose.opacity(0.14)))
                        .overlay(Capsule().strokeBorder(Color.bmsRose.opacity(0.35),
                                                        lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ngắt kết nối BLE")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.bmsText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.opacity)
                Text(session.status)
                    .font(.footnote)
                    .foregroundStyle(Color.bmsMuted)
                    .lineLimit(2)
                    .contentTransition(.opacity)
            }
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
                if session.readMode != .none {
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
        .animation(.snappy(duration: 0.35), value: session.isStreaming)
    }

    // ---------------------------------------------------------- waiting card
    private var waitingCard: some View {
        let session = store.session
        let color: Color = session.phase == .failed ? .bmsRose : .bmsAmber
        let message: String

        if session.rawPacketCount == 0 {
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
                Button("Gửi lại lệnh") { session.requestDeviceInfo() }
                    .font(.caption2.weight(.semibold))
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
                    value: store.session.readMode == .none ? "" : store.session.readMode.rawValue),
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

    /// Chỉ hiển thị trường thực sự có trong khung nhận được — không biến giá
    /// trị mặc định của decoder thành "đọc được từ mạch".
    private func value(_ raw: String, _ field: BMSDeviceInfoProvenance.Field) -> String {
        store.provenance.has(field) ? raw : ""
    }

    private func versionText(_ info: BMSDeviceInfo) -> String {
        var parts: [String] = []
        if !info.hardwareVersion.isEmpty, store.provenance.has(.hardwareVersion) {
            parts.append("HW \(info.hardwareVersion)")
        }
        if !info.softwareVersion.isEmpty, store.provenance.has(.softwareVersion) {
            parts.append("SW \(info.softwareVersion)")
        }
        return parts.joined(separator: " · ")
    }

    private func activityText(_ info: BMSDeviceInfo) -> String {
        var parts: [String] = []
        if store.provenance.has(.uptimeSeconds), info.uptimeSeconds > 0 {
            parts.append(BMSFormatting.formatDuration(seconds: info.uptimeSeconds))
        }
        if store.provenance.has(.powerOnCount), info.powerOnCount > 0 {
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
        if !session.isStreaming {
            return "Đã kết nối nhưng chưa có khung hợp lệ — mạch có thể đang "
                + "khởi động hoặc sai kênh dữ liệu."
        }
        return "Dữ liệu đọc trực tiếp từ mạch qua BLE · kênh \(session.selectedDataUUID)."
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

// MARK: - Chip nhỏ trong header

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
