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

enum APCApplicationAppearance {
    static func colorScheme(for theme: AppearanceTheme) -> ColorScheme? {
        switch theme {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }

    static func appearanceName(for theme: AppearanceTheme) -> NSAppearance.Name? {
        switch theme {
        case .system: nil
        case .dark: .darkAqua
        case .light: .aqua
        }
    }

    static func nsAppearance(for theme: AppearanceTheme) -> NSAppearance? {
        appearanceName(for: theme).flatMap(NSAppearance.init(named:))
    }

    @MainActor
    static func apply(_ theme: AppearanceTheme) {
        // Keep AppKit chrome, menu bar menus, detached NSPanels, and SwiftUI's
        // inherited system colors on the same appearance. Setting nil restores
        // live system following instead of snapshotting the current scheme.
        NSApplication.shared.appearance = nsAppearance(for: theme)
    }
}

extension View {
    func apcAppearanceTheme(_ theme: AppearanceTheme) -> some View {
        preferredColorScheme(APCApplicationAppearance.colorScheme(for: theme))
    }
}

struct Surface<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    private var increasedContrast: Bool {
        colorSchemeContrast == .increased
    }

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        APCDesign.stroke.opacity(increasedContrast ? 1 : 0.72),
                        lineWidth: increasedContrast ? 2 : 1
                    )
                    .allowsHitTesting(false)
            }
    }
}

/// Groups nearby glass surfaces so macOS can render them as one native optical layer.
/// On macOS 14–15 the same hierarchy falls back to native regular material.
struct APCGlassGroup<Content: View>: View {
    var spacing: CGFloat = 18
    @ViewBuilder var content: Content

    @ViewBuilder
    var body: some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
#else
        content
#endif
    }
}

private struct APCLiquidGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let shape: S
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(APCDesign.panel, in: shape)
                .overlay {
                    accessibilityBorder(opacity: 0.72, lineWidth: 1)
                }
        } else {
            glass(content)
                .overlay {
                    if colorSchemeContrast == .increased {
                        accessibilityBorder(opacity: 0.58, lineWidth: 1.5)
                    }
                }
        }
    }

    @ViewBuilder
    private func glass(_ content: Content) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: shape
            )
        } else {
            content.background(.regularMaterial, in: shape)
        }
#else
        content.background(.regularMaterial, in: shape)
#endif
    }

    private func accessibilityBorder(
        opacity: Double,
        lineWidth: CGFloat
    ) -> some View {
        shape
            .stroke(Color.primary.opacity(opacity), lineWidth: lineWidth)
            .allowsHitTesting(false)
    }
}

enum APCBubbleGlassStyle {
    /// Regular Liquid Glass is the default functional surface on macOS 26.
    /// Keep the normal path free of supplemental fills, borders, and tint. The
    /// native optical background is attenuated independently; the foreground
    /// is never post-composited with reduced opacity.
    static let backdropOpacity = 0.0
    static let borderOpacity = 0.0
    /// User-facing transparency is the inverse of the native optical layer's
    /// strength. Even the clearest endpoint keeps enough of the system lens to
    /// preserve refraction and an identifiable glass boundary.
    static let minimumOpticalOpacity = 0.30
    static let maximumOpticalOpacity = 0.88
    static let legacyBackdropOpacity = 0.18
    static let legacyBorderOpacity = 0.18
    static let increasedContrastBackdropOpacity = 0.42
    static let increasedContrastBorderOpacity = 0.52
    static let reducedTransparencyBackdropOpacity = 1.0
    static let reducedTransparencyBorderOpacity = 0.62

    static func opticalOpacity(for transparency: Double) -> Double {
        let clamped = BehaviorSettings.clampedBubbleTransparency(transparency)
        return maximumOpticalOpacity
            - ((maximumOpticalOpacity - minimumOpticalOpacity) * clamped)
    }

    static func resolvedLegacyBackdropOpacity(for transparency: Double) -> Double {
        let clamped = BehaviorSettings.clampedBubbleTransparency(transparency)
        return 0.34 - (0.24 * clamped)
    }

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

