// BLESession.swift
// Tầng CoreBluetooth (Phase 4 → siết lại cho mạch thật).
//
// Nguyên tắc lấy dữ liệu:
//   1. Chọn kênh TẤT ĐỊNH: ưu tiên UUID đã biết (JK FFE1, JBD FF01/FF02,
//      Daly FFF1/FFF2) và cùng service; loại FFE2 (log JK) + GATT chuẩn.
//   2. Đăng ký notify xong mới gửi lệnh. Không gửi lệnh khi CCCD chưa bật.
//   3. Chỉ đẩy dữ liệu của đúng characteristic đã chọn vào parser.
//   4. Không báo "đang nhận" nếu chưa có khung hợp lệ. Watchdog phân biệt:
//      không nhận byte nào / nhận byte nhưng sai khung / có khung nhưng mất nhịp.
//   5. Ghi lệnh có kiểm soát hàng đợi writeWithoutResponse và có timeout.
//
// iOS KHÔNG cho biết MAC address; kết nối lại dựa trên CBPeripheral.identifier.

import BMSCore
import Combine
import CoreBluetooth
import Foundation

/// Thiết bị quét được. Dùng `id` (UUID do iOS cấp) làm khóa kết nối,
/// không dùng chuỗi "tên · RSSI" vì RSSI đổi liên tục.
struct ScannedDevice: Identifiable, Hashable {
    let id: UUID
    var name: String
    var rssi: Int

    var title: String { "\(name) · \(rssi) dBm" }
}

