import AppKit

enum ControlCenterColdLaunchTiming {
    static let maximumValidationJitterMilliseconds = 1_500

    static func validationJitterMilliseconds(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard environment["APC_VALIDATE_HOST_UI"] == "1",
              let rawValue = environment["APC_CONTROL_CENTER_LAUNCH_JITTER_MS"],
              let value = Int(rawValue),
              (0...maximumValidationJitterMilliseconds).contains(value)
        else {
            return 0
        }
        return value
    }

    @MainActor
    static func schedule(_ action: @escaping @MainActor () -> Void) {
        let delay = validationJitterMilliseconds()
        if delay == 0 {
            DispatchQueue.main.async(execute: action)
        } else {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(delay),
                execute: action
            )
        }
    }
}

/// The single presentation owner for the product's Control Center window.
///
/// SwiftUI may install its `openWindow` presenter and attach the concrete
/// `NSWindow` in either order. Every launch, reopen, menu, overlay, and update
/// request is reduced to one desired presentation here, then fulfilled only
/// when the exact singleton window can be made visible and key.
@MainActor
final class ControlCenterPresentationCoordinator: NSObject {
    enum Phase: Equatable {
        case closed
        case waitingForPresenter
        case waitingForWindow
        case presented

        var diagnosticValue: String {
            switch self {
            case .closed: "closed"
            case .waitingForPresenter: "waiting_for_presenter"
            case .waitingForWindow: "waiting_for_window"
            case .presented: "presented"
            }
        }
    }

    typealias WindowProvider = @MainActor () -> [NSWindow]
    typealias ApplicationActivator = @MainActor () -> Void
    typealias RuntimeHandoffCheck = @MainActor () -> Bool
    typealias WindowHandler = @MainActor (NSWindow) -> Void
    typealias CloseHandler = @MainActor () -> Void

    private let identifier: NSUserInterfaceItemIdentifier
    private let windowProvider: WindowProvider
    private let activateApplication: ApplicationActivator
    private let runtimeHandoffIfNeeded: RuntimeHandoffCheck
    private let onWindowOpened: WindowHandler
    private let onWindowClosed: CloseHandler

    private var presenter: (() -> Void)?
    private weak var window: NSWindow?
    private weak var observedWindow: NSWindow?
    private var wantsPresentation = false
    private var presenterInvokedForOutstandingRequest = false
    private var runtimeHandoffCheckRequired = true

    private(set) var phase = Phase.closed
    private(set) var isOpen = false

    var registeredWindow: NSWindow? {
        guard let window, Self.isCandidate(window, identifier: identifier) else {
            return nil
        }
        return window
    }

    init(
        identifier: NSUserInterfaceItemIdentifier,
        windowProvider: @escaping WindowProvider,
        activateApplication: @escaping ApplicationActivator,
        runtimeHandoffIfNeeded: @escaping RuntimeHandoffCheck,
        onWindowOpened: @escaping WindowHandler,
        onWindowClosed: @escaping CloseHandler
    ) {
        self.identifier = identifier
        self.windowProvider = windowProvider
        self.activateApplication = activateApplication
        self.runtimeHandoffIfNeeded = runtimeHandoffIfNeeded
        self.onWindowOpened = onWindowOpened
        self.onWindowClosed = onWindowClosed
        super.init()
    }

    func installPresenter(_ presenter: @escaping () -> Void) {
        self.presenter = presenter
        fulfillOutstandingRequestIfPossible()
    }

    func register(_ window: NSWindow) {
        window.identifier = identifier
        guard Self.isCandidate(window, identifier: identifier) else { return }

        let publishesOpenTransition = self.window !== window || !isOpen
        if self.window !== window {
            if let observedWindow {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.willCloseNotification,
                    object: observedWindow
                )
            }
            self.window = window
            observedWindow = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(controlCenterWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }

        isOpen = true
        phase = .presented
        if publishesOpenTransition {
            onWindowOpened(window)
        }

        if wantsPresentation {
            front(window)
        }
    }

    @objc
    private func controlCenterWindowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              window === closingWindow
        else {
            return
        }
        window = nil
        observedWindow = nil
        wantsPresentation = false
        presenterInvokedForOutstandingRequest = false
        runtimeHandoffCheckRequired = true
        isOpen = false
        phase = .closed
        onWindowClosed()
    }

    func requestPresentation(checkRuntimeHandoff: Bool) {
        if wantsPresentation {
            // A forced recovery or installation guide must not be weakened by
            // an earlier ordinary request that was still waiting on SwiftUI.
            runtimeHandoffCheckRequired =
                runtimeHandoffCheckRequired && checkRuntimeHandoff
        } else {
            runtimeHandoffCheckRequired = checkRuntimeHandoff
        }
        wantsPresentation = true
        fulfillOutstandingRequestIfPossible()
    }

    static func isCandidate(
        _ window: NSWindow,
        identifier: NSUserInterfaceItemIdentifier
    ) -> Bool {
        window.identifier == identifier
            && !(window is NSPanel)
            && window.level == .normal
            && window.styleMask.contains(.titled)
    }

    private func fulfillOutstandingRequestIfPossible() {
        guard wantsPresentation else { return }

        if let window = resolveWindow() {
            if wantsPresentation {
                front(window)
            }
            return
        }

        guard let presenter else {
            phase = .waitingForPresenter
            return
        }
        guard !presenterInvokedForOutstandingRequest else {
            phase = .waitingForWindow
            return
        }
        guard authorizePresentationIfNeeded() else { return }

        presenterInvokedForOutstandingRequest = true
        phase = .waitingForWindow
        presenter()

        // `openWindow(id:)` normally attaches the AppKit window later, but a
        // test presenter or future scene implementation may do so inline.
        if let window = resolveWindow(), wantsPresentation {
            front(window)
        }
    }

    private func resolveWindow() -> NSWindow? {
        if let registeredWindow {
            return registeredWindow
        }
        guard let candidate = windowProvider().first(where: {
            Self.isCandidate($0, identifier: identifier)
        }) else {
            return nil
        }
        register(candidate)
        return candidate
    }

    private func authorizePresentationIfNeeded() -> Bool {
        guard runtimeHandoffCheckRequired else { return true }
        guard !runtimeHandoffIfNeeded() else {
            wantsPresentation = false
            presenterInvokedForOutstandingRequest = false
            runtimeHandoffCheckRequired = true
            phase = isOpen ? .presented : .closed
            return false
        }
        runtimeHandoffCheckRequired = false
        return true
    }

    private func front(_ window: NSWindow) {
        guard authorizePresentationIfNeeded() else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        // Presentation invariants belong here. No appearance hydration or
        // overlay update may leave the Control Center transparent, unable to
        // receive input, behind another app, or represented by another window.
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        activateApplication()
        window.makeKeyAndOrderFront(nil)

        self.window = window
        wantsPresentation = false
        presenterInvokedForOutstandingRequest = false
        runtimeHandoffCheckRequired = true
        isOpen = true
        phase = .presented
    }
}
