// Motion.swift
// Các mảnh chuyển động dùng chung cho màn hình kết nối và màn hình dữ liệu.
// Mọi hiệu ứng đều tự tắt khi người dùng bật "Giảm chuyển động".

import SwiftUI

// MARK: - Nền

/// Nền tối "Industrial Dark" với hai quầng sáng xanh ở góc.
struct BMSBackdrop: View {
    var body: some View {
        ZStack {
            Color.bmsBg
            RadialGradient(colors: [Color.bmsGreen.opacity(0.10), .clear],
                           center: .topTrailing,
                           startRadius: 0,
                           endRadius: 460)
            RadialGradient(colors: [Color.bmsBlue.opacity(0.08), .clear],
                           center: .bottomLeading,
                           startRadius: 0,
                           endRadius: 460)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Chấm trạng thái

struct PulsingDot: View {
    let color: Color
    var animated = true

    @State private var pulse = false

    var body: some View {
        ZStack {
            if animated {
                Circle()
                    .stroke(color.opacity(0.55), lineWidth: 1)
                    .scaleEffect(pulse ? 2.4 : 1)
                    .opacity(pulse ? 0 : 1)
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .frame(width: 8, height: 8)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Quầng sáng nền card

/// Hai quầng sáng trôi chậm phía sau card header.
struct AmbientGlow: View {
    var leading: Color = .bmsGreen
    var trailing: Color = .bmsBlue
    var reduceMotion: Bool = false

    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(leading.opacity(0.42))
                    .frame(width: geo.size.width * 0.70)
                    .blur(radius: 70)
                    .offset(x: drift ? geo.size.width * 0.22 : -geo.size.width * 0.18,
                            y: -geo.size.height * 0.20)
                Circle()
                    .fill(trailing.opacity(0.34))
                    .frame(width: geo.size.width * 0.55)
                    .blur(radius: 80)
                    .offset(x: drift ? -geo.size.width * 0.20 : geo.size.width * 0.24,
                            y: geo.size.height * 0.30)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 9).repeatForever(autoreverses: true),
                       value: drift)
            .onAppear { drift = !reduceMotion }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Hiệu ứng vào

extension View {
    /// Fade + trượt nhẹ lên khi card xuất hiện, lệch nhịp theo `delay`.
    func reveal(_ visible: Bool, delay: Double, reduceMotion: Bool) -> some View {
        self
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 16)
            .animation(reduceMotion
                       ? nil
                       : .snappy(duration: 0.55, extraBounce: 0.06).delay(delay),
                       value: visible)
    }

    /// Card "bung" ra từ phía nút kết nối rồi xếp dần xuống dưới.
    /// `index` quyết định độ trễ để tạo nhịp so le giữa các card.
    func burstOut(_ visible: Bool, index: Int, reduceMotion: Bool) -> some View {
        let shown = visible || reduceMotion
        return self
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.88, anchor: .top)
            .offset(y: shown ? 0 : -36)
            .blur(radius: shown ? 0 : 8)
            .animation(reduceMotion
                       ? nil
                       : .spring(response: 0.55, dampingFraction: 0.82)
                           .delay(Double(index) * 0.06),
                       value: visible)
    }
}