    static func resolvedBorderOpacity(
        reduceTransparency: Bool,
        increasedContrast: Bool,
        supportsLiquidGlass: Bool
    ) -> Double {
        if reduceTransparency {
            return reducedTransparencyBorderOpacity
        }
        if increasedContrast {
            return increasedContrastBorderOpacity
        }
        return supportsLiquidGlass ? borderOpacity : legacyBorderOpacity
    }
}

enum APCBubbleForegroundStyle {
    /// Foreground content is never attenuated to make the surface look clear.
    /// Transparency belongs to the glass surface, not to labels or icons. Keep
    /// the foreground free of blur and light/dark halos so glyph and control
    /// edges remain native and pixel-sharp.
    static let contentOpacity = 1.0
    static let secondaryContentOpacity = 1.0
    static let usesBlur = false
    static let usesHalo = false
}

/// Owns the one AppKit capability gap in the bubble implementation. In a
/// transparent `NSPanel`, embedding `NSHostingView` as
/// `NSGlassEffectView.contentView` can leave only the optical layer visible.
/// Keep native regular glass and the SwiftUI foreground as ordered siblings so
/// the glass never obscures labels or controls.
#if compiler(>=6.2)
@available(macOS 26.0, *)
private final class APCBubbleBackgroundGlassView: NSGlassEffectView {
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

@available(macOS 26.0, *)
@MainActor
final class APCNativeBubbleGlassView: NSView {
    let glassView: NSGlassEffectView = APCBubbleBackgroundGlassView()
    let foregroundView: NSView

    init(foregroundView: NSView, cornerRadius: CGFloat, transparency: Double) {
        self.foregroundView = foregroundView
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        glassView.translatesAutoresizingMaskIntoConstraints = false
        foregroundView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glassView)
        addSubview(foregroundView)
        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
            foregroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            foregroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            foregroundView.topAnchor.constraint(equalTo: topAnchor),
            foregroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        APCNativeBubbleGlassConfiguration.configureAppearance(
            glassView,
            cornerRadius: cornerRadius,
            transparency: transparency
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        foregroundView.hitTest(convert(point, to: foregroundView))
    }
}

@available(macOS 26.0, *)
@MainActor
enum APCNativeBubbleGlassConfiguration {
    static func makeHostingView<Content: View>(
        rootView: Content
    ) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: rootView)
        // Preserve an intrinsic fallback for unspecified SwiftUI proposals,
        // but do not install NSHostingView's near-required max-width/height
        // constraints. Those constraints can shrink the private glass content
        // holder and make the far edge of a full-width bubble non-interactive.
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        return hostingView
    }

    static func makeView(
        contentView: NSView,
        cornerRadius: CGFloat,
        transparency: Double = BehaviorSettings.defaultBubbleTransparency
    ) -> APCNativeBubbleGlassView {
        APCNativeBubbleGlassView(
            foregroundView: contentView,
            cornerRadius: cornerRadius,
            transparency: transparency
        )
    }

    static func configureAppearance(
        _ glassView: NSGlassEffectView,
        cornerRadius: CGFloat,
        transparency: Double
    ) {
        glassView.style = .regular
        glassView.tintColor = nil
        glassView.cornerRadius = cornerRadius
        glassView.alphaValue = APCBubbleGlassStyle.opticalOpacity(for: transparency)
    }

    static func resolvedSize(
        proposal: ProposedViewSize,
        fittingSize: CGSize
    ) -> CGSize {
        CGSize(
            width: proposal.width ?? fittingSize.width,
            height: proposal.height ?? fittingSize.height
        )
    }
}

@available(macOS 26.0, *)
private struct APCNativeBubbleGlassHost<Content: View>: NSViewRepresentable {
    let cornerRadius: CGFloat
    let transparency: Double
    let content: Content

    func makeNSView(context: Context) -> APCNativeBubbleGlassView {
        let hostingView = APCNativeBubbleGlassConfiguration.makeHostingView(
            rootView: content
        )
        return APCNativeBubbleGlassConfiguration.makeView(
            contentView: hostingView,
            cornerRadius: cornerRadius,
            transparency: transparency
        )
    }

