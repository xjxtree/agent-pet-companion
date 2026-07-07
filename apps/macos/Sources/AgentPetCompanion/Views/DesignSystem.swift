import AgentPetCompanionCore
import SwiftUI

enum APCDesign {
    static let accent = Color(red: 0.49, green: 0.31, blue: 0.96)
    static let accentSoft = Color(red: 0.92, green: 0.88, blue: 1.0)
    static let cyanSoft = Color(red: 0.80, green: 0.94, blue: 1.0)
    static let stroke = Color.black.opacity(0.10)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
}

struct Surface<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(APCDesign.stroke)
                    )
            )
    }
}

struct PillButton: View {
    var title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(selected ? APCDesign.accent : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(selected ? APCDesign.accentSoft : Color(nsColor: .controlBackgroundColor))
                        .overlay(Capsule().stroke(selected ? APCDesign.accent.opacity(0.45) : APCDesign.stroke))
                )
        }
        .buttonStyle(.plain)
    }
}

struct PrimaryActionButton: View {
    var title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.callout.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(APCDesign.accent)
                    .shadow(color: APCDesign.accent.opacity(0.25), radius: 12, y: 6)
            )
        }
        .buttonStyle(.plain)
    }
}

struct SecondaryActionButton: View {
    var title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(APCDesign.stroke))
            )
        }
        .buttonStyle(.plain)
    }
}

struct StatusBadge: View {
    var title: String
    var tone: Tone

    enum Tone {
        case good
        case warning
        case neutral
        case accent
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(background))
    }

    private var foreground: Color {
        switch tone {
        case .good: Color(red: 0.05, green: 0.48, blue: 0.20)
        case .warning: Color(red: 0.62, green: 0.34, blue: 0.02)
        case .neutral: .secondary
        case .accent: APCDesign.accent
        }
    }

    private var background: Color {
        switch tone {
        case .good: Color(red: 0.86, green: 0.97, blue: 0.89)
        case .warning: Color(red: 1.0, green: 0.91, blue: 0.76)
        case .neutral: Color(nsColor: .quaternaryLabelColor).opacity(0.16)
        case .accent: APCDesign.accentSoft
        }
    }
}

struct SamplePetIllustration: View {
    var state: AgentEventKind? = nil
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.10))
                .frame(width: 128 * scale, height: 22 * scale)
                .offset(y: 88 * scale)
            Circle()
                .fill(Color(red: 0.21, green: 0.20, blue: 0.58))
                .frame(width: 118 * scale, height: 118 * scale)
                .offset(y: -22 * scale)
            Circle()
                .fill(Color(red: 1.0, green: 0.84, blue: 0.72))
                .frame(width: 72 * scale, height: 72 * scale)
                .offset(y: -28 * scale)
            VStack(spacing: 0) {
                Spacer()
                Trapezoid()
                    .fill(Color(red: 0.94, green: 0.90, blue: 1.0))
                    .frame(width: 150 * scale, height: 112 * scale)
                    .overlay(
                        Trapezoid()
                            .fill(stateColor.opacity(0.86))
                            .frame(width: 112 * scale, height: 34 * scale)
                            .offset(y: -10 * scale)
                    )
            }
            .frame(width: 170 * scale, height: 210 * scale)
            Circle()
                .fill(Color.primary)
                .frame(width: 8 * scale, height: 8 * scale)
                .offset(x: -18 * scale, y: -28 * scale)
            Circle()
                .fill(Color.primary)
                .frame(width: 8 * scale, height: 8 * scale)
                .offset(x: 18 * scale, y: -28 * scale)
            Smile()
                .stroke(Color(red: 0.83, green: 0.29, blue: 0.37), lineWidth: 3 * scale)
                .frame(width: 34 * scale, height: 18 * scale)
                .offset(y: -10 * scale)
        }
        .frame(width: 210 * scale, height: 250 * scale)
    }

    private var stateColor: Color {
        switch state {
        case .start: APCDesign.accent
        case .tool: Color(red: 0.20, green: 0.68, blue: 0.86)
        case .waiting: Color(red: 0.95, green: 0.66, blue: 0.20)
        case .review: Color(red: 0.43, green: 0.46, blue: 1.0)
        case .done: Color(red: 0.24, green: 0.72, blue: 0.43)
        case .failed: Color(red: 0.91, green: 0.30, blue: 0.38)
        case .none: Color(red: 0.35, green: 0.66, blue: 0.91)
        }
    }
}

struct Trapezoid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.24, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.24, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct Smile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
