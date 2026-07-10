import AgentPetCompanionCore
import AppKit
import SwiftUI

enum APCSemanticColorToken: CaseIterable {
    case accent
    case accentSoft
    case cyanSoft
    case stroke
    case panel
    case textSecondary
    case success
    case warning
    case destructive
    case onAccent
}

enum APCDesign {
    static let accent = color(.accent)
    static let accentSoft = color(.accentSoft)
    static let cyanSoft = color(.cyanSoft)
    static let stroke = color(.stroke)
    static let panel = color(.panel)
    static let textSecondary = color(.textSecondary)
    static let success = color(.success)
    static let warning = color(.warning)
    static let destructive = color(.destructive)
    static let onAccent = color(.onAccent)

    static func color(_ token: APCSemanticColorToken) -> Color {
        Color(nsColor: nsColor(token))
    }

    static func resolvedColor(
        _ token: APCSemanticColorToken,
        appearance name: NSAppearance.Name
    ) -> NSColor? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            result = nsColor(token).usingColorSpace(.deviceRGB)
        }
        return result
    }

    private static func nsColor(_ token: APCSemanticColorToken) -> NSColor {
        switch token {
        case .accent:
            .controlAccentColor
        case .accentSoft:
            .selectedContentBackgroundColor.withAlphaComponent(0.18)
        case .cyanSoft:
            .unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.24)
        case .stroke:
            .separatorColor
        case .panel:
            .controlBackgroundColor
        case .textSecondary:
            .secondaryLabelColor
        case .success:
            .systemGreen
        case .warning:
            .systemOrange
        case .destructive:
            .systemRed
        case .onAccent:
            .selectedMenuItemTextColor
        }
    }
}

struct Surface<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
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
                            .stroke(APCDesign.stroke, lineWidth: colorSchemeContrast == .increased ? 2 : 1)
                    )
            )
    }
}

struct PageScroll<Content: View>: View {
    var horizontalPadding: CGFloat = 24
    var verticalPadding: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct AdaptiveTwoColumnLayout: Layout {
    var minimumColumnWidth: CGFloat
    var spacing: CGFloat

    static func usesColumns(
        availableWidth: CGFloat,
        minimumColumnWidth: CGFloat,
        spacing: CGFloat
    ) -> Bool {
        availableWidth >= minimumColumnWidth * 2 + spacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let availableWidth = max(0, proposal.width ?? 0)
        guard !subviews.isEmpty else { return CGSize(width: availableWidth, height: 0) }

        if Self.usesColumns(
            availableWidth: availableWidth,
            minimumColumnWidth: minimumColumnWidth,
            spacing: spacing
        ) {
            let columnWidth = max(0, (availableWidth - spacing) / 2)
            let sizes = subviews.map {
                $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            }
            return CGSize(
                width: availableWidth,
                height: sizes.map(\.height).max() ?? 0
            )
        }

        let sizes = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))
        }
        return CGSize(
            width: availableWidth,
            height: sizes.map(\.height).reduce(0, +)
                + spacing * CGFloat(max(0, subviews.count - 1))
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        if Self.usesColumns(
            availableWidth: bounds.width,
            minimumColumnWidth: minimumColumnWidth,
            spacing: spacing
        ) {
            let columnWidth = max(0, (bounds.width - spacing) / 2)
            for (index, subview) in subviews.enumerated() {
                subview.place(
                    at: CGPoint(
                        x: bounds.minX + CGFloat(index) * (columnWidth + spacing),
                        y: bounds.minY
                    ),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: columnWidth, height: nil)
                )
            }
            return
        }

        var y = bounds.minY
        for subview in subviews {
            let childProposal = ProposedViewSize(width: bounds.width, height: nil)
            let size = subview.sizeThatFits(childProposal)
            subview.place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: childProposal
            )
            y += size.height + spacing
        }
    }
}

struct PillButton: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    var title: String
    var selected: Bool
    var semanticLabel: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            pillLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel(semanticLabel ?? title)
        .accessibilityValue(UIControlSemantics.selectionValue(isSelected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var pillLabel: some View {
        HStack(spacing: 6) {
            if selected {
                Image(systemName: "checkmark")
                    .accessibilityHidden(true)
            }
            Text(title)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(pillBackground)
    }

    private var pillBackground: some View {
        Capsule()
            .fill(selected ? APCDesign.accentSoft : Color(nsColor: .controlBackgroundColor))
            .overlay(
                Capsule().stroke(
                    selected ? APCDesign.accent : APCDesign.stroke,
                    lineWidth: colorSchemeContrast == .increased ? 2 : 1
                )
            )
    }
}

struct PrimaryActionButton: View {
    @Environment(\.isEnabled) private var isEnabled
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
            .foregroundStyle(isEnabled ? APCDesign.onAccent : Color(nsColor: .secondaryLabelColor))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isEnabled ? APCDesign.accent : Color(nsColor: .quaternaryLabelColor).opacity(0.55))
                    .shadow(color: isEnabled ? APCDesign.accent.opacity(0.25) : .clear, radius: 12, y: 6)
            )
        }
        .buttonStyle(.plain)
    }
}

struct SecondaryActionButton: View {
    @Environment(\.isEnabled) private var isEnabled
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
            .foregroundStyle(isEnabled ? .primary : .secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(isEnabled ? 1 : 0.55))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(APCDesign.stroke))
            )
        }
        .buttonStyle(.plain)
    }
}

struct StatusBadge: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    var title: String
    var tone: Tone

    enum Tone {
        case good
        case warning
        case neutral
        case accent
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.bold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(background)
                    .overlay(
                        Capsule().stroke(
                            toneColor.opacity(colorSchemeContrast == .increased ? 0.85 : 0.42),
                            lineWidth: colorSchemeContrast == .increased ? 2 : 1
                        )
                    )
            )
            .accessibilityElement(children: .combine)
    }

    private var background: Color {
        switch tone {
        case .good: APCDesign.success.opacity(0.18)
        case .warning: APCDesign.warning.opacity(0.20)
        case .neutral: Color(nsColor: .quaternaryLabelColor).opacity(0.16)
        case .accent: APCDesign.accentSoft
        }
    }

    private var toneColor: Color {
        switch tone {
        case .good: APCDesign.success
        case .warning: APCDesign.warning
        case .neutral: APCDesign.textSecondary
        case .accent: APCDesign.accent
        }
    }

    private var systemImage: String {
        switch tone {
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .neutral: "circle"
        case .accent: "checkmark.circle"
        }
    }
}
