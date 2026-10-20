// BMSMonitorApp.swift
// Điểm vào app. RootView quản lý Store (parser + phiên BLE).

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
            DashboardView(store: store)
                .navigationTitle("BMS Monitor")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            store.loadDemo(named: "ant_17s_demo")
                        } label: {
                            Label("Demo", systemImage: "waveform.path.ecg")
                        }
                        .foregroundStyle(Color.bmsBlue)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showScan = true
                        } label: {
                            Label("Kết nối", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .foregroundStyle(Color.bmsGreen)
                    }
                }
                .sheet(isPresented: $showScan) {
                    ScanSheet(store: store,
                              onConnected: { showScan = false })
                    .presentationDetents([.medium, .large])
                }
        }
    }
}
