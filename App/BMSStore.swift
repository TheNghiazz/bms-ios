// BMSStore.swift
// Ô chứa trạng thái chung cho UI: parser (golden test đã chuẩn) + phiên BLE.
// Mọi thay đổi dữ liệu làm bump revision để view render lại.
//
// `isDemo` tách bạch dữ liệu mẫu với dữ liệu mạch thật: trước đây chỉ dựa
// vào isConnected nên khi mất kết nối, dữ liệu thật cũ bị gắn nhãn "demo".

import Combine
import BMSCore
import Foundation

@MainActor
final class BMSStore: ObservableObject {

    let parser = UniversalBmsParser()
    let session: BLESession

    /// Tăng lên mỗi lần dữ liệu (parser hoặc trạng thái BLE) thay đổi.
    @Published private(set) var revision = 0

    /// true = đang xem dữ liệu mẫu; false = đang/đã kết nối mạch thật.
    @Published private(set) var isDemo = true

    private var bag = Set<AnyCancellable>()

    init() {
        session = BLESession(parser: parser)
        session.onData = { [weak self] in self?.bump() }
        session.objectWillChange
            .sink { [weak self] _ in self?.bump() }
            .store(in: &bag)
        loadDemo(named: "ant_17s_demo")   // dữ liệu mẫu lúc mở app (như bản gốc)
    }

    // ------------------------------------------------------------- read API
    var live: BMSLiveTelemetry { parser.live }
    var deviceInfo: BMSDeviceInfo { parser.deviceInfo }
    var settingsInfo: BMSSettingsInfo { parser.settingsInfo }
    var provenance: BMSDeviceInfoProvenance { parser.deviceInfoProvenance }

    // ------------------------------------------------------------ demo mode
    func loadDemo(named: String) {
        session.disconnect(silent: true)
        parser.reset()
        isDemo = true
        guard let frames = GoldenVectorStore.framesHex(named: named) else { return }
        for hex in frames {
            guard let data = GoldenVectorCheck.makeData(hex: hex) else { continue }
            parser.feed(data)
        }
        bump()
    }

    // -------------------------------------------------------------- connect
    /// true khi người dùng đang ở chế độ mạch thật (kể cả lúc chờ dữ liệu).
    var isLive: Bool { !isDemo }

    /// Có khung BMS hợp lệ từ mạch thật trong phiên hiện tại.
    var hasRealData: Bool { !isDemo && parser.hasAcceptedFrame }

    func connect(deviceID: UUID) {
        isDemo = false
        session.connect(deviceID: deviceID)
        bump()
    }

    func toggleLiveConnection() {
        if session.isConnected {
            // Ngắt BLE rồi quay về dữ liệu mẫu để màn hình không trống.
            loadDemo(named: "ant_17s_demo")
        } else {
            session.toggleScanOrConnect()
        }
    }

    // ---------------------------------------------------------------- misc
    private func bump() { revision += 1 }
}
