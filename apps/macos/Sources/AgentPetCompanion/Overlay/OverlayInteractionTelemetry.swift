import Foundation
import OSLog

enum OverlayInteractionTelemetrySource: String, CaseIterable, Sendable {
    case view
    case monitor
    case persistence
}

enum OverlayInteractionTelemetryResult: String, CaseIterable, Sendable {
    case success
    case conflict
    case transportFailure = "transport_failure"
    case stale
    case suppressed
    case exhausted
}

enum OverlayInteractionDurationBucket: String, CaseIterable, Sendable {
    case under4MS = "under_4_ms"
    case under8MS = "under_8_ms"
    case under16MS = "under_16_ms"
    case under33MS = "under_33_ms"
    case atLeast33MS = "at_least_33_ms"

    init(milliseconds: Double) {
        self = switch max(0, milliseconds) {
        case ..<4: .under4MS
        case ..<8: .under8MS
        case ..<16: .under16MS
        case ..<33: .under33MS
        default: .atLeast33MS
        }
    }
}

enum OverlayInteractionTelemetryEvent: String, CaseIterable, Sendable {
    case pointerDown = "pointer_down"
    case dragThresholdCrossed = "drag_threshold_crossed"
    case firstPresentationApplied = "first_presentation_applied"
    case coalescedPresentationTick = "coalesced_presentation_tick"
    case normalMouseUpObserved = "normal_mouse_up_observed"
    case fallbackArmed = "fallback_armed"
    case fallbackFired = "fallback_fired"
    case fallbackSuppressed = "fallback_suppressed"
    case finalFrameApplied = "final_frame_applied"
    case placementCommitQueued = "placement_commit_queued"
    case requestAttempt = "request_attempt"
    case requestResult = "request_result"
    case convergenceComplete = "convergence_complete"
    case retryExhausted = "retry_exhausted"
}

/// Closed, privacy-reviewed metadata. Coordinates, frames, display/pet/session
/// identities, paths, text, and RPC payloads are deliberately unrepresentable.
struct OverlayInteractionTelemetryRecord: Equatable, Sendable {
    static let allowedMetadataKeys: Set<String> = [
        "attempt",
        "boundary_clamped",
        "bubble_visible",
        "duration_bucket",
        "event",
        "menu_visible",
        "result",
        "source",
    ]

    let event: OverlayInteractionTelemetryEvent
    let source: OverlayInteractionTelemetrySource
    var result: OverlayInteractionTelemetryResult?
    var attempt: UInt8?
    var durationBucket: OverlayInteractionDurationBucket?
    var boundaryClamped = false
    var bubbleVisible = false
    var menuVisible = false

    var isValid: Bool {
        attempt.map { (1 ... 5).contains($0) } ?? true
    }
}

struct OverlayInteractionMetricPercentiles: Codable, Equatable, Sendable {
    let p50: Double
    let p95: Double
    let p99: Double
}

/// Privacy-safe aggregate emitted only when an explicit validation output
/// path is configured. It contains timings and counts, never raw events or
/// any product/user identifiers.
struct OverlayInteractionPerformanceSummary: Codable, Equatable, Sendable {
    let schemaVersion = "apc.overlay-performance-summary.v1"
    let presentationSampleCount: Int
    let completedInteractionCount: Int
    let eventToWindowApplyMS: OverlayInteractionMetricPercentiles?
    let handlerCPUms: OverlayInteractionMetricPercentiles?
    let missedDisplayLinkRatio: Double
    let releaseToStableMS: OverlayInteractionMetricPercentiles?
    let commitToConvergenceMS: OverlayInteractionMetricPercentiles?
    let attemptCount: OverlayInteractionMetricPercentiles?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case presentationSampleCount = "presentation_sample_count"
        case completedInteractionCount = "completed_interaction_count"
        case eventToWindowApplyMS = "event_to_window_apply_ms"
        case handlerCPUms = "handler_cpu_ms"
        case missedDisplayLinkRatio = "missed_display_link_ratio"
        case releaseToStableMS = "release_to_stable_ms"
        case commitToConvergenceMS = "commit_to_convergence_ms"
        case attemptCount = "attempt_count"
    }
}

struct OverlayInteractionPerformanceAccumulator: Sendable {
    private(set) var eventToWindowApplyMS: [Double] = []
    private(set) var handlerCPUms: [Double] = []
    private(set) var releaseToStableMS: [Double] = []
    private(set) var commitToConvergenceMS: [Double] = []
    private(set) var attemptCounts: [Double] = []
    private(set) var expectedDisplayLinkIntervals = 0
    private(set) var missedDisplayLinkIntervals = 0
    private(set) var completedInteractionCount = 0

