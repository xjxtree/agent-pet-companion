import AppKit
import AgentPetCompanionCore
import SwiftUI

enum InitialAppearanceReadiness: Equatable {
    case pending
    case authoritative
    case unavailable
}

enum InitialAppearanceWindowGate {
    static func shouldRevealWindow(for readiness: InitialAppearanceReadiness) -> Bool {
        readiness != .pending
    }

    static func action(
        for readiness: InitialAppearanceReadiness,
        theme: AppearanceTheme,
        hasRevealed: Bool
    ) -> InitialAppearanceWindowGateAction {
        switch readiness {
        case .pending:
            hasRevealed ? .noChange : .conceal
        case .authoritative:
            .reveal(appearanceName: APCApplicationAppearance.appearanceName(for: theme))
        case .unavailable:
            .reveal(appearanceName: nil)
        }
    }
}

enum InitialAppearanceWindowGateAction: Equatable {
    case conceal
    case reveal(appearanceName: NSAppearance.Name?)
    case noChange
}

/// Hides AppKit chrome as well as SwiftUI content until the persisted theme is
/// known. A SwiftUI opacity modifier cannot cover a title-bar flash, so the
/// gate controls the owning NSWindow without ordering it on screen or taking
/// input focus.
struct InitialAppearanceWindowGateView: NSViewRepresentable {
    let readiness: InitialAppearanceReadiness
    let theme: AppearanceTheme

    func makeNSView(context: Context) -> InitialAppearanceWindowGateHostView {
        InitialAppearanceWindowGateHostView(readiness: readiness, theme: theme)
    }

    func updateNSView(_ nsView: InitialAppearanceWindowGateHostView, context: Context) {
        nsView.update(readiness: readiness, theme: theme)
    }
}

@MainActor
final class InitialAppearanceWindowGateHostView: NSView {
    private(set) var readiness: InitialAppearanceReadiness
    private(set) var theme: AppearanceTheme
    private(set) var hasRevealed = false

    private weak var controlledWindow: NSWindow?
    private var originalAlphaValue: CGFloat?
    private var originalIgnoresMouseEvents: Bool?

    init(readiness: InitialAppearanceReadiness, theme: AppearanceTheme) {
        self.readiness = readiness
        self.theme = theme
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyGate()
    }

    func update(readiness: InitialAppearanceReadiness, theme: AppearanceTheme) {
        self.readiness = readiness
        self.theme = theme
        applyGate()
    }

    private func applyGate() {
        guard let window else { return }
        captureOriginalWindowStateIfNeeded(for: window)

        switch InitialAppearanceWindowGate.action(
            for: readiness,
            theme: theme,
            hasRevealed: hasRevealed
        ) {
        case .conceal:
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            return
        case .noChange:
            return
        case let .reveal(appearanceName):
            window.appearance = appearanceName.flatMap(NSAppearance.init(named:))
        }

        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            window.alphaValue = originalAlphaValue ?? 1
        }
        window.ignoresMouseEvents = originalIgnoresMouseEvents ?? false
        hasRevealed = true
    }

    private func captureOriginalWindowStateIfNeeded(for window: NSWindow) {
        guard controlledWindow !== window else { return }
        controlledWindow = window
        originalAlphaValue = window.alphaValue
        originalIgnoresMouseEvents = window.ignoresMouseEvents
    }
}
