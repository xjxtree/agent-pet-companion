//! Display refresh observation and coalescing for overlay
//! presentation, including the CADisplayLink-backed tick source.
import AppKit
import AgentPetCompanionCore
import Combine
import CoreGraphics
import Foundation
import QuartzCore

struct OverlayDisplayGeometry: Equatable, Sendable {
    var frame: CGRect
    var visibleFrame: CGRect
    var backingScaleFactor: CGFloat
}

/// The target display's presentation cadence. `CGDisplayMode.refreshRate`
/// reflects an explicitly selected 50/60/etc. Hz mode; some built-in and
/// adaptive displays report zero there, so AppKit's advertised maximum is the
/// bounded fallback before the conservative 60 Hz default.
struct OverlayDisplayRefreshCadence: Equatable, Sendable {
    let displayID: String
    let framesPerSecond: Double

    init(displayID: String, framesPerSecond: Double) {
        self.displayID = displayID
        self.framesPerSecond = framesPerSecond.isFinite && framesPerSecond > 0
            ? framesPerSecond
            : 60
    }

    var intervalSeconds: TimeInterval {
        1 / framesPerSecond
    }

    static func resolved(for screen: NSScreen?) -> Self {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        let screenNumber = screen?.deviceDescription[screenNumberKey] as? NSNumber
        let displayID = screenNumber?.stringValue ?? "fallback"
        let directDisplayID = screenNumber.map { CGDirectDisplayID($0.uint32Value) }
        let selectedModeRefreshRate = directDisplayID
            .flatMap(CGDisplayCopyDisplayMode)?
            .refreshRate ?? 0
        let advertisedMaximum = Double(screen?.maximumFramesPerSecond ?? 0)
        let refreshRate = selectedModeRefreshRate > 0
            ? selectedModeRefreshRate
            : (advertisedMaximum > 0 ? advertisedMaximum : 60)
        return Self(displayID: displayID, framesPerSecond: refreshRate)
    }
}

/// Latest-value coalescing state shared by pointer drag and display-width
/// preview. Callers inject monotonic timestamps, which keeps the cadence logic
/// deterministic in tests and lets production own exactly one sleeping task.
struct OverlayDisplayRefreshCoalescer<Value> {
    private var pending: Value?
    private var cadence: OverlayDisplayRefreshCadence?
    private var lastDeliveryTime: TimeInterval?
    private(set) var scheduledDeadline: TimeInterval?

    @discardableResult
    mutating func submit(
        _ value: Value,
        at time: TimeInterval,
        cadence proposedCadence: OverlayDisplayRefreshCadence
    ) -> TimeInterval {
        let now = max(0, time)
        pending = value
        if scheduledDeadline == nil || cadence != proposedCadence {
            let earliest: TimeInterval
            if let lastDeliveryTime {
                earliest = lastDeliveryTime + proposedCadence.intervalSeconds
            } else {
                earliest = now + proposedCadence.intervalSeconds
            }
            scheduledDeadline = max(now, earliest)
        }
        cadence = proposedCadence
        return scheduledDeadline ?? now
    }

    mutating func takePending(deliveredAt time: TimeInterval) -> Value? {
        guard let pending else { return nil }
        self.pending = nil
        scheduledDeadline = nil
        lastDeliveryTime = max(lastDeliveryTime ?? 0, max(0, time))
        return pending
    }

    mutating func cancelPending() {
        pending = nil
        scheduledDeadline = nil
        cadence = nil
    }
}

@MainActor
protocol OverlayDisplayRefreshTickSource: AnyObject {
    var isPaused: Bool { get set }
    func invalidate()
}

@MainActor
private final class OverlayDisplayLinkWeakTarget: NSObject {
    private let onTick: @MainActor () -> Void

    init(onTick: @escaping @MainActor () -> Void) {
        self.onTick = onTick
    }

    @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
        onTick()
    }
}

@MainActor
private final class OverlayScreenDisplayLinkTickSource:
    OverlayDisplayRefreshTickSource
{
    private let target: OverlayDisplayLinkWeakTarget
    // Source creation, mutation, and teardown are MainActor-owned. The unsafe
    // annotation only lets deinit invalidate AppKit's non-Sendable token.
    nonisolated(unsafe) private let displayLink: CADisplayLink

    init?(screen: NSScreen?, onTick: @escaping @MainActor () -> Void) {
        guard let screen else { return nil }
        let target = OverlayDisplayLinkWeakTarget(onTick: onTick)
        let displayLink = screen.displayLink(
            target: target,
            selector: #selector(OverlayDisplayLinkWeakTarget.displayLinkDidFire(_:))
        )
        self.target = target
        self.displayLink = displayLink
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
    }

    var isPaused: Bool {
        get { displayLink.isPaused }
        set { displayLink.isPaused = newValue }
    }

    func invalidate() {
        displayLink.invalidate()
    }

    deinit {
        displayLink.invalidate()
    }
}