    mutating func recordPresentation(
        eventTimestamp: TimeInterval,
        appliedAt: TimeInterval,
        handlerCPUms: Double,
        refreshIntervalMS: Double
    ) {
        guard eventTimestamp > 0,
              appliedAt >= eventTimestamp,
              handlerCPUms.isFinite,
              handlerCPUms >= 0,
              refreshIntervalMS.isFinite,
              refreshIntervalMS > 0 else { return }
        let latencyMS = (appliedAt - eventTimestamp) * 1_000
        guard latencyMS.isFinite, latencyMS <= 10_000 else { return }
        eventToWindowApplyMS.append(latencyMS)
        self.handlerCPUms.append(handlerCPUms)
        let intervals = max(1, Int(ceil(latencyMS / refreshIntervalMS)))
        expectedDisplayLinkIntervals += intervals
        missedDisplayLinkIntervals += max(0, intervals - 1)
    }

    mutating func recordRelease(mouseUpAt: TimeInterval, stableAt: TimeInterval) {
        guard stableAt >= mouseUpAt else { return }
        releaseToStableMS.append((stableAt - mouseUpAt) * 1_000)
    }

    mutating func recordConvergence(
        commitQueuedAt: TimeInterval?,
        completedAt: TimeInterval,
        attemptCount: Int
    ) {
        completedInteractionCount += 1
        if let commitQueuedAt, completedAt >= commitQueuedAt {
            commitToConvergenceMS.append(
                (completedAt - commitQueuedAt) * 1_000
            )
        }
        if attemptCount > 0 {
            attemptCounts.append(Double(min(5, attemptCount)))
        }
    }

    var summary: OverlayInteractionPerformanceSummary {
        OverlayInteractionPerformanceSummary(
            presentationSampleCount: eventToWindowApplyMS.count,
            completedInteractionCount: completedInteractionCount,
            eventToWindowApplyMS: Self.percentiles(eventToWindowApplyMS),
            handlerCPUms: Self.percentiles(handlerCPUms),
            missedDisplayLinkRatio: expectedDisplayLinkIntervals == 0
                ? 0
                : Double(missedDisplayLinkIntervals)
                    / Double(expectedDisplayLinkIntervals),
            releaseToStableMS: Self.percentiles(releaseToStableMS),
            commitToConvergenceMS: Self.percentiles(commitToConvergenceMS),
            attemptCount: Self.percentiles(attemptCounts)
        )
    }

    private static func percentiles(
        _ values: [Double]
    ) -> OverlayInteractionMetricPercentiles? {
        guard !values.isEmpty else { return nil }
        let ordered = values.sorted()
        func value(at percentile: Double) -> Double {
            let index = min(
                ordered.count - 1,
                max(0, Int(ceil(percentile * Double(ordered.count))) - 1)
            )
            return ordered[index]
        }
        return OverlayInteractionMetricPercentiles(
            p50: value(at: 0.50),
            p95: value(at: 0.95),
            p99: value(at: 0.99)
        )
    }
}

@MainActor
final class OverlayInteractionTelemetry {
    static let shared = OverlayInteractionTelemetry()

    private struct Transaction {
        let signpostID: OSSignpostID
        let interval: OSSignpostIntervalState
        let startedAt: TimeInterval
        var firstPresentationApplied = false
        var mouseUpAt: TimeInterval?
        var commitQueuedAt: TimeInterval?
        var attemptCount = 0
    }

    private let signposter: OSSignposter
    private let performanceSummaryURL: URL?
    private let performanceWriter = DispatchQueue(
        label: "io.github.agent-pet-companion.overlay-performance-writer",
        qos: .utility
    )
    private var transactions: [UUID: Transaction] = [:]
    private var performance = OverlayInteractionPerformanceAccumulator()

    init(
        subsystem: String = Bundle.main.bundleIdentifier
            ?? "io.github.agent-pet-companion",
        performanceSummaryPath: String? = ProcessInfo.processInfo.environment[
            "APC_OVERLAY_PERFORMANCE_SUMMARY_PATH"
        ]
    ) {
        signposter = OSSignposter(logger: Logger(
            subsystem: subsystem,
            category: "OverlayInteraction"
        ))
        if let performanceSummaryPath,
           performanceSummaryPath.hasPrefix("/") {
            performanceSummaryURL = URL(fileURLWithPath: performanceSummaryPath)
        } else {
            performanceSummaryURL = nil
        }
    }

    func pointerDown(
        interactionID: UUID,
        bubbleVisible: Bool,
        menuVisible: Bool
    ) {
        guard transactions[interactionID] == nil else { return }
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval(
            "OverlayDrag",
            id: signpostID
        )
        transactions[interactionID] = Transaction(
            signpostID: signpostID,
            interval: interval,
            startedAt: ProcessInfo.processInfo.systemUptime
        )
        emit(OverlayInteractionTelemetryRecord(
            event: .pointerDown,
            source: .view,
            bubbleVisible: bubbleVisible,
            menuVisible: menuVisible
        ), signpostID: signpostID)
    }

