// ScanSheet.swift
// Danh sách mạch BMS tìm thấy trong vòng quét 8 giây (đã lọc theo tên hãng
// và service UUID quảng cáo; có công tắc hiện tất cả thiết bị BLE).
// iOS không cho thấy MAC; UUID nội bộ của CBPeripheral là khóa kết nối.
// Màn hình này cũng là nơi xem chẩn đoán: đã chọn kênh nào, nhận bao nhiêu
// byte, bao nhiêu khung hợp lệ.

import SwiftUI

struct ScanSheet: View {
    @ObservedObject var store: BMSStore
    var onConnected: () -> Void

    var body: some View {
        let _ = store.revision
        List {
            Section {
                HStack {
                    Text(store.session.status)
                        .font(.footnote)
                    Spacer()
                    if store.session.isScanning {
                        ProgressView()
                    } else {
                        Button("Quét lại") {
                            store.session.toggleScanOrConnect()
                        }
                        .font(.footnote.weight(.semibold))
                    }
                }

                Toggle(isOn: Binding(
                    get: { store.session.showAllDevices },
                    set: { store.session.setShowAllDevices($0) }
                )) {
                    Label("Hiện tất cả thiết bị Bluetooth", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.footnote)
                }

                if !store.session.showAllDevices, store.session.hiddenDeviceCount > 0 {
                    HStack {
                        Text("Đã ẩn \(store.session.hiddenDeviceCount) thiết bị không phải mạch BMS")
                            .font(.caption2)
                            .foregroundStyle(Color.bmsMuted)
                        Spacer()
                        Button("Hiện") {
                            store.session.setShowAllDevices(true)
                        }
                        .font(.caption2.weight(.semibold))
                    }
                }
            }

            Section("Mạch BMS tìm thấy") {
                if store.session.devices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.session.isScanning
                             ? "Đang tìm mạch BMS…"
                             : "Chưa thấy mạch BMS nào")
                            .font(.footnote)
                            .foregroundStyle(Color.bmsMuted)
                        if !store.session.isScanning {
                            Text("Mạch có thể đã được đổi tên lạ — bật "
                                 + "“Hiện tất cả thiết bị Bluetooth” để xem toàn bộ.")
                                .font(.caption2)
                                .foregroundStyle(Color.bmsMuted)
                        }
                    }
                } else {
                    ForEach(store.session.devices) { device in
                        Button {
                            store.connect(deviceID: device.id)
                            onConnected()
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
                                if store.session.isConnected,
                                   store.session.connectedDeviceName == device.name {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.bmsGreen)
                                }
                            }
                        }
                    }
                }
            }

            if store.isLive || !store.session.diagnostics.isEmpty {
                Section("Chẩn đoán BLE — \(store.session.readMode.rawValue)") {
                    diagnosticSummary

                    if store.session.readMode == .polling {
                        Button {
                            store.session.pollNow()
                        } label: {
                            Label("Đọc ngay (1 lần)", systemImage: "arrow.clockwise")
                                .font(.footnote)
                        }
                    }

                    if store.isLive {
                        Button {
                            store.session.requestDeviceInfo()
                        } label: {
                            Label("Gửi lại lệnh đọc thông tin", systemImage: "paperplane")
                                .font(.footnote)
                        }
                    }

                    if store.session.diagnostics.isEmpty {
                        Text("Chưa kết nối thiết bị nào để xem service.")
                            .font(.caption2)
                            .foregroundStyle(Color.bmsMuted)
                    } else {
                        ForEach(Array(store.session.diagnostics.enumerated()), id: \.offset) {
                            _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .foregroundStyle(Color.bmsMuted)
                        }
                    }
                }
            }

            Section("Chế độ demo (không cần BLE)") {
                ForEach(demoNames, id: \.name) { demo in
                    Button {
                        store.loadDemo(named: demo.name)
                        onConnected()
                    } label: {
                        Label(demo.title, systemImage: "waveform.path")
                            .font(.footnote)
                            .foregroundStyle(Color.bmsBlue)
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
        .onAppear { store.session.beginScanIfNeeded() }
    }

    @ViewBuilder
    private var diagnosticSummary: some View {
        let session = store.session
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

    private var demoNames: [(name: String, title: String)] {
        [
            ("ant_17s_demo", "Mẫu ANT-BMS 17S 60V/30Ah"),
            ("jk_24s_demo", "Mẫu JK-BMS 24S 17 cell"),
            ("jk_32s_synthetic", "Mẫu JK-BMS 32S (tổng hợp)"),
            ("jbd_basic_and_cells", "Mẫu JBD 17S"),
            ("daly_0x90", "Mẫu Daly 0x90"),
        ]
    }
}
