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

    /// Dung lượng khối pin nhập tay (Ah) — dùng khi BMS không khai báo.
    @Published var manualCapacityAh: Double {
        didSet { UserDefaults.standard.set(manualCapacityAh, forKey: Self.capacityKey) }
    }

    private static let capacityKey = "bms.manualCapacityAh"

    private var bag = Set<AnyCancellable>()

    init() {
        manualCapacityAh = UserDefaults.standard.double(forKey: Self.capacityKey)
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

    var eta: BMSEtaResult {
        var snapshot = live
        if snapshot.nominalCapacityAh <= 0, manualCapacityAh > 0 {
            snapshot.nominalCapacityAh = manualCapacityAh
        }
        if snapshot.socPercent == 0,
           snapshot.nominalCapacityAh > 0,
           snapshot.remainingCapacityAh > 0 {
            let pct = snapshot.remainingCapacityAh / snapshot.nominalCapacityAh * 100.0
            snapshot.socPercent = min(100, max(0, Int(pct.rounded())))
        }
        return BMSEtaEstimator.estimate(snapshot)
    }

    /// Dung lượng hiển thị (Ah): ưu tiên số mạch gửi, nếu không có thì dùng số nhập tay.
    var capacityAh: Double {
        live.nominalCapacityAh > 0 ? live.nominalCapacityAh : manualCapacityAh
    }

    /// % pin hiển thị: ưu tiên SOC mạch gửi; nếu mạch không gửi (0) và biết dung
    /// lượng thì tự tính từ dung lượng còn lại.
    var displaySocPercent: Int {
        if live.socPercent > 0 { return live.socPercent }
        guard capacityAh > 0, live.remainingCapacityAh > 0 else { return 0 }
        let raw = live.remainingCapacityAh / capacityAh * 100.0
        return min(100, max(0, Int(raw.rounded())))
    }

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
