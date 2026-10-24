// ScanSheet.swift
// Danh sách mạch BMS tìm thấy trong vòng quét 8 giây (đã lọc theo tên hãng
// và service UUID quảng cáo; có công tắc hiện tất cả thiết bị BLE).
// iOS không cho thấy MAC; UUID nội bộ của CBPeripheral là khóa kết nối.
//
// Sheet giữ nguyên khi đang kết nối: chọn mạch → hiện "Đang kết nối…" và
// tự đóng khi didConnect thành công. Nếu lỗi, sheet ở lại để chọn lại.
// Màn hình này cũng là nơi xem chẩn đoán: đã chọn kênh nào, nhận bao nhiêu
// byte, bao nhiêu khung hợp lệ.

import SwiftUI

struct ScanSheet: View {
    @ObservedObject var store: BMSStore

    @Environment(\.dismiss) private var dismiss
    @State private var connectingID: UUID?

    private var session: BLESession { store.session }

    var body: some View {
        List {
            Section {
                HStack {
                    Text(session.status)
                        .font(.footnote)
                        .lineLimit(2)
                    Spacer()
                    if session.isScanning || connectingID != nil {
                        ProgressView()
                    } else {
                        Button("Quét lại") {
                            session.toggleScanOrConnect()
                        }
                        .font(.footnote.weight(.semibold))
                    }
                }

                if let error = session.lastError, connectingID == nil {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(Color.bmsRose)
                }

                Toggle(isOn: Binding(
                    get: { session.showAllDevices },
                    set: { session.setShowAllDevices($0) }
                )) {
                    Label("Hiện tất cả thiết bị Bluetooth",
                          systemImage: "antenna.radiowaves.left.and.right")
                        .font(.footnote)
                }
                .disabled(connectingID != nil)

                if !session.showAllDevices, session.hiddenDeviceCount > 0 {
                    HStack {
                        Text("Đã ẩn \(session.hiddenDeviceCount) thiết bị không phải mạch BMS")
                            .font(.caption2)
                            .foregroundStyle(Color.bmsMuted)
                        Spacer()
                        Button("Hiện") {
                            session.setShowAllDevices(true)
                        }
                        .font(.caption2.weight(.semibold))
                    }
                }
            }

            Section("Mạch BMS tìm thấy") {
                if session.devices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.isScanning
                             ? "Đang tìm mạch BMS…"
                             : "Chưa thấy mạch BMS nào")
                            .font(.footnote)
                            .foregroundStyle(Color.bmsMuted)
                        if !session.isScanning {
                            Text("Mạch có thể đã được đổi tên lạ — bật "
                                 + "“Hiện tất cả thiết bị Bluetooth” để xem toàn bộ.")
                                .font(.caption2)
                                .foregroundStyle(Color.bmsMuted)
                        }
                    }
                } else {
                    ForEach(session.devices) { device in
                        deviceRow(device)
                    }
                }
            }

            if store.isConnected || !session.diagnostics.isEmpty {
                Section("Chẩn đoán BLE — \(session.readMode.rawValue)") {
                    diagnosticSummary

                    if session.readMode == .polling {
                        Button {
                            session.pollNow()
                        } label: {
                            Label("Đọc ngay (1 lần)", systemImage: "arrow.clockwise")
                                .font(.footnote)
                        }
                    }

                    if session.isConnected {
                        Button {
                            session.requestDeviceInfo()
                        } label: {
                            Label("Gửi lại lệnh đọc thông tin", systemImage: "paperplane")
                                .font(.footnote)
                        }
                    }

                    if session.diagnostics.isEmpty {
                        Text("Chưa kết nối thiết bị nào để xem service.")
                            .font(.caption2)
                            .foregroundStyle(Color.bmsMuted)
                    } else {
                        ForEach(Array(session.diagnostics.enumerated()), id: \.offset) {
                            _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .foregroundStyle(Color.bmsMuted)
                        }
                    }
                }
            }
        }
        .navigationTitle("Quét & kết nối")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Color.bmsBg.ignoresSafeArea())
        .tint(Color.bmsGreen)
        .preferredColorScheme(.dark)
        .toolbarBackground(Color.bmsHeader, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Đóng") { dismiss() }
                    .font(.footnote.weight(.semibold))
            }
        }
        .onAppear { session.beginScanIfNeeded() }
        .onChange(of: store.isConnected) { _, connected in
            if connected { dismiss() }
        }
        .onChange(of: session.phase) { _, phase in
            guard connectingID != nil else { return }
            switch phase {
            case .failed, .idle, .bluetoothOff:
                connectingID = nil
            default:
                break
            }
        }
    }

    // --------------------------------------------------------------- row
    private func deviceRow(_ device: ScannedDevice) -> some View {
        Button {
            connect(device)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "circuitboard")
                    .foregroundStyle(Color.bmsGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    Text(device.subtitle)
                        .font(.caption2)
                        .foregroundStyle(Color.bmsMuted)
                        .lineLimit(2)
                }
                Spacer()
                if connectingID == device.id {
                    ProgressView()
                } else if session.isConnected,
                          session.connectedDeviceName == device.name {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.bmsGreen)
                }
            }
        }
        .disabled(connectingID != nil && connectingID != device.id)
    }

    private func connect(_ device: ScannedDevice) {
        guard connectingID == nil else { return }
        connectingID = device.id
        store.connect(deviceID: device.id)
        // Kết nối có thể bị từ chối ngay (thiết bị không còn trong danh sách).
        if session.phase != .connecting {
            connectingID = nil
        }
    }

    @ViewBuilder
    private var diagnosticSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pha: \(session.phase.rawValue) · \(session.readMode.rawValue)")
            Text("Kênh dữ liệu: \(session.selectedDataUUID.isEmpty ? "—" : session.selectedDataUUID)"
                 + " · ghi: \(session.selectedWriteUUID.isEmpty ? "—" : session.selectedWriteUUID)")
            Text("Nhận \(session.rawPacketCount) gói / \(session.rawByteCount) B"
                 + " · khung hợp lệ \(session.validFrameCount)")
            if let age = session.secondsSinceData {
                Text("Khung cuối: \(age) giây trước")
            }
            if let error = session.lastError {
                Text("Lỗi: \(error)")
                    .foregroundStyle(Color.bmsRose)
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(Color.bmsMuted)
    }
}
