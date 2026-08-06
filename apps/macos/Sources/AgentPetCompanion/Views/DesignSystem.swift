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

/// Selects which native Liquid Glass variant a surface asks for. `regular` is
/// the adaptive system lens: it keeps the frost, edge refraction, and specular
/// highlight that identify a glass boundary over an arbitrary desktop backdrop.
/// `clear` is the media-backdrop variant and deliberately drops most of that
/// optical treatment, so it is only appropriate where the surface sits on
/// content the user is meant to read straight through.
enum APCGlassVariant {
    case regular
    case clear
}

private struct APCLiquidGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let shape: S
    let variant: APCGlassVariant
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
            content.glassEffect(nativeGlass, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
#else
        content.background(.regularMaterial, in: shape)
#endif
    }

#if compiler(>=6.2)
    @available(macOS 26.0, *)
    private var nativeGlass: Glass {
        let base: Glass = switch variant {
        case .regular: .regular
        case .clear: .clear
        }
        return interactive ? base.interactive() : base
    }
#endif

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
    /// Public Liquid Glass owns the actual backdrop sampling and refraction.
    /// This very thin, inset rim only makes that optical boundary readable on
    /// a busy desktop: a restrained highlight faces the notional light source
    /// while the opposite edge receives a smaller depth cue. It adds no fill,
    /// blur, shadow, or second glass layer.
    static let opticalRimWidth: CGFloat = 0.8
    static let opticalRimHighlightOpacity = 0.30
    static let opticalRimMidpointOpacity = 0.055
    static let opticalRimDepthOpacity = 0.14

    /// The normal path carries no supplemental fill or structural border over
    /// the native surface. Its optical rim is a sub-point directional stroke,
    /// not another material. The foreground is never post-composited with
    /// reduced opacity: transparency belongs to the glass, not to labels and
    /// controls.
    static let backdropOpacity = 0.0
    static let borderOpacity = 0.0
    static let legacyBorderOpacity = 0.18
    static let increasedContrastBackdropOpacity = 0.42
    static let increasedContrastBorderOpacity = 0.52
    static let reducedTransparencyBackdropOpacity = 1.0
    static let reducedTransparencyBorderOpacity = 0.62

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

    init(foregroundView: NSView, cornerRadius: CGFloat) {
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
            cornerRadius: cornerRadius
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
        cornerRadius: CGFloat
    ) -> APCNativeBubbleGlassView {
        APCNativeBubbleGlassView(
            foregroundView: contentView,
            cornerRadius: cornerRadius
        )
    }

    static func configureAppearance(
        _ glassView: NSGlassEffectView,
        cornerRadius: CGFloat
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        glassView.style = .regular
        glassView.cornerRadius = cornerRadius
        // Keep the public system material unmodified. Liquid Glass adapts its
        // luminance, blur, and refraction to the live desktop backdrop; a
        // supplemental tint would turn that adaptive material into another
        // product-specific appearance setting.
        glassView.alphaValue = 1
        glassView.tintColor = nil
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
    let content: Content

    func makeNSView(context _: Context) -> APCNativeBubbleGlassView {
        let hostingView = APCNativeBubbleGlassConfiguration.makeHostingView(
            rootView: content
        )
        return APCNativeBubbleGlassConfiguration.makeView(
            contentView: hostingView,
            cornerRadius: cornerRadius
        )
    }

    func updateNSView(_ surfaceView: APCNativeBubbleGlassView, context _: Context) {
        guard let hostingView = surfaceView.foregroundView as? NSHostingView<Content> else { return }

        hostingView.rootView = content
        APCNativeBubbleGlassConfiguration.configureAppearance(
            surfaceView.glassView,
            cornerRadius: cornerRadius
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: APCNativeBubbleGlassView,
        context _: Context
    ) -> CGSize? {
        APCNativeBubbleGlassConfiguration.resolvedSize(
            proposal: proposal,
            fittingSize: nsView.foregroundView.fittingSize
        )
    }
}
#endif

/// The bubble deliberately does not use a `GlassEffectContainer`: that container
/// manages SwiftUI `glassEffect` descendants, which the AppKit
/// surface below is not, and in a transparent `NSPanel` it can elevate the
/// optical layer above foreground content.
private struct APCBubbleGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let cornerRadius: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var backdropColor: Color {
        colorScheme == .dark ? .black : .white
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
                    content: content
                        .background {
                            if increasedContrast {
                                shape.fill(backdropColor.opacity(backdropOpacity))
                            }
                        }
                        .overlay {
                            bubbleOpticalRim
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
        content
            .background(backdropColor.opacity(backdropOpacity), in: shape)
            .overlay {
                bubbleBorder(supportsLiquidGlass: supportsLiquidGlass)
            }
    }

    private func legacyFallback(_ content: Content) -> some View {
        return content
            .background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if reduceTransparency || increasedContrast {
                        shape.fill(backdropColor.opacity(backdropOpacity))
                    }
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

    /// The refraction remains entirely system-rendered by
    /// `NSGlassEffectView`. This inset gradient is only a directional
    /// reflection cue, kept above the native lens and below interaction.
    private var bubbleOpticalRim: some View {
        shape
            .strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity(APCBubbleGlassStyle.opticalRimHighlightOpacity),
                        .white.opacity(APCBubbleGlassStyle.opticalRimMidpointOpacity),
                        .black.opacity(APCBubbleGlassStyle.opticalRimDepthOpacity),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: APCBubbleGlassStyle.opticalRimWidth
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct APCClearGlassButtonStyleModifier: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glass(.clear.tint(APCDesign.accent)))
            } else {
                content.buttonStyle(.glass(.clear))
            }
        } else {
            legacyStyle(content)
        }
#else
        legacyStyle(content)
#endif
    }

    @ViewBuilder
    private func legacyStyle(_ content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    func apcClearGlass<S: Shape>(
        in shape: S,
        interactive: Bool = false
    ) -> some View {
        modifier(APCLiquidGlassModifier(
            shape: shape,
            variant: .clear,
            interactive: interactive
        ))
    }

    /// The desktop bubble floats over unpredictable wallpaper, editors, and
    /// video, so it keeps the untinted adaptive Regular lens rather than the
    /// Clear variant. Refraction and the specular rim separate the surface from
    /// whatever happens to be behind it without a product-defined opacity.
    func apcNativeBubbleGlass(cornerRadius: CGFloat) -> some View {
        modifier(APCBubbleGlassModifier(
            cornerRadius: cornerRadius
        ))
    }

    func apcClearGlassButtonStyle(prominent: Bool = false) -> some View {
        modifier(APCClearGlassButtonStyleModifier(prominent: prominent))
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
        .apcClearGlassButtonStyle(prominent: selected)
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
        .apcClearGlassButtonStyle(prominent: true)
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
        .apcClearGlassButtonStyle()
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
