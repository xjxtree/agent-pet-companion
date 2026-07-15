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
            .apcLiquidGlass(
                in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                interactive: false
            )
            .overlay {
                if colorSchemeContrast == .increased {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(APCDesign.stroke, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Groups nearby glass surfaces so macOS can render them as one native optical layer.
/// On macOS 14–15 the same hierarchy falls back to native ultra-thin material.
struct APCGlassGroup<Content: View>: View {
    var spacing: CGFloat = 18
    @ViewBuilder var content: Content

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

private struct APCLiquidGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                interactive ? .clear.interactive() : .clear,
                in: shape
            )
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

enum APCBubbleGlassStyle {
    static let opticalOpacity = 0.28
    static let backdropOpacity = 0.18
    static let increasedContrastBackdropOpacity = 0.36
    static let reducedTransparencyBackdropOpacity = 0.86
    static let borderOpacity = 0.22

    static func resolvedBackdropOpacity(
        reduceTransparency: Bool,
        increasedContrast: Bool
    ) -> Double {
        if reduceTransparency {
            return reducedTransparencyBackdropOpacity
        }
        if increasedContrast {
            return increasedContrastBackdropOpacity
        }
        return backdropOpacity
    }
}

/// A bubble-specific surface that keeps the native Clear Liquid Glass edge and
/// refraction while allowing the desktop content behind the panel to remain
/// recognizable. Text is intentionally outside the attenuated optical layer.
private struct APCTransparentBubbleGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let shape: S
    let interactive: Bool

    private var backdropColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var backdropOpacity: Double {
        APCBubbleGlassStyle.resolvedBackdropOpacity(
            reduceTransparency: reduceTransparency,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(backdropColor.opacity(backdropOpacity))

                    if !reduceTransparency {
                        if #available(macOS 26.0, *) {
                            Color.clear
                                .glassEffect(
                                    interactive ? .clear.interactive() : .clear,
                                    in: shape
                                )
                                .opacity(APCBubbleGlassStyle.opticalOpacity)
                        }
                    }
                }
            }
            .overlay {
                shape
                    .stroke(.primary.opacity(APCBubbleGlassStyle.borderOpacity), lineWidth: 0.6)
                    .allowsHitTesting(false)
            }
    }
}

private struct APCBubbleTextContrastModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.shadow(
            color: colorScheme == .dark
                ? .black.opacity(0.72)
                : .white.opacity(0.82),
            radius: 1.1,
            y: 0.4
        )
    }
}

extension View {
    func apcLiquidGlass<S: Shape>(
        in shape: S,
        interactive: Bool = false
    ) -> some View {
        modifier(APCLiquidGlassModifier(shape: shape, interactive: interactive))
    }

    func apcTransparentBubbleGlass<S: Shape>(
        in shape: S,
        interactive: Bool = false
    ) -> some View {
        modifier(APCTransparentBubbleGlassModifier(shape: shape, interactive: interactive))
    }

    func apcBubbleTextContrast() -> some View {
        modifier(APCBubbleTextContrastModifier())
    }
}

struct PageScroll<Content: View>: View {
    var horizontalPadding: CGFloat = 24
    var verticalPadding: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical) {
            APCGlassGroup(spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
            }
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
        .foregroundStyle(selected ? APCDesign.accent : .primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .apcLiquidGlass(in: Capsule(), interactive: true)
        .overlay {
            if selected {
                Capsule()
                    .stroke(APCDesign.accent.opacity(0.72), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct PrimaryActionButton: View {
    var title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            buttonLabel
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    @ViewBuilder
    private var buttonLabel: some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
        } else {
            Text(title)
                .font(.callout.weight(.semibold))
        }
    }
}

struct SecondaryActionButton: View {
    var title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            buttonLabel
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    @ViewBuilder
    private var buttonLabel: some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
        } else {
            Text(title)
                .font(.callout.weight(.semibold))
        }
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
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.bold))
            .foregroundStyle(toneColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .apcLiquidGlass(in: Capsule())
            .overlay {
                Capsule()
                    .stroke(toneColor.opacity(0.36), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .combine)
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