    func updateNSView(_ surfaceView: APCNativeBubbleGlassView, context: Context) {
        guard let hostingView = surfaceView.foregroundView as? NSHostingView<Content> else { return }

        hostingView.rootView = content
        APCNativeBubbleGlassConfiguration.configureAppearance(
            surfaceView.glassView,
            cornerRadius: cornerRadius,
            transparency: transparency
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: APCNativeBubbleGlassView,
        context: Context
    ) -> CGSize? {
        APCNativeBubbleGlassConfiguration.resolvedSize(
            proposal: proposal,
            fittingSize: nsView.foregroundView.fittingSize
        )
    }
}
#endif

/// `BubbleOverlayRootView` deliberately does not use a
/// `GlassEffectContainer`: that container elevates descendant glass layers and
/// can place the optical layer above foreground content in a transparent
/// `NSPanel`.
private struct APCTransparentBubbleGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let cornerRadius: CGFloat
    let transparency: Double

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var backdropColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var reduceTransparency: Bool {
        systemReduceTransparency
    }

    private var increasedContrast: Bool {
        colorSchemeContrast == .increased
    }

    private var backdropOpacity: Double {
        APCBubbleGlassStyle.resolvedBackdropOpacity(
            reduceTransparency: reduceTransparency,
            increasedContrast: increasedContrast
        )
    }

    @ViewBuilder
    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if reduceTransparency {
                accessibilityFallback(content, supportsLiquidGlass: true)
            } else {
                APCNativeBubbleGlassHost(
                    cornerRadius: cornerRadius,
                    transparency: transparency,
                    content: content
                    .background {
                        if increasedContrast {
                            shape.fill(backdropColor.opacity(backdropOpacity))
                        }
                    }
                    .overlay {
                        if increasedContrast {
                            bubbleBorder(supportsLiquidGlass: true)
                        }
                    }
                )
            }
        } else {
            legacyFallback(content)
        }
#else
        legacyFallback(content)
#endif
    }

    private func accessibilityFallback(
        _ content: Content,
        supportsLiquidGlass: Bool
    ) -> some View {
        return content
            .background(backdropColor.opacity(backdropOpacity), in: shape)
            .overlay {
                bubbleBorder(supportsLiquidGlass: supportsLiquidGlass)
            }
    }

    private func legacyFallback(_ content: Content) -> some View {
        let supplementalOpacity = if reduceTransparency || increasedContrast {
            backdropOpacity
        } else {
            APCBubbleGlassStyle.resolvedLegacyBackdropOpacity(for: transparency)
        }

        return content
            .background {
                ZStack {
                    shape.fill(.regularMaterial)
                    shape.fill(backdropColor.opacity(supplementalOpacity))
                }
            }
            .overlay {
                bubbleBorder(supportsLiquidGlass: false)
            }
    }

    private func bubbleBorder(supportsLiquidGlass: Bool) -> some View {
        shape
            .stroke(
                .primary.opacity(
                    APCBubbleGlassStyle.resolvedBorderOpacity(
                        reduceTransparency: reduceTransparency,
                        increasedContrast: increasedContrast,
                        supportsLiquidGlass: supportsLiquidGlass
                    )
                ),
                lineWidth: 0.7
            )
            .allowsHitTesting(false)
    }
}

extension View {
    func apcFloatingControlGlass<S: Shape>(
        in shape: S,
        interactive: Bool = false
    ) -> some View {
        modifier(APCLiquidGlassModifier(shape: shape, interactive: interactive))
    }

    func apcTransparentBubbleGlass(cornerRadius: CGFloat, transparency: Double) -> some View {
        modifier(APCTransparentBubbleGlassModifier(
            cornerRadius: cornerRadius,
            transparency: transparency
        ))
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
        .background(
            Capsule()
                .fill(
                    selected
                        ? APCDesign.accentSoft
                        : Color(nsColor: .controlBackgroundColor)
                )
        )
        .overlay {
            Capsule()
                .stroke(
                    selected ? APCDesign.accent.opacity(0.72) : APCDesign.stroke,
                    lineWidth: 1
                )
                .allowsHitTesting(false)
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
        .controlSize(.regular)
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
        .controlSize(.regular)
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
            .background(Capsule().fill(toneColor.opacity(0.10)))
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