    func thresholdCrossed(interactionID: UUID) {
        guard let transaction = transactions[interactionID] else { return }
        emit(OverlayInteractionTelemetryRecord(
            event: .dragThresholdCrossed,
            source: .view
        ), signpostID: transaction.signpostID)
    }

    func presentationApplied(
        interactionID: UUID,
        boundaryClamped: Bool,
        eventTimestamp: TimeInterval,
        handlerCPUms: Double,
        refreshIntervalMS: Double
    ) {
        guard var transaction = transactions[interactionID] else { return }
        let appliedAt = ProcessInfo.processInfo.systemUptime
        let isFirst = !transaction.firstPresentationApplied
        transaction.firstPresentationApplied = true
        transactions[interactionID] = transaction
        if performanceSummaryURL != nil {
            performance.recordPresentation(
                eventTimestamp: eventTimestamp,
                appliedAt: appliedAt,
                handlerCPUms: handlerCPUms,
                refreshIntervalMS: refreshIntervalMS
            )
        }
        emit(OverlayInteractionTelemetryRecord(
            event: isFirst
                ? .firstPresentationApplied
                : .coalescedPresentationTick,
            source: .view,
            durationBucket: .init(milliseconds: elapsedMS(transaction)),
            boundaryClamped: boundaryClamped
        ), signpostID: transaction.signpostID)
    }

    func normalMouseUp(interactionID: UUID) {
        guard var transaction = transactions[interactionID] else { return }
        transaction.mouseUpAt = ProcessInfo.processInfo.systemUptime
        transactions[interactionID] = transaction
        emit(OverlayInteractionTelemetryRecord(
            event: .normalMouseUpObserved,
            source: .view,
            durationBucket: .init(milliseconds: elapsedMS(transaction))
        ), signpostID: transaction.signpostID)
    }

    func fallback(
        _ event: OverlayInteractionTelemetryEvent,
        interactionID: UUID
    ) {
        guard [.fallbackArmed, .fallbackFired, .fallbackSuppressed]
            .contains(event),
              let transaction = transactions[interactionID] else { return }
        emit(OverlayInteractionTelemetryRecord(
            event: event,
            source: .monitor,
            result: event == .fallbackSuppressed ? .suppressed : nil
        ), signpostID: transaction.signpostID)
    }

    func finalFrameApplied(interactionID: UUID) {
        guard let transaction = transactions[interactionID] else { return }
        let stableAt = ProcessInfo.processInfo.systemUptime
        if performanceSummaryURL != nil,
           let mouseUpAt = transaction.mouseUpAt {
            performance.recordRelease(
                mouseUpAt: mouseUpAt,
                stableAt: stableAt
            )
        }
        emit(OverlayInteractionTelemetryRecord(
            event: .finalFrameApplied,
            source: .view,
            durationBucket: .init(milliseconds: elapsedMS(transaction))
        ), signpostID: transaction.signpostID)
    }

    func commitQueued(interactionID: UUID) {
        guard var transaction = transactions[interactionID] else { return }
        transaction.commitQueuedAt = ProcessInfo.processInfo.systemUptime
        transactions[interactionID] = transaction
        emit(OverlayInteractionTelemetryRecord(
            event: .placementCommitQueued,
            source: .persistence
        ), signpostID: transaction.signpostID)
    }

    func requestAttempt(interactionID: UUID, attempt: Int) {
        guard var transaction = transactions[interactionID],
              (1 ... 5).contains(attempt) else { return }
        transaction.attemptCount = max(transaction.attemptCount, attempt)
        transactions[interactionID] = transaction
        emit(OverlayInteractionTelemetryRecord(
            event: .requestAttempt,
            source: .persistence,
            attempt: UInt8(attempt)
        ), signpostID: transaction.signpostID)
    }

    func requestResult(
        interactionID: UUID,
        attempt: Int,
        result: OverlayInteractionTelemetryResult
    ) {
        guard let transaction = transactions[interactionID],
              (1 ... 5).contains(attempt) else { return }
        emit(OverlayInteractionTelemetryRecord(
            event: .requestResult,
            source: .persistence,
            result: result,
            attempt: UInt8(attempt)
        ), signpostID: transaction.signpostID)
    }

    func finish(
        interactionID: UUID,
        result: OverlayInteractionTelemetryResult
    ) {
        guard let transaction = transactions.removeValue(
            forKey: interactionID
        ) else { return }
        let completedAt = ProcessInfo.processInfo.systemUptime
        if performanceSummaryURL != nil {
            performance.recordConvergence(
                commitQueuedAt: transaction.commitQueuedAt,
                completedAt: completedAt,
                attemptCount: transaction.attemptCount
            )
        }
        emit(OverlayInteractionTelemetryRecord(
            event: result == .exhausted
                ? .retryExhausted
                : .convergenceComplete,
            source: .persistence,
            result: result,
            durationBucket: .init(milliseconds: elapsedMS(transaction))
        ), signpostID: transaction.signpostID)
        signposter.endInterval("OverlayDrag", transaction.interval)
        persistPerformanceSummaryIfEnabled()
    }

