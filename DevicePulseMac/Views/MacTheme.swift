//
//  MacTheme.swift
//  DevicePulseMac
//

import SwiftUI

extension MacSection {
    var tint: Color {
        switch self {
        case .dashboard: return .blue
        case .smartCare: return .cyan
        case .cpu: return .orange
        case .memory: return .purple
        case .ramOptimiser: return .indigo
        case .storage: return .teal
        case .network: return .cyan
        case .battery: return .green
        case .processes: return .brown
        case .startupOptimiser: return .red
        case .bigFiles: return .mint
        case .duplicates: return .cyan
        case .spaceMap: return .orange
        case .uninstaller: return .pink
        case .maintenance: return .yellow
        case .device: return .gray
        case .security: return .blue
        case .settings: return .gray
        }
    }
}

struct MacIconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 30

    @State private var appeared = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.32), .clear], startPoint: .top, endPoint: .center))
            )
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
            )
            .shadow(color: tint.opacity(0.35), radius: 4, y: 2)
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
                    appeared = true
                }
            }
    }
}

/// Interpolates an integer value smoothly across changes, since `Text` alone
/// doesn't animate its string content.
private struct MacAnimatedNumber: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(value.rounded()))")
    }
}

struct MacHealthRing: View {
    let score: Int?
    let tint: Color
    var size: CGFloat = 130

    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.15), lineWidth: 11)
            if let score {
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(100, score))) / 100)
                    .stroke(
                        AngularGradient(colors: [tint.opacity(0.55), tint], center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: 11, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(pulse ? 0.5 : 0.2), radius: pulse ? 8 : 3)
                    .animation(.spring(response: 0.7, dampingFraction: 0.8), value: score)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
            }
            VStack(spacing: 2) {
                if let score {
                    MacAnimatedNumber(value: Double(score))
                        .font(.system(size: size * 0.3, weight: .semibold))
                        .animation(.easeOut(duration: 0.8), value: score)
                } else {
                    Text("—").font(.system(size: size * 0.3, weight: .semibold))
                }
                Text(score == nil ? "not checked" : "health")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}