final class BLESession: NSObject, ObservableObject,
                        CBCentralManagerDelegate, CBPeripheralDelegate {

    // ------------------------------------------------------------ published
    @Published var status = "Sẵn sàng"
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    /// true khi đã nhận được ít nhất một khung BMS hợp lệ.
    @Published private(set) var isStreaming = false
    @Published private(set) var devices: [ScannedDevice] = []
    @Published var lastError: String?
    @Published private(set) var connectedDeviceName = ""

    /// Cách app đang lấy dữ liệu từ thiết bị.
    enum ReadMode: String {
        case none = "Chưa xác định"
        case notify = "Notify"
        case indicate = "Indicate"
        case polling = "Đọc định kỳ (poll)"
        case unreadable = "Không đọc được"
    }

    enum Phase: String {
        case idle = "Chưa kết nối"
        case scanning = "Đang quét"
        case connecting = "Đang kết nối"
        case discovering = "Đang đọc GATT"
        case subscribing = "Đang đăng ký notify"
        case probing = "Đang hỏi mạch"
        case streaming = "Đang nhận dữ liệu"
        case stalled = "Không có dữ liệu"
        case failed = "Lỗi"
        case bluetoothOff = "Bluetooth tắt"
    }

    @Published private(set) var readMode: ReadMode = .none
    @Published private(set) var diagnostics: [String] = []

    // ------------------------------------------------------- số liệu chẩn đoán
    @Published private(set) var rawPacketCount = 0
    @Published private(set) var rawByteCount = 0
    @Published private(set) var validFrameCount = 0
    @Published private(set) var writeCount = 0
    @Published private(set) var lastDataAt: Date?
    @Published private(set) var secondsSinceData: Int?
    @Published private(set) var selectedDataUUID = ""
    @Published private(set) var selectedWriteUUID = ""

    /// Callback UI gọi khi parser có dữ liệu notification mới.
    var onData: (() -> Void)?

    /// Parser dùng chung (Store truyền vào); BLE chỉ đẩy dữ liệu vào.
    let parser: UniversalBmsParser

    init(parser: UniversalBmsParser) {
        self.parser = parser
        super.init()
    }

    deinit {
        stopAllTimers()
    }

    // ------------------------------------------------------------ internals
    private var central: CBCentralManager?
    private var wantsScan = false
    private var scanTimer: Timer?
    private var scanToken = 0

    private var peripheral: CBPeripheral?
    private var pendingConnect: CBPeripheral?
    private var connectTimer: Timer?
    private var known: [UUID: CBPeripheral] = [:]
    private var advertisedNames: [UUID: String] = [:]
    private var advertisedName = ""
    private var brandHint: BMSBrand?

    private var dataChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?
    private var pollChar: CBCharacteristic?
    private var deferredWrite: (payload: [UInt8], characteristic: CBCharacteristic)?
    private var pollCandidate: CBCharacteristic?
    private var dataCandidates: [CBCharacteristic] = []
    private var gattInfos: [GATTCharacteristicInfo] = []
    private var charLookup: [String: CBCharacteristic] = [:]
    private var servicesPending = 0
    private var didFinishDiscovery = false
    private var discoveryTimer: Timer?

    private var notifyTimer: Timer?
    private var notifyConfirmed = false

    private var heartbeat: Timer?
    private var pollTimer: Timer?
    private var watchdog: Timer?
    private var tickStep = 0
    private var commandGeneration = 0
    private var linkStartedAt = Date()
    private var retriedInfo = false
    private var infoRequestedAfterStream = false
    private var watchdogErrorSet = false
    private var lastStatusBrand = ""
    private var lastRejectedSeen = 0

    // ------------------------------------------------------------------ scan
    func toggleScanOrConnect() {
        wantsScan = true
        guard let central else {
            central = CBCentralManager(delegate: self, queue: .main)
            status = "Đang khởi động Bluetooth..."
            return
        }
        if central.state == .poweredOn {
            startScan()
        } else {
            status = "Bluetooth chưa sẵn sàng (\(central.state.rawValue))"
        }
    }

    /// Gọi khi mở màn hình quét: không reset danh sách nếu đang quét dở.
    func beginScanIfNeeded() {
        guard !isConnected, !isScanning else { return }
        wantsScan = true
        if let central {
            if central.state == .poweredOn { startScan() }
            else { status = "Bluetooth chưa sẵn sàng (\(central.state.rawValue))" }
        } else {
            central = CBCentralManager(delegate: self, queue: .main)
            status = "Đang khởi động Bluetooth..."
        }
    }

    private func startScan() {
        guard let central, central.state == .poweredOn else {
            status = "Bluetooth chưa sẵn sàng"
            return
        }
        central.stopScan()
        scanTimer?.invalidate()
        scanToken += 1
        let token = scanToken
        wantsScan = false
        known.removeAll(keepingCapacity: true)
        advertisedNames.removeAll(keepingCapacity: true)
        devices.removeAll()
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
        phase = .scanning
        status = "Đang quét Bluetooth BLE (8 giây)..."
        scanTimer = after(8.0) { [weak self] in
            guard let self, self.scanToken == token else { return }
            self.central?.stopScan()
            self.isScanning = false
            if self.devices.isEmpty {
                self.status = "Không tìm thấy thiết bị Bluetooth nào"
            } else {
                self.status = "Tìm thấy \(self.devices.count) thiết bị"
            }
            if self.phase == .scanning { self.phase = .idle }
        }
    }

    // -------------------------------------------------------------- connect
    func connect(deviceID: UUID) {
        guard let target = known[deviceID] else {
            status = "Thiết bị không còn trong danh sách quét — quét lại"
            return
        }
        central?.stopScan()
        scanTimer?.invalidate()
        scanTimer = nil
        scanToken += 1
        isScanning = false

        resetForConnection()
        let display = devices.first(where: { $0.id == deviceID })?.name
            ?? target.name
            ?? "(Không tên)"
        connectedDeviceName = display
        advertisedName = advertisedNames[deviceID] ?? display
        brandHint = BMSBrand.detect(fromDeviceName: advertisedName)
            ?? BMSBrand.detect(fromDeviceName: display)

        if let current = peripheral, current.state != .disconnected {
            pendingConnect = target
            status = "Đang ngắt kết nối cũ để kết nối lại..."
            central?.cancelPeripheralConnection(current)
            return
        }
        beginConnect(target)
    }

    private func beginConnect(_ target: CBPeripheral) {
        peripheral = target
        isConnected = false
        isStreaming = false
        readMode = .none
        phase = .connecting
        status = "Đang kết nối [\(connectedDeviceName)]..."
        linkStartedAt = Date()
        connectTimer?.invalidate()
        connectTimer = after(12.0) { [weak self] in
            guard let self, !self.isConnected,
                  let current = self.peripheral,
                  current.identifier == target.identifier else { return }
            self.central?.cancelPeripheralConnection(current)
            self.phase = .failed
            self.status = "Hết thời gian kết nối [\(self.connectedDeviceName)]"
            self.lastError = "Không kết nối được trong 12 giây. Kiểm tra mạch đã bật "
                + "và không bị app/điện thoại khác giữ kết nối."
        }

        if target.state == .connected {
            handleConnected(target)
        } else if target.state == .connecting {
            status = "Đang chờ iOS hoàn tất kết nối [\(connectedDeviceName)]..."
        } else {
            central?.connect(target, options: nil)
        }
    }

    private func handleConnected(_ peripheral: CBPeripheral) {
        connectTimer?.invalidate()
        connectTimer = nil
        self.peripheral = peripheral
        peripheral.delegate = self
        isConnected = true
        phase = .discovering
        status = "Đã kết nối [\(connectedDeviceName)] — đang đọc service/characteristic..."
        peripheral.discoverServices(nil)
    }

    func disconnect(silent: Bool = false) {
        let current = peripheral
        scanTimer?.invalidate()
        scanTimer = nil
        scanToken += 1
        central?.stopScan()
        isScanning = false
        pendingConnect = nil
        tearDownLink()
        if let current {
            central?.cancelPeripheralConnection(current)
        }
        if !silent {
            status = "Đã ngắt kết nối BLE"
        }
    }

    // ------------------------------------------------- CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            status = "Bluetooth đã sẵn sàng"
            if wantsScan, !isConnected, !isScanning {
                startScan()
            }
        case .poweredOff:
            isScanning = false
            wantsScan = false
            tearDownLink()
            phase = .bluetoothOff
            status = "Bluetooth đang tắt"
        case .unauthorized:
            isScanning = false
            wantsScan = false
            tearDownLink()
            phase = .failed
            status = "Chưa cấp quyền Bluetooth cho ứng dụng"
            lastError = "Vào Settings → BMS Monitor → Bluetooth để bật quyền."
        case .unsupported:
            isScanning = false
            wantsScan = false
            tearDownLink()
            phase = .failed
            status = "Thiết bị không hỗ trợ BLE"
        default:
            status = "Bluetooth: \(central.state.rawValue)"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = nonEmptyName(advName)
            ?? nonEmptyName(peripheral.name)
            ?? "(Không tên)"

        known[peripheral.identifier] = peripheral
        if let advName, !advName.isEmpty {
            advertisedNames[peripheral.identifier] = advName
        }

        if let index = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[index].rssi = RSSI.intValue
            if name != "(Không tên)" { devices[index].name = name }
        } else {
            devices.append(ScannedDevice(
                id: peripheral.identifier, name: name, rssi: RSSI.intValue))
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        handleConnected(peripheral)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        connectTimer?.invalidate()
        connectTimer = nil
        tearDownLink()
        phase = .failed
        let reason = error?.localizedDescription
            ?? "Thiết bị không phản hồi. Có thể mạch đang bị app khác giữ kết nối."
        lastError = reason
        status = "Kết nối thất bại: \(reason)"
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // Ngắt do chính app gọi: disconnect() đã dọn state và set nil.
        guard self.peripheral === peripheral else { return }

        let wasStreaming = isStreaming
        tearDownLink()

        if let next = pendingConnect {
            pendingConnect = nil
            beginConnect(next)
            return
        }

        phase = .idle
        isConnected = false
        if let error {
            lastError = error.localizedDescription
            status = "Mất kết nối: \(error.localizedDescription)"
        } else {
            status = wasStreaming ? "Mất kết nối BLE" : "Đã ngắt kết nối"
        }
    }

    // ------------------------------------------------- CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        servicesPending = 0
        didFinishDiscovery = false
        gattInfos.removeAll()
        charLookup.removeAll()
        dataCandidates.removeAll()
        // Khi discovery chạy lại (reconnect/đọc lại GATT) phải bỏ mọi lựa chọn
        // cũ, nếu không sẽ notify/ghi lên characteristic đã bị hủy.
        dataChar = nil
        writeChar = nil
        pollChar = nil
        pollCandidate = nil
        notifyTimer?.invalidate()
        notifyTimer = nil
        notifyConfirmed = false

        if let error {
            appendDiagnostic("Lỗi đọc service: \(error.localizedDescription)")
        }
        guard let services = peripheral.services, !services.isEmpty else {
            phase = .failed
            status = "Thiết bị không công bố service BLE nào"
            appendDiagnostic("Không có service — có thể cần pairing hoặc sai thiết bị.")
            return
        }

        servicesPending = services.count
        appendDiagnostic("Tìm thấy \(services.count) service")
        discoveryTimer?.invalidate()
        discoveryTimer = after(6.0) { [weak self] in
            self?.finishDiscovery()
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
        if let error {
            appendDiagnostic("Lỗi characteristic \(short(service.uuid)): "
                + error.localizedDescription)
        }
        appendDiagnostic("① \(short(service.uuid))")
        for characteristic in service.characteristics ?? [] {
            let props = characteristic.properties
            appendDiagnostic("   ↳ \(short(characteristic.uuid)) [\(describe(props))]")

            let info = GATTCharacteristicInfo(
                uuid: characteristic.uuid.uuidString,
                serviceUUID: service.uuid.uuidString,
                canRead: props.contains(.read),
                canWrite: props.contains(.write),
                canWriteWithoutResponse: props.contains(.writeWithoutResponse),
                canNotify: props.contains(.notify),
                canIndicate: props.contains(.indicate))
            gattInfos.append(info)
            charLookup[info.key] = characteristic
        }

        servicesPending -= 1
        if servicesPending <= 0 {
            finishDiscovery()
        }
    }

    private func finishDiscovery() {
        guard !didFinishDiscovery, isConnected, let peripheral else { return }
        didFinishDiscovery = true
        discoveryTimer?.invalidate()
        discoveryTimer = nil

        let nameHint = [connectedDeviceName, advertisedName]
            .filter { !$0.isEmpty && $0 != "(Không tên)" }
            .joined(separator: " ")
        let selection = BLEEndpointSelector.select(
            from: gattInfos, advertisedName: nameHint)
        brandHint = selection.brandHint ?? brandHint
        for reason in selection.reasons { appendDiagnostic(reason) }

        dataCandidates = selection.dataCandidates.compactMap { charLookup[$0.key] }
        pollCandidate = selection.poll.flatMap { charLookup[$0.key] }
        if let info = selection.write, let char = charLookup[info.key] {
            writeChar = char
        }

        if let info = selection.data, let data = charLookup[info.key] {
            dataChar = data
            if writeChar == nil, info.isWritable { writeChar = data }
            selectedDataUUID = short(data.uuid)
            selectedWriteUUID = writeChar.map { short($0.uuid) } ?? "—"
            readMode = info.canNotify ? .notify : .indicate
            phase = .subscribing
            status = "Chọn \(readMode.rawValue) \(selectedDataUUID) · ghi \(selectedWriteUUID)"
                + " — đang đăng ký..."
            appendDiagnostic(
                "Đăng ký \(readMode.rawValue) trên \(selectedDataUUID); "
                + "ghi lệnh trên \(selectedWriteUUID)")
            peripheral.setNotifyValue(true, for: data)
            startNotifyTimeout()
            return
        }

        if let poll = pollCandidate {
            pollChar = poll
            selectedDataUUID = short(poll.uuid)
            selectedWriteUUID = writeChar.map { short($0.uuid) } ?? "—"
            readMode = .polling
            phase = .probing
            status = "Thiết bị không có notify — đọc định kỳ \(selectedDataUUID)"
            appendDiagnostic("Fallback đọc định kỳ \(selectedDataUUID)")
            startPolling()
            startActivationSequence()
            startHeartbeat()
            startWatchdog()
            return
        }

        readMode = .unreadable
        phase = .failed
        status = "Không tìm thấy kênh đọc/ghi phù hợp"
        lastError = "Thiết bị chỉ cho ghi hoặc chỉ có characteristic chuẩn, "
            + "không có kênh dữ liệu BMS."
        appendDiagnostic("Không có kênh dữ liệu: \(selection.reasons.joined(separator: "; "))")
    }

    private func startNotifyTimeout() {
        notifyTimer?.invalidate()
        // CCCD trên một số mạch JK/JBD phản hồi chậm hơn 3 giây khi vừa kết
        // nối. Chờ 5 giây trước khi kết luận notify không bật được.
        notifyTimer = after(5.0) { [weak self] in
            guard let self, !self.notifyConfirmed else { return }
            self.tryNextDataCharacter(reason: "không có xác nhận notify sau 5 giây")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic === dataChar else { return }
        notifyTimer?.invalidate()
        notifyTimer = nil

        if let error {
            appendDiagnostic("Notify \(short(characteristic.uuid)) lỗi: "
                + error.localizedDescription)
            lastError = error.localizedDescription
            tryNextDataCharacter(reason: error.localizedDescription)
            return
        }

        guard characteristic.isNotifying else {
            tryNextDataCharacter(reason: "notify bị tắt")
            return
        }

        notifyConfirmed = true
        lastError = nil
        phase = .probing
        status = "Đã đăng ký \(readMode.rawValue) \(selectedDataUUID) — đang gửi lệnh đọc..."
        appendDiagnostic("Notify đã bật trên \(selectedDataUUID)")
        startActivationSequence()
        startHeartbeat()
        startWatchdog()
    }

    private func tryNextDataCharacter(reason: String) {
        notifyTimer?.invalidate()
        notifyTimer = nil
        notifyConfirmed = false
        guard let peripheral, let current = dataChar else {
            fallbackToPolling(reason: reason)
            return
        }
        dataCandidates.removeAll { $0 === current }
        dataChar = nil

        guard let next = dataCandidates.first else {
            fallbackToPolling(reason: reason)
            return
        }
        dataChar = next
        readMode = next.properties.contains(.notify) ? .notify : .indicate
        selectedDataUUID = short(next.uuid)
        phase = .subscribing
        status = "\(readMode.rawValue) \(selectedDataUUID) lỗi (\(reason)) — thử "
            + "\(short(next.uuid))..."
        appendDiagnostic("Thử notify kế tiếp \(selectedDataUUID)")
        peripheral.setNotifyValue(true, for: next)
        startNotifyTimeout()
    }

    private func fallbackToPolling(reason: String) {
        dataChar = nil
        guard let poll = pollCandidate else {
            readMode = .unreadable
            phase = .failed
            status = "Không dùng được notify (\(reason)) và không có kênh read."
            lastError = "Thiết bị không cho notify và cũng không có characteristic read. "
                + "iOS không thể lấy dữ liệu."
            appendDiagnostic("Hết đường đọc: \(reason)")
            return
        }
        pollChar = poll
        selectedDataUUID = short(poll.uuid)
        readMode = .polling
        phase = .probing
        status = "Notify lỗi (\(reason)) — chuyển sang đọc định kỳ \(selectedDataUUID)"
        appendDiagnostic("Fallback poll \(selectedDataUUID): \(reason)")
        startPolling()
        startActivationSequence()
        startHeartbeat()
        startWatchdog()
    }

    // -------------------------------------------------------- activation/probe
    private func effectiveBrand() -> BMSBrand? {
        if let brand = BMSBrand(rawValue: parser.bmsBrand) { return brand }
        return brandHint
    }

    private func startActivationSequence() {
        guard isConnected, writeChar != nil else {
            appendDiagnostic("Không có kênh ghi — chỉ có thể chờ notify tự đẩy.")
            return
        }
        commandGeneration += 1
        let generation = commandGeneration
        let counter = UInt8(max(1, tickStep % 250))

        switch effectiveBrand() {
        case .jk:
            scheduleSend(BMSCommand.jkFrame(cmd: BMSCommand.jkDeviceInfoCmd, counter: counter),
                         after: 0.05, generation: generation)
            scheduleSend(BMSCommand.jkFrame(cmd: BMSCommand.jkCellInfoCmd, counter: counter),
                         after: 0.45, generation: generation)
            scheduleSend(BMSCommand.jkFrame(cmd: BMSCommand.jkDeviceInfoCmd, counter: counter &+ 1),
                         after: 0.90, generation: generation)
        case .jbd:
            scheduleSend(BMSCommand.jbdRead(cmd: 0x03), after: 0.05, generation: generation)
            scheduleSend(BMSCommand.jbdReadDeviceName(), after: 0.45, generation: generation)
            scheduleSend(BMSCommand.jbdRead(cmd: 0x04), after: 0.85, generation: generation)
        case .daly:
            scheduleSend(BMSCommand.dalyStatusRequest, after: 0.05, generation: generation)
        case .ant:
            scheduleSend(BMSCommand.antWakeup, after: 0.05, generation: generation)
        case nil:
            scheduleProbeSequence(generation: generation)
        }
    }

    /// Khi chưa biết hãng: thăm dò TUẦN TỰ, không dội 4 họ lệnh cùng lúc.
    private func scheduleProbeSequence(generation: Int) {
        let steps: [(delay: Double, payload: [UInt8], label: String)] = [
            (0.05, BMSCommand.antWakeup, "ANT wakeup"),
            (1.20, BMSCommand.jkFrame(cmd: BMSCommand.jkDeviceInfoCmd, counter: 1), "JK 0x97"),
            (2.40, BMSCommand.jkFrame(cmd: BMSCommand.jkCellInfoCmd, counter: 2), "JK 0x96"),
            (3.60, BMSCommand.jbdRead(cmd: 0x03), "JBD 0x03"),
            (4.80, BMSCommand.jbdReadDeviceName(), "JBD 0x05"),
            (6.00, BMSCommand.jbdRead(cmd: 0x04), "JBD 0x04"),
            (7.20, BMSCommand.dalyStatusRequest, "Daly 0x90"),
        ]
        appendDiagnostic("Chưa rõ hãng — thăm dò tuần tự 7 lệnh trong 7,2 giây")
        for step in steps {
            scheduleSend(step.payload,
                         after: step.delay,
                         generation: generation,
                         onlyIfUnknown: true)
        }
    }

    private func scheduleSend(
        _ payload: [UInt8],
        after delay: Double,
        generation: Int,
        onlyIfUnknown: Bool = false
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isConnected,
                  self.commandGeneration == generation else { return }
            if onlyIfUnknown, self.effectiveBrand() != nil { return }
            guard let write = self.writeChar else { return }
            self.writeCommand(payload, to: write)
        }
    }

    /// UI gọi để đọc lại thông tin thiết bị (và cũng dùng cho nút refresh).
    func requestDeviceInfo() {
        guard isConnected, let write = writeChar else { return }
        let generation = commandGeneration
        let counter = UInt8(max(1, tickStep % 250))
        let brand = effectiveBrand()
        lastError = nil
        switch brand {
        case .jk:
            scheduleSend(BMSCommand.jkFrame(cmd: BMSCommand.jkDeviceInfoCmd,
                                            counter: counter),
                         after: 0, generation: generation)
            scheduleSend(BMSCommand.jkFrame(cmd: BMSCommand.jkDeviceInfoCmd,
                                            counter: counter &+ 1),
                         after: 0.45, generation: generation)
            status = "Đang gửi lại lệnh JK 0x97 (device info)..."
        case .jbd:
            scheduleSend(BMSCommand.jbdReadDeviceName(), after: 0, generation: generation)
            status = "Đang gửi lại lệnh JBD 0x05 (device name)..."
        case .daly:
            writeCommand(BMSCommand.dalyStatusRequest, to: write)
            status = "Đang gửi lại lệnh Daly 0x90..."
        case .ant:
            writeCommand(BMSCommand.antWakeup, to: write)
            status = "Đang gửi lại lệnh đánh thức ANT..."
        case nil:
            startActivationSequence()
        }
    }

    // --------------------------------------------------------------- timers
    private func startHeartbeat() {
        heartbeat?.invalidate()
        tickStep = 0
        heartbeat = every(1.0) { [weak self] in
            self?.heartbeatTick()
        }
    }

    private func heartbeatTick() {
        tickStep += 1
        guard tickStep % 2 == 0, isConnected,
              readMode != .none, readMode != .unreadable,
              let write = writeChar else { return }
        let counter = UInt8(max(1, tickStep % 250))

        switch effectiveBrand() {
        case .jk:
            // Live mỗi 2 giây; device info mỗi 4 giây để bắt thay đổi.
            if tickStep % 4 == 0 {
                writeCommand(BMSCommand.jkFrame(cmd: BMSCommand.jkDeviceInfoCmd,
                                                counter: counter), to: write)
            } else {
                writeCommand(BMSCommand.jkFrame(cmd: BMSCommand.jkCellInfoCmd,
                                                counter: counter), to: write)
            }
        case .jbd:
            if parser.deviceInfo.deviceName.isEmpty || tickStep % 40 == 0 {
                writeCommand(BMSCommand.jbdReadDeviceName(), to: write)
            } else if tickStep % 6 == 0 {
                writeCommand(BMSCommand.jbdRead(cmd: 0x03), to: write)
            } else {
                writeCommand(BMSCommand.jbdRead(cmd: 0x04), to: write)
            }
        case .daly:
            writeCommand(BMSCommand.dalyStatusRequest, to: write)
        case .ant:
            writeCommand(BMSCommand.antWakeup, to: write)
        case nil:
            // Chưa nhận diện: lặp lại chuỗi thăm dò tuần tự mỗi 16 giây.
            if tickStep % 8 == 0 { startActivationSequence() }
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollOnce()
        pollTimer = every(1.2) { [weak self] in
            self?.pollOnce()
        }
    }

    /// Đọc một lần ngay (nút "Đọc ngay" và sau mỗi lệnh ghi).
    func pollNow() {
        guard isConnected else { return }
        if readMode == .polling {
            pollOnce()
        } else {
            requestDeviceInfo()
        }
    }

    private func pollOnce() {
        guard isConnected, readMode == .polling,
              let peripheral, peripheral.state == .connected,
              let pollChar,
              pollChar.properties.contains(.read) else { return }
        peripheral.readValue(for: pollChar)
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        // Đặt lại mốc từ lúc bắt đầu xin dữ liệu, không tính thời gian kết nối
        // + khám phá GATT (nếu không watchdog sẽ báo "chưa có dữ liệu" ngay).
        linkStartedAt = Date()
        watchdogErrorSet = false
        watchdog = every(1.0) { [weak self] in
            self?.watchdogTick()
        }
    }

    private func watchdogTick() {
        guard isConnected else { return }
        let now = Date()

        guard let last = parser.lastFrameAt else {
            secondsSinceData = nil
            let elapsed = now.timeIntervalSince(linkStartedAt)

            if elapsed > 3, !retriedInfo {
                retriedInfo = true
                requestDeviceInfo()
            }

            // Notify đã bật nhưng tuyệt nhiên không có byte nào: thử kênh
            // notify kế tiếp (nếu có) rồi mới kết luận mạch không gửi.
            if elapsed > 6, notifyConfirmed,
               dataCandidates.contains(where: { $0 !== dataChar }) {
                appendDiagnostic("Chưa nhận byte nào sau 6 giây — thử kênh notify kế tiếp")
                tryNextDataCharacter(reason: "không có byte sau 6 giây")
                return
            }

            if elapsed > 8, phase != .stalled {
                phase = .stalled
                if rawPacketCount == 0 {
                    status = "Đã kết nối \(connectedDeviceName) nhưng chưa nhận được byte nào"
                    if !watchdogErrorSet {
                        watchdogErrorSet = true
                        if lastError == nil {
                            lastError = "Không nhận được dữ liệu trên \(selectedDataUUID). "
                                + "Characteristic notify có thể sai hoặc mạch chưa gửi."
                        }
                    }
                } else {
                    status = "Đã nhận \(rawByteCount) byte nhưng chưa có khung hợp lệ"
                    if !watchdogErrorSet {
                        watchdogErrorSet = true
                        if lastError == nil {
                            lastError = "Có \(rawPacketCount) gói (\(rawByteCount) byte) nhưng "
                                + "không khung nào qua kiểm tra "
                                + "(\(parser.lastRejectReason ?? "?")). "
                                + "Có thể chọn sai characteristic hoặc sai giao thức."
                        }
                    }
                }
            }
            return
        }

        let age = Int(now.timeIntervalSince(last))
        secondsSinceData = age

        if age > 6, phase != .stalled {
            phase = .stalled
            status = "Không có khung mới trong \(age) giây — vẫn đang gửi lệnh..."
        } else if age <= 3, phase == .stalled {
            phase = .streaming
            status = "Đã có dữ liệu trở lại (\(parser.bmsBrand))"
        }
    }

    // --------------------------------------------------------------- writes
    private func writeCommand(
        _ payload: [UInt8],
        to characteristic: CBCharacteristic,
        attempt: Int = 0
    ) {
        guard isConnected, let peripheral,
              peripheral.state == .connected else { return }
        let data = Data(payload)
        // Ưu tiên writeWithoutResponse nếu mạch khai báo: khung lệnh JK/JBD
        // không cần ACK ở tầng GATT, và một số firmware JK chỉ nhận kiểu này.
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse

        if type == .withoutResponse, !peripheral.canSendWriteWithoutResponse {
            // Hàng đợi của iOS đang đầy: giữ lệnh mới nhất và thử lại khi
            // CoreBluetooth báo sẵn sàng (peripheralIsReady) hoặc sau 0,1 s.
            deferredWrite = (payload, characteristic)
            if attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
                    guard let self, let pending = self.deferredWrite else { return }
                    self.deferredWrite = nil
                    self.writeCommand(pending.payload, to: pending.characteristic,
                                      attempt: attempt + 1)
                }
            } else {
                appendDiagnostic("Bỏ lệnh \(payload.count)B: hàng đợi writeWithoutResponse đầy")
            }
            return
        }

        deferredWrite = nil
        peripheral.writeValue(data, for: characteristic, type: type)
        writeCount += 1

        if readMode == .polling {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                self?.pollOnce()
            }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let pending = deferredWrite else { return }
        deferredWrite = nil
        writeCommand(pending.payload, to: pending.characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let error else { return }
        lastError = error.localizedDescription
        appendDiagnostic("Ghi lỗi \(short(characteristic.uuid)): "
            + error.localizedDescription)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        // Chỉ nhận dữ liệu từ đúng kênh đã chọn. Trước đây mọi notify/read
        // đều đổ vào parser nên log debug hoặc Battery Level có thể làm hỏng
        // buffer.
        guard characteristic === dataChar || characteristic === pollChar else { return }

        if let error {
            lastError = error.localizedDescription
            appendDiagnostic("Đọc \(short(characteristic.uuid)) lỗi: "
                + error.localizedDescription)
            return
        }
        guard let value = characteristic.value, !value.isEmpty else { return }

        rawPacketCount += 1
        rawByteCount += value.count
        let events = parser.feed(value)

        if parser.rejectedFrames > lastRejectedSeen {
            lastRejectedSeen = parser.rejectedFrames
            if let reason = parser.lastRejectReason {
                appendDiagnostic("Loại khung: \(reason)")
            }
        }

        guard !events.isEmpty else { return }

        validFrameCount = parser.acceptedFrames
        lastDataAt = parser.lastFrameAt
        isStreaming = true
        secondsSinceData = 0
        if watchdogErrorSet {
            watchdogErrorSet = false
            lastError = nil
        }
        if phase != .streaming {
            phase = .streaming
        }

        let brand = parser.bmsBrand
        if brand != lastStatusBrand {
            lastStatusBrand = brand
            status = "Đang nhận \(brand) qua \(readMode.rawValue) (\(selectedDataUUID))"
        }

        // JK/JBD cần lệnh riêng cho device info; gửi lại ngay khi có khung
        // đầu tiên để bù trường hợp lệnh ban đầu rơi mất.
        if !parser.hasDeviceInfo, !infoRequestedAfterStream,
           (brand == BMSBrand.jk.rawValue || brand == BMSBrand.jbd.rawValue) {
            infoRequestedAfterStream = true
            requestDeviceInfo()
        }

        onData?()
    }

    // --------------------------------------------------------------- helpers
    private func short(_ uuid: CBUUID) -> String {
        BLEEndpointSelector.shortUUID(uuid.uuidString)
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

    private func nonEmptyName(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private func appendDiagnostic(_ line: String) {
        diagnostics.append(line)
        if diagnostics.count > 80 {
            diagnostics.removeFirst(diagnostics.count - 80)
        }
    }

    private func resetForConnection() {
        parser.reset()
        lastError = nil
        diagnostics.removeAll()
        rawPacketCount = 0
        rawByteCount = 0
        validFrameCount = 0
        writeCount = 0
        lastDataAt = nil
        secondsSinceData = nil
        selectedDataUUID = ""
        selectedWriteUUID = ""
        lastStatusBrand = ""
        lastRejectedSeen = 0
        tickStep = 0
        retriedInfo = false
        infoRequestedAfterStream = false
        watchdogErrorSet = false
        linkStartedAt = Date()
        brandHint = nil
        // Bỏ kênh cũ ngay: nếu đang kết nối lại, notification của thiết bị cũ
        // có thể còn tới trước khi didDisconnect chạy và làm bẩn parser mới.
        dataChar = nil
        writeChar = nil
        pollChar = nil
        pollCandidate = nil
        dataCandidates.removeAll()
        gattInfos.removeAll()
        charLookup.removeAll()
        notifyConfirmed = false
        deferredWrite = nil
    }

    /// Dọn tài nguyên kết nối nhưng GIỮ số liệu chẩn đoán gần nhất.
    private func tearDownLink() {
        connectTimer?.invalidate()
        connectTimer = nil
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        notifyTimer?.invalidate()
        notifyTimer = nil
        heartbeat?.invalidate()
        heartbeat = nil
        pollTimer?.invalidate()
        pollTimer = nil
        watchdog?.invalidate()
        watchdog = nil
        commandGeneration += 1

        peripheral = nil
        dataChar = nil
        writeChar = nil
        pollChar = nil
        pollCandidate = nil
        deferredWrite = nil
        dataCandidates.removeAll()
        gattInfos.removeAll()
        charLookup.removeAll()
        servicesPending = 0
        didFinishDiscovery = false
        notifyConfirmed = false
        isConnected = false
        isStreaming = false
        readMode = .none
        phase = .idle
        secondsSinceData = nil
    }

    private func stopAllTimers() {
        [scanTimer, connectTimer, discoveryTimer, notifyTimer,
         heartbeat, pollTimer, watchdog].forEach { $0?.invalidate() }
        scanTimer = nil
        connectTimer = nil
        discoveryTimer = nil
        notifyTimer = nil
        heartbeat = nil
        pollTimer = nil
        watchdog = nil
    }

    @discardableResult
    private func every(_ interval: TimeInterval,
                       _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in body() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    @discardableResult
    private func after(_ delay: TimeInterval,
                       _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in body() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
