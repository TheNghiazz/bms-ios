// BMSMonitorApp.swift
// Điểm vào app. RootView chỉ giữ Store (parser + phiên BLE) và màn hình
// dữ liệu thiết bị; mở ScanSheet để quét/kết nối hoặc chọn dữ liệu mẫu.

import SwiftUI

@main
struct BMSMonitorApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @StateObject private var store = BMSStore()
    @State private var showScan = false

    var body: some View {
        NavigationStack {
            DeviceInfoView(store: store, onConnect: { showScan = true })
                .navigationTitle("Dữ liệu BMS")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showScan = true
                        } label: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                        .accessibilityLabel("Quét & kết nối")
                        .foregroundStyle(Color.bmsGreen)
                    }
                }
                .sheet(isPresented: $showScan) {
                    ScanSheet(store: store,
                              onConnected: { showScan = false })
                    .presentationDetents([.medium, .large])
                }
        }
        .tint(Color.bmsGreen)
        .preferredColorScheme(.dark)
    }
}
