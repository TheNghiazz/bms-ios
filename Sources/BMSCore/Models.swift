// Models.swift
// Port 1:1 của BMSDeviceInfo / BMSSettingsInfo / BMSLiveTelemetry (dataclass
// trong file Python gốc). Tên trường đã chuyển snake_case -> camelCase, số
// đơn vị nằm ngay trong tên (V / A / Ah / W ...). Codable để đối chiếu với
// golden_vectors.json; Equatable để test so khớp chính xác.

public struct BMSDeviceInfo: Codable, Equatable, Sendable {
    public var vendorId: String = ""
    public var hardwareVersion: String = ""
    public var softwareVersion: String = ""
    public var uptimeSeconds: Int = 0
    public var powerOnCount: Int = 0
    public var deviceName: String = ""
    /// Mật khẩu kết nối Bluetooth (PIN)
    public var devicePasscode: String = ""
    public var manufacturingDate: String = ""
    public var serialNumber: String = ""
    public var passcode: String = ""
    public var userData: String = ""
    /// Mật khẩu cài đặt
    public var setupPasscode: String = ""

    public init() {}
}

public struct BMSSettingsInfo: Codable, Equatable, Sendable {
    public var cellCountConfigured: Int = 0
    public var nominalCapacityAh: Double = 0.0
    public var smartSleepVoltageV: Double = 0.0
    public var cellUvpV: Double = 0.0
    public var cellUvprV: Double = 0.0
    public var cellOvpV: Double = 0.0
    public var cellOvprV: Double = 0.0
    public var balanceTriggerVoltageV: Double = 0.0
    public var startBalanceVoltageV: Double = 0.0
    public var powerOffVoltageV: Double = 0.0
    public var maxChargeCurrentA: Double = 0.0
    public var maxDischargeCurrentA: Double = 0.0
    public var maxBalanceCurrentA: Double = 0.0
    public var chargeSwitchEnabled: Bool = false
    public var dischargeSwitchEnabled: Bool = false
    public var balancerSwitchEnabled: Bool = false

    public init() {}
}

public struct BMSLiveTelemetry: Codable, Equatable, Sendable {
    public var detectedBrand: String = "Tự động nhận diện"
    public var protocolVersion: String = "AUTO"
    public var activeCellCount: Int = 0
    public var cellVoltagesV: [Double] = []
    public var cellResistancesOhm: [Double] = []
    public var averageCellVoltageV: Double = 0.0
    public var deltaCellVoltageV: Double = 0.0
    public var maxCellVoltageV: Double = 0.0
    public var minCellVoltageV: Double = 0.0
    public var maxVoltageCellNum: Int = 0
    public var minVoltageCellNum: Int = 0
    public var totalVoltageV: Double = 0.0
    public var currentA: Double = 0.0
    public var powerW: Double = 0.0
    public var balanceCurrentA: Double = 0.0
    public var balancingAction: Int = 0
    public var balancingStatusText: String = "Tắt (Idle)"
    public var socPercent: Int = 0
    public var sohPercent: Int = 100
    public var remainingCapacityAh: Double = 0.0
    public var nominalCapacityAh: Double = 0.0
    public var cycleCount: Int = 0
    public var totalCycleCapacityAh: Double = 0.0
    public var mosfetTempC: Double = 0.0
    public var tempSensor1C: Double = 0.0
    public var tempSensor2C: Double = 0.0
    public var tempSensor3C: Double? = nil
    public var tempSensor4C: Double? = nil
    public var chargingMosOn: Bool = false
    public var dischargingMosOn: Bool = false
    public var prechargingOn: Bool = false
    public var heatingOn: Bool = false
    public var chargerPlugged: Bool = false
    public var runtimeSeconds: Int = 0
    public var errorsBitmask: Int = 0
    public var errorMessages: [String] = []

    public init() {}
}

/// Nhãn lỗi của JK theo bit (ERROR_BIT_LABELS trong bản gốc).
public enum BMSErrorBit {
    public static let vietnamese: [Int: String] = [
        0: "Nội trở dây cân bằng lớn",
        1: "Quá nhiệt MOSFET",
        2: "Số cell thực tế lệch cài đặt",
        4: "Pin đã sạc đầy",
        5: "Quá áp tổng (Pack OVP)",
        6: "Quá dòng sạc",
        7: "Ngắn mạch sạc",
        8: "Quá nhiệt khi sạc",
        9: "Thấp nhiệt khi sạc",
        10: "Lỗi giao tiếp chip phụ",
        11: "Thấp áp Cell (Cell UVP)",
        12: "Thấp áp tổng (Pack UVP)",
        13: "Quá dòng xả",
        14: "Ngắn mạch xả",
        15: "Quá nhiệt khi xả",
        16: "Lỗi MOSFET sạc",
        17: "Lỗi MOSFET xả",
        18: "Mất kết nối GPS",
        19: "Cần đổi mật khẩu",
        20: "Mở mạch xả thất bại",
        21: "Quá nhiệt pin",
        22: "Lỗi cảm biến nhiệt độ",
        23: "Lỗi module giới hạn dòng",
    ]

    public static func label(for bit: Int) -> String {
        vietnamese[bit] ?? "Lỗi bit \(bit)"
    }
}
