// LockScreen.swift
// Màn hình mở khoá + sheet đổi mật khẩu. Cùng bảng màu "Industrial Dark"
// với dashboard để app trông liền mạch.

import SwiftUI

struct LockScreen: View {
    @ObservedObject var lock: AppLock

    @State private var password = ""
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    private let fieldWidth: CGFloat = 320

    var body: some View {
        ZStack {
            Color.bmsBg.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(Color.bmsGreen)
                    .padding(.bottom, 2)

                VStack(spacing: 4) {
                    Text("BMS Monitor")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.bmsText)
                    Text("Nhập mật khẩu để mở khoá")
                        .font(.footnote)
                        .foregroundStyle(Color.bmsMuted)
                }

                SecureField("Mật khẩu", text: $password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($fieldFocused)
                    .onSubmit(attemptUnlock)
                    .disabled(isLockedOut)
                    .padding(12)
                    .background(Color.bmsCard)
                    .foregroundStyle(Color.bmsText)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(error == nil ? Color.bmsBorder : Color.bmsRose,
                                    lineWidth: 1)
                    )
                    .frame(maxWidth: fieldWidth)

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.bmsRose)
                }

                Button(action: attemptUnlock) {
                    Text(isLockedOut ? "Chờ \(lock.lockoutSecondsRemaining)s" : "Mở khoá")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: fieldWidth)
                        .padding(.vertical, 12)
                        .background(isLockedOut ? Color.bmsCard : Color.bmsGreen)
                        .foregroundStyle(isLockedOut ? Color.bmsMuted : Color.bmsBg)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(password.isEmpty || isLockedOut)
                .opacity(password.isEmpty && !isLockedOut ? 0.45 : 1)

                if lock.isUsingDefaultPassword {
                    Text("Mật khẩu mặc định: \(AppLock.defaultPassword)")
                        .font(.caption2)
                        .foregroundStyle(Color.bmsMuted)
                        .padding(.top, 4)
                }
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if isLockedOut {
                error = "Sai quá \(AppLock.maxAttempts) lần. Thử lại sau \(lock.lockoutSecondsRemaining)s."
            }
            fieldFocused = !isLockedOut
        }
        .onChange(of: password) { _, _ in
            if !isLockedOut, !password.isEmpty { error = nil }
        }
        .onChange(of: lock.lockoutSecondsRemaining) { _, seconds in
            if seconds > 0 {
                error = "Sai quá \(AppLock.maxAttempts) lần. Thử lại sau \(seconds)s."
            } else {
                error = nil
                fieldFocused = true
            }
        }
    }

    private var isLockedOut: Bool { lock.lockoutSecondsRemaining > 0 }

    private func attemptUnlock() {
        guard !password.isEmpty, !isLockedOut else { return }
        switch lock.attemptUnlock(password) {
        case .success:
            password = ""
            error = nil
        case .wrongPassword(let attemptsLeft):
            error = "Mật khẩu không đúng. Còn \(attemptsLeft) lần thử."
            password = ""
            fieldFocused = true
        case .lockedOut(let secondsLeft):
            error = "Sai quá \(AppLock.maxAttempts) lần. Thử lại sau \(secondsLeft)s."
            password = ""
            fieldFocused = false
        }
    }
}

struct PasswordSettingsView: View {
    @ObservedObject var lock: AppLock
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var message: String?
    @State private var isError = false
    @State private var didSave = false

    private var canSave: Bool {
        !current.isEmpty && !new.isEmpty && !confirm.isEmpty
    }

    var body: some View {
        Form {
            Section {
                Text(lock.isUsingDefaultPassword
                     ? "Đang dùng mật khẩu mặc định: \(AppLock.defaultPassword)"
                     : "Đã đặt mật khẩu riêng.")
                    .font(.footnote)
                    .foregroundStyle(Color.bmsMuted)
            }

            Section("Mật khẩu") {
                SecureField("Mật khẩu hiện tại", text: $current)
                    .textContentType(.password)
                SecureField("Mật khẩu mới (≥ 4 ký tự)", text: $new)
                    .textContentType(.newPassword)
                SecureField("Nhập lại mật khẩu mới", text: $confirm)
                    .textContentType(.newPassword)
            }
            .disabled(didSave)

            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(isError ? Color.bmsRose : Color.bmsGreen)
                }
            }

            Section {
                if didSave {
                    Button("Xong") { dismiss() }
                } else {
                    Button("Lưu mật khẩu", action: save)
                        .disabled(!canSave)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.bmsBg.ignoresSafeArea())
        .foregroundStyle(Color.bmsText)
        .tint(Color.bmsGreen)
        .preferredColorScheme(.dark)
        .navigationTitle("Đổi mật khẩu")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Đóng") { dismiss() }
                    .foregroundStyle(Color.bmsMuted)
            }
        }
        .onChange(of: current) { _, _ in clearMessage() }
        .onChange(of: new) { _, _ in clearMessage() }
        .onChange(of: confirm) { _, _ in clearMessage() }
    }

    private func clearMessage() {
        guard !didSave else { return }
        message = nil
        isError = false
    }

    private func save() {
        let result = lock.changePassword(current: current, new: new, confirm: confirm)
        isError = result != .success
        message = result.message
        didSave = result == .success
    }
}
