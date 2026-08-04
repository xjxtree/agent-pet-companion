import Foundation
import Testing
@testable import AgentPetCompanion

@Suite("Overlay interaction telemetry privacy")
struct OverlayInteractionTelemetryTests {
    @Test
    func metadataAllowlistIsClosedAndContainsNoSensitiveFields() {
        #expect(OverlayInteractionTelemetryRecord.allowedMetadataKeys == [
            "attempt",
            "boundary_clamped",
            "bubble_visible",
            "duration_bucket",
            "event",
            "menu_visible",
            "result",
            "source",
        ])
        let forbiddenFragments = [
            "coordinate", "display", "frame", "message", "path", "payload",
            "pet_id", "session", "text", "title",
        ]
        for key in OverlayInteractionTelemetryRecord.allowedMetadataKeys {
            #expect(!forbiddenFragments.contains(where: { key.contains($0) }))
            #expect(key != "x" && key != "y")
        }
    }

    @Test
    func everyTelemetryDimensionIsAClosedEnumAndAttemptIsBounded() {
        #expect(OverlayInteractionTelemetryEvent.allCases.count == 14)
        #expect(OverlayInteractionTelemetrySource.allCases.count == 3)
        #expect(OverlayInteractionTelemetryResult.allCases.count == 6)
        #expect(OverlayInteractionDurationBucket.allCases.count == 5)
        for attempt in 1 ... 5 {
            #expect(OverlayInteractionTelemetryRecord(
                event: .requestAttempt,
                source: .persistence,
                attempt: UInt8(attempt)
            ).isValid)
        }
        #expect(!OverlayInteractionTelemetryRecord(
            event: .requestAttempt,
            source: .persistence,
            attempt: 0
        ).isValid)
        #expect(!OverlayInteractionTelemetryRecord(
            event: .requestAttempt,
            source: .persistence,
            attempt: 6
        ).isValid)
    }

    @Test(arguments: [
        (0.0, OverlayInteractionDurationBucket.under4MS),
        (3.999, OverlayInteractionDurationBucket.under4MS),
        (4.0, OverlayInteractionDurationBucket.under8MS),
        (8.0, OverlayInteractionDurationBucket.under16MS),
        (16.0, OverlayInteractionDurationBucket.under33MS),
        (33.0, OverlayInteractionDurationBucket.atLeast33MS),
    ])
    func durationBucketsAreDeterministicAndBounded(
        milliseconds: Double,
        expected: OverlayInteractionDurationBucket
    ) {
        #expect(
            OverlayInteractionDurationBucket(milliseconds: milliseconds)
                == expected
        )
    }

    @Test
    func syntheticPerformanceSequenceProducesExactPercentilesAndCounts() throws {
        var accumulator = OverlayInteractionPerformanceAccumulator()
        for value in 1 ... 100 {
            let latencyMS = Double(value)
            accumulator.recordPresentation(
                eventTimestamp: 10,
                appliedAt: 10 + latencyMS / 1_000,
                handlerCPUms: latencyMS / 10,
                refreshIntervalMS: 10
            )
        }
        accumulator.recordRelease(mouseUpAt: 20, stableAt: 20.003)
        accumulator.recordRelease(mouseUpAt: 30, stableAt: 30.009)
        accumulator.recordConvergence(
            commitQueuedAt: 40,
            completedAt: 40.025,
            attemptCount: 1
        )
        accumulator.recordConvergence(
            commitQueuedAt: 50,
            completedAt: 50.075,
            attemptCount: 3
        )

        let summary = accumulator.summary
        #expect(summary.presentationSampleCount == 100)
        #expect(summary.completedInteractionCount == 2)
        #expect(abs((summary.eventToWindowApplyMS?.p50 ?? 0) - 50) < 0.001)
        #expect(abs((summary.eventToWindowApplyMS?.p95 ?? 0) - 95) < 0.001)
        #expect(abs((summary.eventToWindowApplyMS?.p99 ?? 0) - 99) < 0.001)
        #expect(summary.handlerCPUms?.p95 == 9.5)
        #expect(summary.releaseToStableMS?.p50 ?? 0 > 2.99)
        #expect(summary.releaseToStableMS?.p95 ?? 0 > 8.99)
        #expect(summary.commitToConvergenceMS?.p50 ?? 0 > 24.99)
        #expect(summary.commitToConvergenceMS?.p95 ?? 0 > 74.99)
        #expect(summary.attemptCount?.p50 == 1)
        #expect(summary.attemptCount?.p95 == 3)
        #expect(summary.missedDisplayLinkRatio > 0)

        let object = try #require(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(summary)
            ) as? [String: Any]
        )
        #expect(Set(object.keys) == [
            "attempt_count",
            "commit_to_convergence_ms",
            "completed_interaction_count",
            "event_to_window_apply_ms",
            "handler_cpu_ms",
            "missed_display_link_ratio",
            "presentation_sample_count",
            "release_to_stable_ms",
            "schema_version",
        ])
    }

    @Test
    func invalidOrUnboundedPerformanceSamplesAreRejected() {
        var accumulator = OverlayInteractionPerformanceAccumulator()
        accumulator.recordPresentation(
            eventTimestamp: 0,
            appliedAt: 10,
            handlerCPUms: 1,
            refreshIntervalMS: 16
        )
        accumulator.recordPresentation(
            eventTimestamp: 10,
            appliedAt: 9,
            handlerCPUms: 1,
            refreshIntervalMS: 16
        )
        accumulator.recordPresentation(
            eventTimestamp: 10,
            appliedAt: 21,
            handlerCPUms: 1,
            refreshIntervalMS: 16
        )

        #expect(accumulator.summary.presentationSampleCount == 0)
        #expect(accumulator.summary.eventToWindowApplyMS == nil)
        #expect(accumulator.summary.missedDisplayLinkRatio == 0)
    }

    @MainActor
    @Test
    func optInPerformanceSummaryWritesOnlyAggregatedMetrics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apc-overlay-telemetry-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("summary.json")
        let telemetry = OverlayInteractionTelemetry(
            subsystem: "io.github.agent-pet-companion.tests",
            performanceSummaryPath: output.path
        )
        let interactionID = UUID()
        telemetry.pointerDown(
            interactionID: interactionID,
            bubbleVisible: true,
            menuVisible: false
        )
        let now = ProcessInfo.processInfo.systemUptime
        telemetry.thresholdCrossed(interactionID: interactionID)
        telemetry.presentationApplied(
            interactionID: interactionID,
            boundaryClamped: false,
            eventTimestamp: now - 0.001,
            handlerCPUms: 0.25,
            refreshIntervalMS: 16.667
        )
        telemetry.normalMouseUp(interactionID: interactionID)
        telemetry.finalFrameApplied(interactionID: interactionID)
        telemetry.commitQueued(interactionID: interactionID)
        telemetry.requestAttempt(interactionID: interactionID, attempt: 1)
        telemetry.requestResult(
            interactionID: interactionID,
            attempt: 1,
            result: .success
        )
        telemetry.finish(interactionID: interactionID, result: .success)

        for _ in 0 ..< 200 where !FileManager.default.fileExists(
            atPath: output.path
        ) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let object = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: output)
            ) as? [String: Any]
        )
        #expect(object["presentation_sample_count"] as? Int == 1)
        #expect(object["completed_interaction_count"] as? Int == 1)
        let encoded = String(
            decoding: try JSONSerialization.data(withJSONObject: object),
            as: UTF8.self
        )
        for forbidden in [
            "coordinate", "display_id", "frame", "message", "path",
            "payload", "pet_id", "session", "title", "user_text",
        ] {
            #expect(!encoded.contains(forbidden))
        }
    }
}
