import AppKit
import AgentPetCompanionCore
import SwiftUI

enum InitialAppearanceReadiness: Equatable {
    case pending
    case authoritative
    case unavailable
}

enum InitialAppearanceWindowPolicy {
    static func appearanceName(
        for readiness: InitialAppearanceReadiness,
        theme: AppearanceTheme
    ) -> NSAppearance.Name? {
        switch readiness {
        case .pending, .unavailable:
            nil
        case .authoritative:
            APCApplicationAppearance.appearanceName(for: theme)
        }
    }
}

/// Applies the persisted appearance to AppKit window chrome without ever
/// gating the window's visibility or input. While PetCore is still hydrating,
/// the window is immediately usable with the system appearance; an
/// authoritative setting is an ordinary idempotent appearance update.
struct InitialAppearanceWindowView: NSViewRepresentable {
    let readiness: InitialAppearanceReadiness
    let theme: AppearanceTheme

    func makeNSView(context: Context) -> InitialAppearanceWindowHostView {
        InitialAppearanceWindowHostView(readiness: readiness, theme: theme)
    }

    func updateNSView(_ nsView: InitialAppearanceWindowHostView, context: Context) {
        nsView.update(readiness: readiness, theme: theme)
    }
}

@MainActor
final class InitialAppearanceWindowHostView: NSView {
    private(set) var readiness: InitialAppearanceReadiness
    private(set) var theme: AppearanceTheme
    private weak var configuredWindow: NSWindow?

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
        applyAppearance()
    }

    func update(readiness: InitialAppearanceReadiness, theme: AppearanceTheme) {
        self.readiness = readiness
        self.theme = theme
        applyAppearance()
    }

    private func applyAppearance() {
        guard let window else { return }
        let appearanceName = InitialAppearanceWindowPolicy.appearanceName(
            for: readiness,
            theme: theme
        )
        let nextAppearance = appearanceName.flatMap(NSAppearance.init(named:))
        guard configuredWindow !== window
                || window.appearance?.name != nextAppearance?.name
        else { return }

        configuredWindow = window
        window.appearance = nextAppearance
    }
}
