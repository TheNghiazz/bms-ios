// Theme.swift
// Màu sắc lấy đúng bảng "Industrial Dark" của GUI gốc (Tkinter).

import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }

    static let bmsBg = Color(hex: 0x0b1120)
    static let bmsHeader = Color(hex: 0x0f172a)
    static let bmsCard = Color(hex: 0x1e293b)
    static let bmsCardAlt = Color(hex: 0x0d1527)
    static let bmsBorder = Color(hex: 0x334155)
    static let bmsGreen = Color(hex: 0x10b981)
    static let bmsBlue = Color(hex: 0x38bdf8)
    static let bmsAmber = Color(hex: 0xf59e0b)
    static let bmsRose = Color(hex: 0xf43f5e)
    static let bmsText = Color(hex: 0xf8fafc)
    static let bmsMuted = Color(hex: 0x94a3b8)
}