/// Tick-driven latest-value delivery for direct manipulation. A real target
/// screen binds an `NSScreen` display link, so adaptive-refresh panels follow
/// actual presentation ticks rather than an assumed maximum FPS. The time
/// coalescer remains only as the no-screen/display-link fallback.
@MainActor
final class OverlayDisplayLinkCoalescer<Value> {
    typealias TickSourceFactory = @MainActor (
        _ screen: NSScreen?,
        _ onTick: @escaping @MainActor () -> Void
    ) -> (any OverlayDisplayRefreshTickSource)?

    private let tickSourceFactory: TickSourceFactory
    private var tickSource: (any OverlayDisplayRefreshTickSource)?
    private var targetDisplayID: String?
    private var pending: Value?
    private var delivery: ((Value) -> Void)?
    private var fallbackCoalescer = OverlayDisplayRefreshCoalescer<Void>()
    private var fallbackTask: Task<Void, Never>?
    private var fallbackTaskDeadline: TimeInterval?
    /// Keeps the tick source armed for a whole gesture. Pausing after every
    /// delivery and re-arming on the next pointer sample can miss the upcoming
    /// vsync, so a steady drag presents on an irregular cadence even though
    /// every sample arrives on time.
    private var sustainsTicks = false

    init(
        tickSourceFactory: @escaping TickSourceFactory = { screen, onTick in
            return OverlayScreenDisplayLinkTickSource(
                screen: screen,
                onTick: onTick
            )
        }
    ) {
        self.tickSourceFactory = tickSourceFactory
    }

    var hasPending: Bool { pending != nil }

    /// Holds the tick source unpaused until `endSustainedDelivery`, so an
    /// active gesture presents on every display tick instead of re-arming a
    /// paused link per pointer sample.
    func beginSustainedDelivery() {
        sustainsTicks = true
        tickSource?.isPaused = false
    }

    func endSustainedDelivery() {
        sustainsTicks = false
        guard pending == nil else { return }
        tickSource?.isPaused = true
    }

    func submit(
        _ value: Value,
        targetDisplayID: String,
        screen: NSScreen?,
        fallbackCadence: OverlayDisplayRefreshCadence,
        deliver: @escaping (Value) -> Void
    ) {
        pending = value
        delivery = deliver
        if self.targetDisplayID != targetDisplayID {
            rebind(targetDisplayID: targetDisplayID, screen: screen)
        }
        if let tickSource {
            tickSource.isPaused = false
            return
        }
        let deadline = fallbackCoalescer.submit(
            (),
            at: ProcessInfo.processInfo.systemUptime,
            cadence: fallbackCadence
        )
        scheduleFallback(at: deadline)
    }

    func flushNow() {
        deliverPending()
    }

    func cancelPending() {
        pending = nil
        delivery = nil
        sustainsTicks = false
        tickSource?.isPaused = true
        fallbackTask?.cancel()
        fallbackTask = nil
        fallbackTaskDeadline = nil
        fallbackCoalescer.cancelPending()
    }

    func invalidate() {
        cancelPending()
        tickSource?.invalidate()
        tickSource = nil
        targetDisplayID = nil
    }

    func receiveDisplayRefreshTick() {
        deliverPending()
    }

    private func rebind(targetDisplayID: String, screen: NSScreen?) {
        tickSource?.invalidate()
        tickSource = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        fallbackTaskDeadline = nil
        fallbackCoalescer.cancelPending()
        self.targetDisplayID = targetDisplayID
        tickSource = tickSourceFactory(screen) { [weak self] in
            self?.receiveDisplayRefreshTick()
        }
    }

    private func deliverPending() {
        guard let pending else {
            tickSource?.isPaused = !sustainsTicks
            return
        }
        let delivery = delivery
        self.pending = nil
        self.delivery = nil
        tickSource?.isPaused = !sustainsTicks
        fallbackTask?.cancel()
        fallbackTask = nil
        fallbackTaskDeadline = nil
        _ = fallbackCoalescer.takePending(
            deliveredAt: ProcessInfo.processInfo.systemUptime
        )
        delivery?(pending)
    }

    private func scheduleFallback(at deadline: TimeInterval) {
        if let fallbackTaskDeadline,
           abs(fallbackTaskDeadline - deadline) < 0.000_001,
           fallbackTask != nil {
            return
        }
        fallbackTask?.cancel()
        fallbackTaskDeadline = deadline
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        fallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.fallbackTask = nil
            self.fallbackTaskDeadline = nil
            self.deliverPending()
        }
    }
}
