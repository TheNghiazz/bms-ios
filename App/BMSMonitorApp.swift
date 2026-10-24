// BMSMonitorApp.swift
// Điểm vào app. RootView giữ Store và chuyển giữa hai trạng thái:
//   - chưa kết nối: ConnectLandingView (nút BLE ở trung tâm)
//   - đã kết nối:  DeviceInfoView (header thiết bị + danh sách thông tin)
// Không còn navigation bar/toolbar quét — mọi thao tác nằm trong hai màn hình.

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
        ZStack {
            if store.isConnected {
                DeviceInfoView(store: store, onDisconnect: { store.disconnect() })
                    .transition(.opacity)
            } else {
                ConnectLandingView(store: store, onConnect: { showScan = true })
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: store.isConnected)
        .tint(Color.bmsGreen)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showScan) {
            NavigationStack {
                ScanSheet(store: store)
            }
            .presentationDetents([.medium, .large])
            .tint(Color.bmsGreen)
            .preferredColorScheme(.dark)
        }
    }
}