    private func elapsedMS(_ transaction: Transaction) -> Double {
        (ProcessInfo.processInfo.systemUptime - transaction.startedAt) * 1_000
    }

    private func emit(
        _ record: OverlayInteractionTelemetryRecord,
        signpostID: OSSignpostID
    ) {
        guard record.isValid else { return }
        // Event names are a closed static vocabulary. No dynamic values or
        // identifiers enter the signpost payload.
        switch record.event {
        case .pointerDown:
            switch (record.bubbleVisible, record.menuVisible) {
            case (false, false):
                signposter.emitEvent("PointerDownAuxHidden", id: signpostID)
            case (true, false):
                signposter.emitEvent("PointerDownBubbleVisible", id: signpostID)
            case (false, true):
                signposter.emitEvent("PointerDownMenuVisible", id: signpostID)
            case (true, true):
                signposter.emitEvent("PointerDownAuxVisible", id: signpostID)
            }
        case .dragThresholdCrossed: signposter.emitEvent("DragThresholdCrossed", id: signpostID)
        case .firstPresentationApplied:
            if record.boundaryClamped {
                signposter.emitEvent(
                    "FirstPresentationAppliedClamped",
                    id: signpostID
                )
            } else {
                signposter.emitEvent(
                    "FirstPresentationApplied",
                    id: signpostID
                )
            }
        case .coalescedPresentationTick:
            if record.boundaryClamped {
                signposter.emitEvent(
                    "CoalescedPresentationTickClamped",
                    id: signpostID
                )
            } else {
                signposter.emitEvent(
                    "CoalescedPresentationTick",
                    id: signpostID
                )
            }
        case .normalMouseUpObserved: signposter.emitEvent("NormalMouseUpObserved", id: signpostID)
        case .fallbackArmed: signposter.emitEvent("FallbackArmed", id: signpostID)
        case .fallbackFired: signposter.emitEvent("FallbackFired", id: signpostID)
        case .fallbackSuppressed: signposter.emitEvent("FallbackSuppressed", id: signpostID)
        case .finalFrameApplied: signposter.emitEvent("FinalFrameApplied", id: signpostID)
        case .placementCommitQueued: signposter.emitEvent("PlacementCommitQueued", id: signpostID)
        case .requestAttempt:
            switch record.attempt {
            case 1: signposter.emitEvent("PlacementRequestAttempt1", id: signpostID)
            case 2: signposter.emitEvent("PlacementRequestAttempt2", id: signpostID)
            case 3: signposter.emitEvent("PlacementRequestAttempt3", id: signpostID)
            case 4: signposter.emitEvent("PlacementRequestAttempt4", id: signpostID)
            case 5: signposter.emitEvent("PlacementRequestAttempt5", id: signpostID)
            default: return
            }
        case .requestResult:
            switch record.result {
            case .success: signposter.emitEvent("PlacementRequestSuccess", id: signpostID)
            case .conflict: signposter.emitEvent("PlacementRequestConflict", id: signpostID)
            case .transportFailure: signposter.emitEvent("PlacementRequestTransportFailure", id: signpostID)
            case .stale: signposter.emitEvent("PlacementRequestStale", id: signpostID)
            case .suppressed: signposter.emitEvent("PlacementRequestSuppressed", id: signpostID)
            case .exhausted: signposter.emitEvent("PlacementRequestExhausted", id: signpostID)
            case nil: return
            }
        case .convergenceComplete:
            switch record.result {
            case .success: signposter.emitEvent("PlacementConverged", id: signpostID)
            case .stale: signposter.emitEvent("PlacementSuperseded", id: signpostID)
            case .suppressed: signposter.emitEvent("PlacementCancelled", id: signpostID)
            case .conflict: signposter.emitEvent("PlacementConvergedConflict", id: signpostID)
            case .transportFailure: signposter.emitEvent("PlacementConvergenceFailed", id: signpostID)
            case .exhausted: signposter.emitEvent("PlacementRetryExhausted", id: signpostID)
            case nil: return
            }
        case .retryExhausted: signposter.emitEvent("PlacementRetryExhausted", id: signpostID)
        }
    }

    private func persistPerformanceSummaryIfEnabled() {
        guard let performanceSummaryURL,
              let data = try? JSONEncoder().encode(performance.summary) else {
            return
        }
        performanceWriter.async {
            try? data.write(to: performanceSummaryURL, options: .atomic)
        }
    }
}
