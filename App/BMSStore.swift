// BMSStore.swift
// Ô chứa trạng thái chung cho UI: parser (golden test đã chuẩn) + phiên BLE.
// Mọi thay đổi dữ liệu làm bump revision để view render lại.
//
// Không còn dữ liệu mẫu: app chỉ hiển thị thông tin đọc từ mạch thật.
// Màn hình chính chuyển giữa "chưa kết nối" và "đã kết nối" dựa trên
// `session.isConnected`.

import Combine
import BMSCore
import Foundation

@MainActor
final class BMSStore: ObservableObject {

    let parser = UniversalBmsParser()
    let session: BLESession

    /// Tăng lên mỗi lần dữ liệu (parser hoặc trạng thái BLE) thay đổi.
    @Published private(set) var revision = 0

    private var bag = Set<AnyCancellable>()

    init() {
        session = BLESession(parser: parser)
        session.onData = { [weak self] in self?.bump() }
        session.objectWillChange
            .sink { [weak self] _ in self?.bump() }
            .store(in: &bag)
    }

    // ------------------------------------------------------------- read API
    var live: BMSLiveTelemetry { parser.live }
    var deviceInfo: BMSDeviceInfo { parser.deviceInfo }
    var settingsInfo: BMSSettingsInfo { parser.settingsInfo }
    var provenance: BMSDeviceInfoProvenance { parser.deviceInfoProvenance }

    /// Có thiết bị BLE đang kết nối (đã qua bước didConnect).
    var isConnected: Bool { session.isConnected }

    /// Có khung BMS hợp lệ từ mạch thật trong phiên hiện tại.
    var hasRealData: Bool { parser.hasAcceptedFrame }

    // -------------------------------------------------------------- connect
    /// Bắt đầu phiên mới: xoá dữ liệu của lần đọc trước rồi kết nối.
    func connect(deviceID: UUID) {
        parser.reset()
        session.connect(deviceID: deviceID)
        bump()
    }

    func disconnect() {
        session.disconnect()
        bump()
    }

    // ---------------------------------------------------------------- misc
    private func bump() { revision += 1 }
}
