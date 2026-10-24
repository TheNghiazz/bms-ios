// ConnectLandingView.swift
// Trạng thái "chưa kết nối": không hiển thị dữ liệu mẫu hay card rỗng.
// Chỉ có nút kết nối BLE ở trung tâm, vòng radar lan toả và trạng thái BLE.
// Bấm nút sẽ mở ScanSheet (quét & chọn mạch).

import SwiftUI

struct ConnectLandingView: View {
    @ObservedObject var store: BMSStore
    var onConnect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var session: BLESession { store.session }

    private var isConnecting: Bool { session.phase == .connecting }
    private var isBusy: Bool {
        switch session.phase {
        case .scanning, .connecting, .discovering, .subscribing, .probing:
            return true
        default:
            return false
        }
    }

    private var statusTint: Color {
        switch session.phase {
        case .bluetoothOff, .failed:
            return .bmsRose
        case .scanning, .connecting, .discovering, .subscribing, .probing:
            return .bmsAmber
        default:
            return .bmsMuted
        }
    }

    private var statusLabel: String {
        switch session.phase {
        case .bluetoothOff:
            return "BLUETOOTH ĐANG TẮT"
        case .failed:
            return "LỖI KẾT NỐI"
        case .scanning:
            return "ĐANG QUÉT MẠCH"
        case .connecting, .discovering, .subscribing, .probing:
            return "ĐANG KẾT NỐI…"
        default:
            return "CHƯA KẾT NỐI"
        }
    }

    var body: some View {
        ZStack {
            BMSBackdrop()

            VStack(spacing: 0) {
                Spacer(minLength: 8)

                Text("BMS MONITOR")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(3.2)
                    .foregroundStyle(Color.bmsMuted)
                    .reveal(appeared, delay: 0, reduceMotion: reduceMotion)

                radarButton
                    .padding(.top, 6)
                    .reveal(appeared, delay: 0.04, reduceMotion: reduceMotion)

                Text("KẾT NỐI BLE")
                    .font(.system(size: 15, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Color.bmsGreen)
                    .padding(.top, 10)
                    .reveal(appeared, delay: 0.10, reduceMotion: reduceMotion)

                Text("Đọc thông tin mạch BMS qua Bluetooth.\nKhông có dữ liệu nào rời khỏi máy.")
                    .font(.footnote)
                    .foregroundStyle(Color.bmsMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 8)
                    .reveal(appeared, delay: 0.14, reduceMotion: reduceMotion)

                statusPill
                    .padding(.top, 24)
                    .reveal(appeared, delay: 0.18, reduceMotion: reduceMotion)

                if let error = session.lastError {
                    errorNote(error)
                        .padding(.top, 12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Spacer(minLength: 12)

                Text("Bật Bluetooth và đưa điện thoại lại gần mạch.")
                    .font(.caption2)
                    .foregroundStyle(Color.bmsMuted.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .reveal(appeared, delay: 0.24, reduceMotion: reduceMotion)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .tint(Color.bmsGreen)
        .animation(.snappy(duration: 0.3), value: session.phase)
        .animation(.snappy(duration: 0.3), value: session.lastError)
        .onAppear {
            guard !appeared else { return }
            appeared = true
        }
    }

    // ------------------------------------------------------------- nút giữa
    private var radarButton: some View {
        ZStack {
            if !reduceMotion {
                RadarRings(tint: isBusy ? .bmsAmber : .bmsGreen)
                    .frame(width: 250, height: 250)
            }

            Button(action: onConnect) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(colors: [Color.bmsGreen, Color.bmsBlue],
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing)
                        )
                        .frame(width: 96, height: 96)
                        .shadow(color: Color.bmsGreen.opacity(0.45), radius: 24, y: 8)

                    if isConnecting {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.bmsBg)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Color.bmsBg)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isConnecting)
            .accessibilityLabel("Kết nối BLE")
            .accessibilityHint("Mở danh sách mạch BMS để chọn thiết bị")
            .sensoryFeedback(.impact(weight: .medium), trigger: session.phase == .connecting)
        }
        .frame(height: 236)
    }

    // --------------------------------------------------------------- trạng thái
    private var statusPill: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                PulsingDot(color: statusTint,
                           animated: !reduceMotion && isBusy)
                Text(statusLabel)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(statusTint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(statusTint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(statusTint.opacity(0.30), lineWidth: 1))

            Text(session.status)
                .font(.caption2)
                .foregroundStyle(Color.bmsMuted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 280, minHeight: 14)
                .contentTransition(.opacity)
        }
    }

    private func errorNote(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color.bmsRose)
            Text(error)
                .font(.caption)
                .foregroundStyle(Color.bmsText)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.bmsRose.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.bmsRose.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Vòng radar

/// Ba vòng sóng lan ra từ nút kết nối, lặp vô hạn và lệch pha nhau.
struct RadarRings: View {
    var tint: Color = .bmsGreen

    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(tint.opacity(0.30), lineWidth: 1.4)
                    .scaleEffect(animate ? 1 : 0.42)
                    .opacity(animate ? 0 : 0.9)
                    .animation(
                        .easeOut(duration: 2.6)
                            .repeatForever(autoreverses: false)
                            .delay(Double(index) * 0.85),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
