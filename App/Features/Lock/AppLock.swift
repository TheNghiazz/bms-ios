// AppLock.swift
// Khoá app bằng mật khẩu. Lần đầu dùng, mật khẩu mặc định là "ngia";
// người dùng có thể đổi trong menu ⋯ → Đổi mật khẩu.
//
// Chỉ lưu SHA-256(salt + mật khẩu) trong UserDefaults, KHÔNG lưu mật khẩu gốc.
// Không dùng Keychain vì bản cài bằng Apple ID free phải re-sign mỗi 7 ngày;
// khi đổi team, keychain item có thể mất quyền truy cập và khoá user ra ngoài.
// (Đây là lớp chặn truy cập, không mã hoá dữ liệu BMS.)

import Combine
import CryptoKit
import Foundation

@MainActor
final class AppLock: ObservableObject {

    /// Mật khẩu mặc định cho lần nhập đầu tiên.
    static let defaultPassword = "ngia"

    /// Số lần nhập sai liên tiếp trước khi tạm khoá.
    static let maxAttempts = 5

    /// Thời gian tạm khoá sau khi sai quá `maxAttempts` (giây).
    static let lockoutSeconds = 30

    /// Đang khoá (mặc định khoá ngay khi mở app).
    @Published private(set) var isLocked = true

    /// true khi chưa từng đổi mật khẩu → còn dùng "ngia".
    @Published private(set) var isUsingDefaultPassword: Bool

    /// Số giây còn phải chờ trước khi được nhập lại (0 = không bị tạm khoá).
    @Published private(set) var lockoutSecondsRemaining = 0

    private(set) var failedAttempts: Int

    private enum Keys {
        static let hash = "bms.lock.hash"
        static let salt = "bms.lock.salt"
        static let failedAttempts = "bms.lock.failedAttempts"
        static let lockedUntil = "bms.lock.lockedUntil"
    }

    private let defaults: UserDefaults
    private var lockedUntil: Date?
    private var lockoutTimer: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isUsingDefaultPassword = defaults.string(forKey: Keys.hash) == nil
        failedAttempts = defaults.integer(forKey: Keys.failedAttempts)

        // Khôi phục trạng thái tạm khoá nếu app bị kill giữa lúc đếm ngược.
        if let until = defaults.object(forKey: Keys.lockedUntil) as? Date,
           until > Date() {
            lockedUntil = until
            lockoutSecondsRemaining = Self.secondsRemaining(until: until)
            startLockoutTimer()
        } else if defaults.object(forKey: Keys.lockedUntil) != nil {
            defaults.removeObject(forKey: Keys.lockedUntil)
        }
    }

    // ------------------------------------------------------------ mở khoá
    enum UnlockOutcome: Equatable {
        case success
        case wrongPassword(attemptsLeft: Int)
        case lockedOut(secondsLeft: Int)
    }

    func attemptUnlock(_ password: String) -> UnlockOutcome {
        if let until = lockedUntil, until > Date() {
            return .lockedOut(secondsLeft: Self.secondsRemaining(until: until))
        }
        guard isCorrect(password) else {
            failedAttempts += 1
            defaults.set(failedAttempts, forKey: Keys.failedAttempts)
            if failedAttempts >= Self.maxAttempts {
                startLockout()
                return .lockedOut(secondsLeft: Self.lockoutSeconds)
            }
            return .wrongPassword(attemptsLeft: Self.maxAttempts - failedAttempts)
        }
        isLocked = false
        resetFailures()
        return .success
    }

    func lock() { isLocked = true }

    func isCorrect(_ password: String) -> Bool {
        guard !password.isEmpty else { return false }
        guard let storedHash = defaults.string(forKey: Keys.hash),
              let salt = defaults.string(forKey: Keys.salt) else {
            return password == Self.defaultPassword
        }
        return Self.hash(password, salt: salt) == storedHash
    }

    // ------------------------------------------------------------ tạm khoá
    private func startLockout() {
        let until = Date().addingTimeInterval(TimeInterval(Self.lockoutSeconds))
        lockedUntil = until
        lockoutSecondsRemaining = Self.lockoutSeconds
        failedAttempts = 0
        defaults.set(until, forKey: Keys.lockedUntil)
        defaults.set(0, forKey: Keys.failedAttempts)
        startLockoutTimer()
    }

    private func startLockoutTimer() {
        lockoutTimer?.cancel()
        lockoutTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in self?.tickLockout() }
            }
    }

    private func tickLockout() {
        guard let until = lockedUntil else {
            lockoutTimer?.cancel()
            lockoutTimer = nil
            lockoutSecondsRemaining = 0
            return
        }
        let remaining = Self.secondsRemaining(until: until)
        if remaining > 0 {
            lockoutSecondsRemaining = remaining
            return
        }
        // Hết thời gian chờ: mở lại lượt thử.
        lockoutTimer?.cancel()
        lockoutTimer = nil
        lockedUntil = nil
        lockoutSecondsRemaining = 0
        failedAttempts = 0
        defaults.removeObject(forKey: Keys.lockedUntil)
        defaults.set(0, forKey: Keys.failedAttempts)
    }

    private func resetFailures() {
        lockoutTimer?.cancel()
        lockoutTimer = nil
        lockedUntil = nil
        lockoutSecondsRemaining = 0
        failedAttempts = 0
        defaults.removeObject(forKey: Keys.lockedUntil)
        defaults.set(0, forKey: Keys.failedAttempts)
    }

    private static func secondsRemaining(until date: Date) -> Int {
        max(0, Int(ceil(date.timeIntervalSinceNow)))
    }

    // ---------------------------------------------------------- đổi mật khẩu
    enum ChangeResult: Equatable {
        case success
        case wrongCurrent
        case tooShort
        case mismatch

        var message: String {
            switch self {
            case .success:      return "Đã đổi mật khẩu."
            case .wrongCurrent: return "Mật khẩu hiện tại không đúng."
            case .tooShort:     return "Mật khẩu mới cần ít nhất 4 ký tự."
            case .mismatch:     return "Xác nhận mật khẩu không khớp."
            }
        }
    }

    @discardableResult
    func changePassword(current: String, new: String, confirm: String) -> ChangeResult {
        guard isCorrect(current) else { return .wrongCurrent }
        guard new.count >= 4 else { return .tooShort }
        guard new == confirm else { return .mismatch }

        let salt = Self.randomSalt()
        defaults.set(salt, forKey: Keys.salt)
        defaults.set(Self.hash(new, salt: salt), forKey: Keys.hash)
        isUsingDefaultPassword = false
        return .success
    }

    // ---------------------------------------------------------------- hash
    private static func hash(_ password: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + password).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomSalt() -> String {
        UUID().uuidString + "-" + UUID().uuidString
    }
}
