// BLESession.swift
// Tầng CoreBluetooth (Phase 4). Ban đầu giữ phiên bản tối giản nhưng đủ dùng:
// quét -> chọn thiết bị -> kết nối -> subscribe notify -> chuỗi lệnh khởi động
// + heartbeat mỗi 2 giây giống logic GUI gốc (dòng 1110-1215 của file Python).
// Điểm khác với desktop: iOS KHÔNG cho biết MAC address; kết nối lại dựa trên
// CBPeripheral.identifier (cải tiến Phase 6).

import BMSCore
import CoreBluetooth
import Foundation

final class BLESession: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    // ------------------------------------------------------------ published
    @Published var status = "Sẵn sàng"
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var devices: [String] = []
    @Published var lastError: String?

    /// Cách app đang lấy dữ liệu từ thiết bị.
    enum ReadMode: String {
        case none = "Chưa xác định"
        case notify = "Notify"
        case indicate = "Indicate"
        case polling = "Đọc định kỳ (poll)"
        case unreadable = "Không đọc được"
    }

    @Published private(set) var readMode: ReadMode = .none
    /// Danh sách service/characteristic + thuộc tính, để chẩn đoán thiết bị lạ.
    @Published private(set) var diagnostics: [String] = []

    /// Callback UI gọi khi parser có dữ liệu notification mới.
    var onData: (() -> Void)?

    /// Parser dùng chung (Store passes in); BLE chỉ đẩy dữ liệu vào.
    let parser: UniversalBmsParser

    init(parser: UniversalBmsParser) {
        self.parser = parser
        super.init()
    }

    // ------------------------------------------------------------ internals
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var connectedName = ""
    private var known: [String: CBPeripheral] = [:]
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?
    private var servicesDone = 0
    private var tickStep = 0
    private var heartbeat: Timer?
    private var pollTimer: Timer?
    private var pollChar: CBCharacteristic?
    private var readableChars: [CBCharacteristic] = []

    // ------------------------------------------------------------------ scan
    func toggleScanOrConnect() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)   // queue main: đơn giản v1
            status = "Đang khởi động Bluetooth..."
            return
        }
        startScan()
    }

    private func startScan() {
        guard let central, central.state == .poweredOn else {
            status = "Bluetooth chưa sẵn sàng"
            return
        }
        known.removeAll(keepingCapacity: true)
        devices.removeAll()
        central.scanForPeripherals(withServices: nil)
        isScanning = true
        status = "Đang quét Bluetooth BLE (6 giây)..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self else { return }
            self.central?.stopScan()
            self.isScanning = false
            if self.devices.isEmpty {
                self.status = "Không tìm thấy thiết bị Bluetooth nào"
            } else {
                self.status = "Tìm thấy \(self.devices.count) thiết bị"
            }
        }
    }

    // -------------------------------------------------------------- connect
    func connect(deviceName displayName: String) {
        guard let target = known[displayName] else { return }
        disconnect(silent: true)
        connectedName = displayName
        status = "Đang kết nối [\(displayName)]..."
        central?.connect(target)
    }

    func disconnect(silent: Bool = false) {
        heartbeat?.invalidate()
        heartbeat = nil
        pollTimer?.invalidate()
        pollTimer = nil
        pollChar = nil
        readableChars.removeAll()
        readMode = .none
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        notifyChar = nil
        writeChar = nil
        servicesDone = 0
        tickStep = 0
        if !silent {
            isConnected = false
            status = "Đã ngắt kết nối BLE"
        }
    }

    // ------------------------------------------------- CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScan()
        case .poweredOff:
            isScanning = false
            status = "Bluetooth đang tắt"
        case .unauthorized:
            status = "Chưa cấp quyền Bluetooth cho ứng dụng"
        case .unsupported:
            status = "Thiết bị không hỗ trợ BLE"
        default:
            status = "Bluetooth: \(central.state.rawValue)"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // iOS không cho thấy MAC; hiển thị tên + tín hiệu thay thế.
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "(Không tên)"
        let display = "\(name) · \(RSSI.intValue) dBm"
        known[display] = peripheral
        if !devices.contains(display) { devices.append(display) }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        isConnected = true
        status = "Đã kết nối [\(connectedName)], đang đọc dịch vụ..."
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        isConnected = false
        lastError = error?.localizedDescription
        status = "Kết nối thất bại: \(error?.localizedDescription ?? "?")"
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        heartbeat?.invalidate()
        heartbeat = nil
        pollTimer?.invalidate()
        pollTimer = nil
        isConnected = false
        status = "Đã mất kết nối"
        if let error { lastError = error.localizedDescription }
    }

    // ------------------------------------------------- CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        servicesDone = 0
        diagnostics.removeAll()
        readableChars.removeAll()
        notifyChar = nil
        writeChar = nil

        if let error {
            lastError = error.localizedDescription
            status = "Không đọc được dịch vụ: \(error.localizedDescription)"
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            status = "Thiết bị không công bố dịch vụ BLE nào"
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        diagnostics.append("① \(short(service.uuid))")
        for characteristic in service.characteristics ?? [] {
            let props = characteristic.properties
            diagnostics.append("   ↳ \(short(characteristic.uuid)) [\(describe(props))]")

            // Ưu tiên notify; nếu chỉ có indicate thì vẫn dùng được.
            if props.contains(.notify) || props.contains(.indicate) {
                let better = notifyChar == nil
                    || (props.contains(.notify)
                        && !(notifyChar?.properties.contains(.notify) ?? false))
                if better { notifyChar = characteristic }
            }
            if props.contains(.read) {
                readableChars.append(characteristic)
            }
            if (props.contains(.writeWithoutResponse) || props.contains(.write))
                && writeChar == nil {
                writeChar = characteristic
            }
        }
        servicesDone += 1
        let total = peripheral.services?.count ?? 0
        if total > 0 && servicesDone >= total {
            finishLink()
        }
    }

    private func finishLink() {
        heartbeat?.invalidate()
        heartbeat = nil
        pollTimer?.invalidate()
        pollTimer = nil
        guard let peripheral else { return }

        // 1) Notify / Indicate — đường chuẩn, dữ liệu tự đẩy về.
        if let notify = notifyChar {
            let isIndicate = !notify.properties.contains(.notify)
                && notify.properties.contains(.indicate)
            readMode = isIndicate ? .indicate : .notify
            peripheral.setNotifyValue(true, for: notify)
            status = "Đã kết nối: \(connectedName) — luồng \(readMode.rawValue) "
                + "(\(short(notify.uuid)))"
            startActivationSequence()
            startHeartbeat()
            return
        }

        // 2) Không có notify → đọc định kỳ một characteristic có quyền read.
        if let poll = pickPollCharacteristic() {
            pollChar = poll
            readMode = .polling
            status = "Thiết bị không mở notify — chuyển sang đọc định kỳ "
                + "(\(short(poll.uuid)))"
            startActivationSequence()
            startPolling()
            startHeartbeat()
            return
        }

        // 3) Không read, không notify → iOS không có cách lấy dữ liệu.
        readMode = .unreadable
        status = "Thiết bị chỉ cho ghi, không cho đọc — không thể lấy dữ liệu"
    }

    /// Ưu tiên các UUID quen thuộc của BMS/module UART, sau đó lấy cái đầu tiên.
    private func pickPollCharacteristic() -> CBCharacteristic? {
        let preferred = ["ffe1", "ff01", "fff1", "fff2", "ffe2", "ff02", "2a19"]
        for marker in preferred {
            if let match = readableChars.first(where: {
                $0.uuid.uuidString.lowercased().contains(marker)
            }) {
                return match
            }
        }
        return readableChars.first
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
    }

    /// Đọc một lần ngay (dùng cho nút "Đọc ngay" và sau mỗi lệnh ghi).
    func pollNow() {
        pollOnce()
    }

    private func pollOnce() {
        guard isConnected, let peripheral, let pollChar else { return }
        guard pollChar.properties.contains(.read) else { return }
        peripheral.readValue(for: pollChar)
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.heartbeatTick()
        }
    }

    private func short(_ uuid: CBUUID) -> String {
        uuid.uuidString
    }

    private func describe(_ props: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if props.contains(.read) { parts.append("read") }
        if props.contains(.write) { parts.append("write") }
        if props.contains(.writeWithoutResponse) { parts.append("writeNR") }
        if props.contains(.notify) { parts.append("notify") }
        if props.contains(.indicate) { parts.append("indicate") }
        if props.contains(.broadcast) { parts.append("broadcast") }
        return parts.isEmpty ? "—" : parts.joined(separator: "+")
    }

    private func startActivationSequence() {
        if let write = writeChar { writeCommand(BMSCommand.antWakeup, to: write) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let write = self.writeChar, self.isConnected else { return }
            self.writeCommand(
                BMSCommand.jkFrame(cmd: BMSCommand.jkDeviceInfoCmd, counter: 1),
                to: write)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, let write = self.writeChar, self.isConnected else { return }
            self.writeCommand(
                BMSCommand.jkFrame(cmd: BMSCommand.jkCellInfoCmd, counter: 2),
                to: write)
        }
    }

    private func heartbeatTick() {
        tickStep += 1
        guard tickStep % 2 == 0, let write = writeChar, isConnected else { return }
        switch parser.bmsBrand {
        case "ANT-BMS":
            writeCommand(BMSCommand.antWakeup, to: write)
        case "JK-BMS":
            writeCommand(
                BMSCommand.jkFrame(cmd: BMSCommand.jkCellInfoCmd,
                                   counter: UInt8(tickStep % 250)),
                to: write)
        default:
            // Chưa nhận diện hãng: thăm dò cả hai như bản gốc
            writeCommand(BMSCommand.antWakeup, to: write)
            writeCommand(
                BMSCommand.jkFrame(cmd: BMSCommand.jkCellInfoCmd,
                                   counter: UInt8(tickStep % 250)),
                to: write)
        }
    }

    private func writeCommand(_ payload: [UInt8], to characteristic: CBCharacteristic) {
        guard let peripheral else { return }
        let data = Data(payload)
        if characteristic.properties.contains(.writeWithoutResponse) {
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        } else {
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
        // Thiết bị kiểu "ghi lệnh rồi đọc trả lời": đọc ngay sau khi ghi.
        if readMode == .polling {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.pollOnce()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            lastError = error.localizedDescription
            return
        }
        guard let value = characteristic.value, !value.isEmpty else { return }
        parser.feed(value)
        onData?()
    }

    /// Nếu đăng ký notify thất bại (thiết bị từ chối / cần pairing), tự chuyển
    /// sang chế độ đọc định kỳ để vẫn lấy được dữ liệu.
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let error else { return }
        lastError = error.localizedDescription
        guard readMode != .polling, let poll = pickPollCharacteristic() else { return }
        pollChar = poll
        readMode = .polling
        status = "Không đăng ký được notify — chuyển sang đọc định kỳ "
            + "(\(short(poll.uuid)))"
        startPolling()
    }
}
