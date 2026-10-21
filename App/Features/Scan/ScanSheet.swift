// ScanSheet.swift
// Danh sách thiết bị BLE tìm thấy trong vòng quét 6 giây.
// iOS không cho thấy MAC; tên + RSSI là định danh hiển thị, UUID nội bộ
// của CBPeripheral mới là khóa kết nối lại (lưu trong Phase 6).

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
                    }
                }
            }
            Section("Thiết bị tìm thấy") {
                if store.session.devices.isEmpty {
                    Text("Chưa có thiết bị nào")
                        .font(.footnote)
                        .foregroundStyle(Color.bmsMuted)
                } else {
                    ForEach(store.session.devices, id: \.self) { name in
                        Button {
                            store.session.connect(deviceName: name)
                            onConnected()
                        } label: {
                            Label(name, systemImage: "circuitboard")
                                .font(.footnote)
                        }
                    }
                }
            }
            if store.isLive || !store.session.diagnostics.isEmpty {
                Section("Chẩn đoán BLE — \(store.session.readMode.rawValue)") {
                    if store.session.readMode == .polling {
                        Button {
                            store.session.pollNow()
                        } label: {
                            Label("Đọc ngay (1 lần)", systemImage: "arrow.clockwise")
                                .font(.footnote)
                        }
                    }
                    if store.session.diagnostics.isEmpty {
                        Text("Chưa kết nối thiết bị nào để xem dịch vụ.")
                            .font(.caption2)
                            .foregroundStyle(Color.bmsMuted)
                    } else {
                        ForEach(store.session.diagnostics, id: \.self) { line in
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
        .onAppear { if !store.isLive { store.session.toggleScanOrConnect() } }
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
