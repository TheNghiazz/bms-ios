// BMSMonitorApp.swift
// Điểm vào app. RootView quản lý Store (parser + phiên BLE) và khoá mật khẩu.

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
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showScan = false
    @State private var showPasswordSettings = false

    var body: some View {
        Group {
            if lock.isLocked {
                LockScreen(lock: lock)
            } else {
                dashboard
            }
        }
        // Tự khoá khi app xuống background (app switcher / thoát ra).
        // Chỉ dùng .background, không dùng .inactive, để hộp thoại hệ thống
        // (xin quyền Bluetooth, Control Center…) không khoá app giữa chừng.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                showScan = false
                showPasswordSettings = false
                lock.lock()
            }
        }
    }

    private var dashboard: some View {
        NavigationStack {
            DashboardView(store: store)
                .navigationTitle("BMS Monitor")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button {
                                showPasswordSettings = true
                            } label: {
                                Label("Đổi mật khẩu", systemImage: "key")
                            }
                            Button {
                                lock.lock()
                            } label: {
                                Label("Khoá app", systemImage: "lock")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .foregroundStyle(Color.bmsMuted)
                    }
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
                .sheet(isPresented: $showPasswordSettings) {
                    NavigationStack {
                        PasswordSettingsView(lock: lock)
                    }
                }
        }
    }
}
