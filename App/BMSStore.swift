// BMSStore.swift
// Ô chứa trạng thái chung cho UI: parser (golden test đã chuẩn) + phiên BLE.
// Mọi thay đổi dữ liệu làm bump revision để view render lại.

import Combine
import BMSCore
import Foundation
import SwiftUI

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
        loadDemo(named: "ant_17s_demo")   // dữ liệu mẫu lúc mở app (như bản gốc)
    }

    // ------------------------------------------------------------- read API
    var live: BMSLiveTelemetry { parser.live }
    var deviceInfo: BMSDeviceInfo { parser.deviceInfo }
    var settingsInfo: BMSSettingsInfo { parser.settingsInfo }

    var eta: BMSEtaResult { BMSEtaEstimator.estimate(live) }

    // ------------------------------------------------------------ demo mode
    func loadDemo(named: String) {
        session.disconnect()
        parser.reset()
        guard let frames = GoldenVectorStore.framesHex(named: named) else { return }
        for hex in frames {
            guard let data = GoldenVectorCheck.makeData(hex: hex) else { continue }
            parser.feed(data)
        }
        bump()
    }

    // -------------------------------------------------------------- connect
    /// true khi phiên BLE đang mở (thay vì đang xem demo).
    var isLive: Bool { session.isConnected }

    func toggleLiveConnection() {
        if session.isConnected {
            session.disconnect()
            parser.reset()
            bump()
        } else {
            session.toggleScanOrConnect()
        }
    }

    // ---------------------------------------------------------------- misc
    private func bump() { revision += 1 }
}
