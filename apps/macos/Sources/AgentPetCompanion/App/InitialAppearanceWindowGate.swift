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

    static func dismantleNSView(
        _ nsView: InitialAppearanceWindowGateHostView,
        coordinator: Void
    ) {
        nsView.detachFromWindow()
    }
}

@MainActor
private enum InitialAppearanceWindowGateCoordinatorStore {
    static let coordinators =
        NSMapTable<NSWindow, InitialAppearanceWindowGateWindowCoordinator>
            .weakToStrongObjects()

    static func coordinator(
        for window: NSWindow
    ) -> InitialAppearanceWindowGateWindowCoordinator {
        if let coordinator = coordinators.object(forKey: window) {
            return coordinator
        }
        let coordinator = InitialAppearanceWindowGateWindowCoordinator(window: window)
        coordinators.setObject(coordinator, forKey: window)
        return coordinator
    }
}

/// One coordinator owns the shared NSWindow state even when SwiftUI replaces
/// or temporarily duplicates its representable host views. The window must
/// never depend on a transient host surviving until the deferred reveal turn.
@MainActor
private final class InitialAppearanceWindowGateWindowCoordinator {
    private weak var window: NSWindow?
    private var owners: Set<ObjectIdentifier> = []
    private var resolvedReadiness = InitialAppearanceReadiness.pending
    private var theme = AppearanceTheme.system
    private var originalAlphaValue: CGFloat?
    private var originalIgnoresMouseEvents: Bool?
    private var isConcealed = false
    private var revealScheduled = false
    private(set) var hasRevealed = false

    init(window: NSWindow) {
        self.window = window
    }

    func attach(
        owner: InitialAppearanceWindowGateHostView,
        readiness: InitialAppearanceReadiness,
        theme: AppearanceTheme
    ) {
        owners.insert(ObjectIdentifier(owner))
        update(readiness: readiness, theme: theme)
    }

    func update(readiness: InitialAppearanceReadiness, theme: AppearanceTheme) {
        self.theme = theme
        if readiness != .pending {
            resolvedReadiness = readiness
        }
        applyGate()
    }

    func detach(owner: InitialAppearanceWindowGateHostView) {
        owners.remove(ObjectIdentifier(owner))
        guard owners.isEmpty, isConcealed else { return }

        // A representable can disappear between updateNSView and the next
        // main-queue turn. Fail open with the system appearance instead of
        // leaving the whole App permanently transparent and non-interactive.
        if resolvedReadiness == .pending {
            resolvedReadiness = .unavailable
        }
        scheduleReveal()
    }

    private func applyGate() {
        guard let window else { return }
        switch InitialAppearanceWindowGate.action(
            for: resolvedReadiness,
            theme: theme,
            hasRevealed: hasRevealed
        ) {
        case .conceal:
            conceal(window)
        case .noChange:
            return
        case let .reveal(appearanceName):
            window.appearance = appearanceName.flatMap(NSAppearance.init(named:))
            scheduleReveal()
        }
    }

    private func conceal(_ window: NSWindow) {
        guard !isConcealed, !hasRevealed else { return }

        // A second representable may attach after the first already concealed
        // this window. Window-scoped ownership prevents it from recording zero
        // alpha or ignored mouse events as the state that should be restored.
        originalAlphaValue = window.alphaValue > 0 ? window.alphaValue : 1
        originalIgnoresMouseEvents = window.alphaValue > 0
            ? window.ignoresMouseEvents
            : false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        isConcealed = true
    }

    private func scheduleReveal() {
        guard let window else { return }
        guard isConcealed else {
            hasRevealed = true
            return
        }
        guard !revealScheduled else { return }
        revealScheduled = true

        // `updateNSView` runs while SwiftUI may still be rendering its
        // NSHostingView. Defer the AppKit mutation, but keep its ownership in
        // this window-retained coordinator rather than the transient host.
        DispatchQueue.main.async { [self, weak window] in
            revealScheduled = false
            guard let window, self.window === window else { return }
            guard resolvedReadiness != .pending || owners.isEmpty else { return }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                window.alphaValue = originalAlphaValue ?? 1
            }
            window.ignoresMouseEvents = originalIgnoresMouseEvents ?? false
            originalAlphaValue = nil
            originalIgnoresMouseEvents = nil
            isConcealed = false
            hasRevealed = true
        }
    }
}

@MainActor
final class InitialAppearanceWindowGateHostView: NSView {
    private(set) var readiness: InitialAppearanceReadiness
    private(set) var theme: AppearanceTheme

    var hasRevealed: Bool {
        windowCoordinator?.hasRevealed ?? false
    }

    private weak var controlledWindow: NSWindow?
    private var windowCoordinator: InitialAppearanceWindowGateWindowCoordinator?

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
        attachToWindowIfNeeded()
    }

    func update(readiness: InitialAppearanceReadiness, theme: AppearanceTheme) {
        self.readiness = readiness
        self.theme = theme
        attachToWindowIfNeeded()
        windowCoordinator?.update(readiness: readiness, theme: theme)
    }

    func detachFromWindow() {
        if let windowCoordinator {
            windowCoordinator.detach(owner: self)
        }
        windowCoordinator = nil
        controlledWindow = nil
    }

    private func attachToWindowIfNeeded() {
        guard controlledWindow !== window else { return }
        detachFromWindow()
        guard let window else { return }

        let coordinator = InitialAppearanceWindowGateCoordinatorStore.coordinator(
            for: window
        )
        controlledWindow = window
        windowCoordinator = coordinator
        coordinator.attach(owner: self, readiness: readiness, theme: theme)
    }
}
