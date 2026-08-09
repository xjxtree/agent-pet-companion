import AgentPetCompanionCore
import AppKit
import CoreImage
import Testing
@testable import AgentPetCompanion

@Suite
struct PetFramePipelineTests {
    @Test
    func settledIdleKeepsSemanticProjectionOwnershipAcrossStateChanges() {
        let toolEntryID = "tool:codex:session-a:activation-1"
        let toolPlayback = OverlayPetFrameProjectionIdentity.resolve(
            semanticEntryID: toolEntryID,
            presentsSettledIdle: false
        )
        let toolSettledIdle = OverlayPetFrameProjectionIdentity.resolve(
            semanticEntryID: toolEntryID,
            presentsSettledIdle: true
        )
        let doneEntryID = "done:codex:session-a:activation-1"
        let doneSettledIdle = OverlayPetFrameProjectionIdentity.resolve(
            semanticEntryID: doneEntryID,
            presentsSettledIdle: true
        )

        #expect(toolPlayback.renderEntryID == toolEntryID)
        #expect(toolSettledIdle.renderEntryID == "\(toolEntryID):settled-idle")
        #expect(toolPlayback.semanticOwnerEntryID == toolEntryID)
        #expect(toolSettledIdle.semanticOwnerEntryID == toolEntryID)
        #expect(doneSettledIdle.semanticOwnerEntryID == doneEntryID)
        #expect(doneSettledIdle.semanticOwnerEntryID != toolSettledIdle.semanticOwnerEntryID)

        let localInteraction = OverlayPetFrameProjectionIdentity.resolve(
            semanticEntryID: doneEntryID,
            interactionEntryID: "acknowledge:local-1",
            presentsSettledIdle: true
        )
        #expect(localInteraction.renderEntryID == "acknowledge:local-1")
        #expect(localInteraction.semanticOwnerEntryID == doneEntryID)
    }

    @MainActor
    @Test
    func rendererContentReplayLeavesTheRepresentableUpdateCycle() async {
        let renderer = PetMetalFrameRenderer()
        let view = renderer.makeView()
        var received: [Bool] = []
        let loadRequest = request(
            quality: .low,
            stateName: "idle",
            frameCount: 1
        )

        renderer.configure(
            view: view,
            pet: loadRequest.pet,
            stateName: "idle",
            stateEntryID: "deferred-content-replay",
            active: false,
            reduceMotion: false,
            onVisualEnvelopeChanged: { _ in },
            onFrameContentChanged: { received.append($0) }
        )

        #expect(received.isEmpty)
        await Task.yield()
        #expect(received == [false])
        renderer.dismantlePipeline()
    }

    @Test(arguments: QualityLevel.allCases, [
        PlaybackMatrixFixture(
            name: "loop",
            contract: PlaybackContract(mode: .loop)
        ),
        PlaybackMatrixFixture(
            name: "burst_then_idle",
            contract: PlaybackContract(mode: .burstThenIdle, entryRepeatCount: 2)
        ),
        PlaybackMatrixFixture(
            name: "once_then_return",
            contract: PlaybackContract(mode: .onceThenReturn)
        ),
        PlaybackMatrixFixture(
            name: "periodic",
            contract: PlaybackContract(mode: .periodic, cooldownMS: [4_000, 8_000])
        ),
        PlaybackMatrixFixture(
            name: "burst_then_settle",
            contract: PlaybackContract(
                mode: .burstThenSettle,
                entryRepeatCount: 2,
                settleFrameIndex: 2
            )
        ),
    ])
    func everyQualityAndPlaybackPinsReducedMotionAndStopsBoundaryScheduling(
        quality: QualityLevel,
        fixture: PlaybackMatrixFixture
    ) async throws {
        let pipeline = makePipeline(probe: FrameDecoderProbe(), frameCount: 3)
        let prepared = try await pipeline.prepare(request(
            quality: quality,
            stateName: "matrix-\(fixture.name)",
            frameDurationsMS: [100, 150, 250],
            playback: fixture.contract,
            reducedMotionFrameIndex: 1
        ))
        let handoff = PetFrameRenderHandoff()
        let generation = UUID()
        handoff.begin(
            generation: generation,
            stateID: "\(quality.rawValue):\(fixture.name)",
            enteredAt: 10
        )
        #expect(handoff.publish(prepared, generation: generation))

        #expect(handoff.lookup(at: 10, reducedMotion: false).frame?.hitTestIdentity
            == prepared.readyFrame(at: 0)?.hitTestIdentity)
        #expect(handoff.nextBoundaryDelay(after: 10, reducedMotion: false) != nil)
        for virtualTime in [10.0, 25.0, 70.0] {
            let reduced = handoff.lookup(at: virtualTime, reducedMotion: true)
            #expect(reduced.frame?.hitTestIdentity
                == prepared.readyFrame(at: 1)?.hitTestIdentity)
            #expect(reduced.shouldPauseAfterDraw)
            #expect(handoff.nextBoundaryDelay(
                after: virtualTime,
                reducedMotion: true
            ) == nil)
        }
    }

    @Test
    func reducedMotionPinsPlaybackToRepresentativeFrameAndStopsScheduling() async throws {
        let pipeline = makePipeline(probe: FrameDecoderProbe(), frameCount: 3)
        let prepared = try await pipeline.prepare(request(
            quality: .standard,
            stateName: "tool",
            frameCount: 3,
            reducedMotionFrameIndex: 2
        ))
        let handoff = PetFrameRenderHandoff()
        let generation = UUID()
        handoff.begin(generation: generation, stateID: "tool", enteredAt: 10)
        #expect(handoff.publish(prepared, generation: generation))

        let reduced = handoff.lookup(at: 25, reducedMotion: true)
        #expect(reduced.frame?.hitTestIdentity == prepared.readyFrame(at: 2)?.hitTestIdentity)
        #expect(reduced.shouldPauseAfterDraw)
        #expect(handoff.nextBoundaryDelay(after: 25, reducedMotion: true) == nil)
    }

    @MainActor
    @Test
    func presentationCoordinatorRejectsOutOfOrderDrawableCallbacks() throws {
        let coordinator = PetFramePresentationCoordinator()
        let context = PetFramePresentationContext(
            renderGeneration: UUID(),
            stateEntryID: "tool:session-a"
        )
        coordinator.activate(context)
        let earlier = try #require(coordinator.reserve(for: context))
        let later = try #require(coordinator.reserve(for: context))
        let earlierMask = try presentationHitTest(alpha: 64)
        let laterMask = try presentationHitTest(alpha: 255)

        #expect(later.sequence > earlier.sequence)
        #expect(coordinator.resolve(
            .presented(laterMask),
            token: later
        ) == .publish(laterMask))
        #expect(coordinator.resolve(
            .presented(earlierMask),
            token: earlier
        ) == .rejected)
        #expect(coordinator.snapshot.hitTest == laterMask)
        #expect(coordinator.snapshot.latestAcceptedSequence == later.sequence)
    }

    @MainActor
    @Test
    func presentationCoordinatorRejectsOldStateCallbacksWhenGenerationIsReused() throws {
        let coordinator = PetFramePresentationCoordinator()
        let reusedGeneration = UUID()
        let oldContext = PetFramePresentationContext(
            renderGeneration: reusedGeneration,
            stateEntryID: "tool:session-a:activation-1"
        )
        coordinator.activate(oldContext)
        let stale = try #require(coordinator.reserve(for: oldContext))

        coordinator.invalidate()
        let currentContext = PetFramePresentationContext(
            renderGeneration: reusedGeneration,
            stateEntryID: "tool:session-b:activation-2"
        )
        coordinator.activate(currentContext)
        let current = try #require(coordinator.reserve(for: currentContext))
        let staleMask = try presentationHitTest(alpha: 64)
        let currentMask = try presentationHitTest(alpha: 255)

        #expect(current.epoch > stale.epoch)
        #expect(current.sequence > stale.sequence)
        #expect(coordinator.reserve(for: oldContext) == nil)
        #expect(coordinator.resolve(
            .presented(staleMask),
            token: stale
        ) == .rejected)
        #expect(coordinator.resolve(
            .presented(currentMask),
            token: current
        ) == .publish(currentMask))
    }

    @MainActor
    @Test
    func rendererSuspensionInvalidatesLatePresentedCallbacks() throws {
        let coordinator = PetFramePresentationCoordinator()
        let context = PetFramePresentationContext(
            renderGeneration: UUID(),
            stateEntryID: "waiting:session-a"
        )
        coordinator.activate(context)
        let inFlight = try #require(coordinator.reserve(for: context))
        let mask = try presentationHitTest(alpha: 255)
        let activeEpoch = coordinator.snapshot.epoch

        // PetMetalFrameRenderer uses invalidation for hide, dismantle, and
        // explicit lifecycle suspension.
        coordinator.invalidate()

        #expect(coordinator.snapshot.epoch > activeEpoch)
        #expect(coordinator.snapshot.context == nil)
        #expect(coordinator.snapshot.hitTest == nil)
        #expect(coordinator.resolve(
            .presented(mask),
            token: inFlight
        ) == .rejected)
    }

    @MainActor
    @Test
    func finiteFinalFrameMayPublishAfterBoundarySchedulerStops() throws {
        let coordinator = PetFramePresentationCoordinator()
        let context = PetFramePresentationContext(
            renderGeneration: UUID(),
            stateEntryID: "done:session-a:activation-1"
        )
        coordinator.activate(context)
        let finalSubmission = try #require(coordinator.reserve(for: context))
        let finalMask = try presentationHitTest(alpha: 255)

        // Stopping boundary scheduling after submitting the settle frame is
        // not renderer suspension, so its presented callback stays valid.
        #expect(coordinator.resolve(
            .presented(finalMask),
            token: finalSubmission
        ) == .publish(finalMask))
        #expect(coordinator.snapshot.hitTest == finalMask)
    }

    @MainActor
    @Test
    func replacementHandlerReplaysOnlyTheLastAcceptedPresentation() throws {
        let coordinator = PetFramePresentationCoordinator()
        let context = PetFramePresentationContext(
            renderGeneration: UUID(),
            stateEntryID: "tool:handler-replacement"
        )
        coordinator.activate(context)
        let submission = try #require(coordinator.reserve(for: context))
        let presentedMask = try presentationHitTest(alpha: 255)
        #expect(coordinator.resolve(
            .presented(presentedMask),
            token: submission
        ) == .publish(presentedMask))

        var replayed: [OverlayPetFrameHitTest?] = []
        coordinator.replayCurrent { replayed.append($0) }

        #expect(replayed == [presentedMask])
    }

    @MainActor
    @Test
    func presentedNilMaskAdvancesSequenceAndBlocksOlderMask() throws {
        let coordinator = PetFramePresentationCoordinator()
        let context = PetFramePresentationContext(
            renderGeneration: UUID(),
            stateEntryID: "tool:transparent-frame"
        )
        coordinator.activate(context)
        let opaqueSubmission = try #require(coordinator.reserve(for: context))
        let transparentSubmission = try #require(coordinator.reserve(for: context))
        let opaqueMask = try presentationHitTest(alpha: 255)

        #expect(coordinator.resolve(
            .presented(opaqueMask),
            token: opaqueSubmission
        ) == .publish(opaqueMask))
        #expect(coordinator.resolve(
            .presented(nil),
            token: transparentSubmission
        ) == PetFramePresentationDecision.publish(nil))
        #expect(coordinator.snapshot.hitTest == nil)
        #expect(coordinator.snapshot.latestAcceptedSequence == transparentSubmission.sequence)
        #expect(coordinator.resolve(
            .presented(opaqueMask),
            token: opaqueSubmission
        ) == .rejected)
    }

    @MainActor
    @Test
    func gpuFailureDoesNotSupersedeTheLastActuallyPresentedMask() throws {
        let coordinator = PetFramePresentationCoordinator()
        let context = PetFramePresentationContext(
            renderGeneration: UUID(),
            stateEntryID: "tool:gpu-failure"
        )
        coordinator.activate(context)
        let first = try #require(coordinator.reserve(for: context))
        let presentedBeforeFailure = try #require(coordinator.reserve(for: context))
        let failed = try #require(coordinator.reserve(for: context))
        let firstMask = try presentationHitTest(alpha: 255)
        let nextPresentedMask = try presentationHitTest(alpha: 64)

        #expect(coordinator.resolve(
            .presented(firstMask),
            token: first
        ) == .publish(firstMask))
        #expect(coordinator.resolve(.failed, token: failed)
            == .acceptedUnchanged)
        #expect(coordinator.snapshot.hitTest == firstMask)
        #expect(coordinator.snapshot.latestAcceptedSequence == first.sequence)
        // A failure callback may reach MainActor before an earlier drawable's
        // presented callback. Failure therefore cannot advance the presented
        // sequence or suppress that real presentation.
        #expect(coordinator.resolve(
            .presented(nextPresentedMask),
            token: presentedBeforeFailure
        ) == .publish(nextPresentedMask))
        #expect(coordinator.snapshot.hitTest == nextPresentedMask)
        #expect(coordinator.snapshot.latestAcceptedSequence == presentedBeforeFailure.sequence)
    }

    @Test
    func testDrawLookupNeverReadsDisk() async throws {
        let probe = FrameDecoderProbe()
        let pipeline = makePipeline(probe: probe, frameCount: 3)
        let prepared = try await pipeline.prepare(request(
            quality: .standard,
            stateName: "tool",
            frameCount: 3
        ))
        let readsAfterPrepare = probe.decodeCount

        for index in 0..<20 {
            _ = prepared.readyFrame(at: index % 3)
        }

        #expect(probe.decodeCount == readsAfterPrepare)
    }

    @MainActor
    @Test
    func testDecodeWorkIsNotMainActor() async throws {
        let probe = FrameDecoderProbe()
        let pipeline = makePipeline(probe: probe, frameCount: 2)

        _ = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))

        #expect(!probe.didDecodeOnMainThread)
    }

    @Test
    func testLRURespectsByteBudget() async throws {
        let probe = FrameDecoderProbe(pixelWidth: 2, pixelHeight: 2)
        let pipeline = makePipeline(
            probe: probe,
            frameCount: 6,
            memoryBudgetBytes: 32
        )

        _ = try await pipeline.prepare(request(
            quality: .standard,
            stateName: "tool",
            frameCount: 6
        ))
        let metrics = await pipeline.cacheMetrics()

        #expect(metrics.byteCount <= 32)
        #expect(metrics.frameCount <= 2)
        #expect(metrics.maximumConcurrentDecodes <= 1)
    }

    @Test
    func everyQualityTierEagerlyDecodesEveryAuthoredFrameWithoutSampling() async throws {
        for quality in QualityLevel.allCases {
            let probe = FrameDecoderProbe()
            let pipeline = makePipeline(probe: probe, frameCount: 8)
            let prepared = try await pipeline.prepare(request(
                quality: quality,
                stateName: "tool",
                frameCount: 8
            ))

            #expect(prepared.sourceKind == .eager)
            #expect(prepared.sourceFrameCount == 8)
            #expect(prepared.frameCount == 8)
            #expect(prepared.readyFrameCount == 8)
            #expect(probe.decodeCount == 8)
            #expect(probe.decodedPaths == (0..<8).map { "/virtual/frame-\($0).png" })
        }
    }

    @Test
    func mismatchedAuthoredTimingAndAssetCountIsRejected() async throws {
        let pipeline = makePipeline(probe: FrameDecoderProbe(), frameCount: 3)

        do {
            _ = try await pipeline.prepare(request(
                quality: .standard,
                stateName: "tool",
                frameCount: 4
            ))
            Issue.record("expected mismatched authored timing to be rejected")
        } catch let error as PetFramePipelineError {
            #expect(error == .frameCountMismatch(expected: 4, actual: 3))
        }
    }

    @Test
    func burstThenSettleUsesTheAuthoredSettleFrame() async throws {
        let pipeline = makePipeline(probe: FrameDecoderProbe(), frameCount: 4)
        let prepared = try await pipeline.prepare(request(
            quality: .standard,
            stateName: "done",
            frameDurationsMS: [100, 150, 200, 250],
            playback: PlaybackContract(
                mode: .burstThenSettle,
                entryRepeatCount: 1,
                settleFrameIndex: 2
            )
        ))
        let handoff = PetFrameRenderHandoff()
        let generation = UUID()
        handoff.begin(generation: generation, stateID: "done:first", enteredAt: 10)
        #expect(handoff.publish(prepared, generation: generation))

        let terminal = handoff.lookup(at: 10.71, reducedMotion: false)
        #expect(terminal.frame?.hitTestIdentity == prepared.readyFrame(at: 2)?.hitTestIdentity)
        #expect(terminal.shouldPauseAfterDraw)
        #expect(handoff.nextBoundaryDelay(after: 10.71, reducedMotion: false) == nil)

        handoff.holdTerminalFrame(stateID: "done:seen-again")
        let held = handoff.lookup(at: 10, reducedMotion: false)
        #expect(held.frame?.hitTestIdentity == prepared.readyFrame(at: 2)?.hitTestIdentity)
    }

    @Test
    func periodicCooldownHoldsRepresentativeFrameWithoutBusyDrawing() async throws {
        let pipeline = makePipeline(probe: FrameDecoderProbe(), frameCount: 3)
        let prepared = try await pipeline.prepare(request(
            quality: .standard,
            stateName: "idle",
            frameDurationsMS: [100, 150, 250],
            playback: PlaybackContract(mode: .periodic, cooldownMS: [500, 500]),
            reducedMotionFrameIndex: 1
        ))
        let handoff = PetFrameRenderHandoff()
        let generation = UUID()
        handoff.begin(generation: generation, stateID: "idle", enteredAt: 10)
        #expect(handoff.publish(prepared, generation: generation))

        let cooldown = handoff.lookup(at: 10.7, reducedMotion: false)
        #expect(cooldown.frame?.hitTestIdentity == prepared.readyFrame(at: 1)?.hitTestIdentity)
        let delay = try #require(handoff.nextBoundaryDelay(after: 10.7, reducedMotion: false))
        #expect(delay > 0.299 && delay < 0.302)
    }

    @Test
    func periodicCooldownSamplesOncePerCycleAndStallResolvesCurrentFrame() async throws {
        let cooldowns = PeriodicCooldownSequence(values: [500, 800, 600])
        let pipeline = makePipeline(
            probe: FrameDecoderProbe(),
            frameCount: 2,
            periodicCooldownSampler: { range in cooldowns.next(in: range) }
        )
        let prepared = try await pipeline.prepare(request(
            quality: .standard,
            stateName: "idle",
            frameDurationsMS: [100, 100],
            playback: PlaybackContract(mode: .periodic, cooldownMS: [500, 800]),
            reducedMotionFrameIndex: 1
        ))
        let handoff = PetFrameRenderHandoff()
        let generation = UUID()
        handoff.begin(generation: generation, stateID: "idle", enteredAt: 0)
        #expect(handoff.publish(prepared, generation: generation))

        let firstCooldown = handoff.lookup(at: 0.25, reducedMotion: false)
        #expect(firstCooldown.frame?.hitTestIdentity
            == prepared.readyFrame(at: 1)?.hitTestIdentity)
        _ = handoff.lookup(at: 0.4, reducedMotion: false)
        _ = handoff.nextBoundaryDelay(after: 0.4, reducedMotion: false)
        #expect(cooldowns.snapshot() == [500])

        let secondCycle = handoff.lookup(at: 0.701, reducedMotion: false)
        #expect(secondCycle.frame?.hitTestIdentity
            == prepared.readyFrame(at: 0)?.hitTestIdentity)
        _ = handoff.lookup(at: 1.2, reducedMotion: false)
        #expect(cooldowns.snapshot() == [500, 800])

        // One lookup after a long stall samples skipped cycle cooldowns only
        // to resolve wall-clock phase; it returns the currently due frame and
        // never asks the renderer to replay the missed authored boundaries.
        let afterStall = handoff.lookup(at: 1.75, reducedMotion: false)
        #expect(afterStall.frame?.hitTestIdentity
            == prepared.readyFrame(at: 0)?.hitTestIdentity)
        _ = handoff.nextBoundaryDelay(after: 1.8, reducedMotion: false)
        #expect(cooldowns.snapshot() == [500, 800, 600])
    }

    @Test
    func fixedPeriodicCooldownFastForwardsADayInConstantWork() async throws {
        let cooldowns = PeriodicCooldownCounter(value: 0)
        let pipeline = makePipeline(
            probe: FrameDecoderProbe(),
            frameCount: 2,
            periodicCooldownSampler: { range in cooldowns.next(in: range) }
        )
        let prepared = try await pipeline.prepare(request(
            quality: .standard,
            stateName: "idle",
            frameDurationsMS: [50, 50],
            playback: PlaybackContract(mode: .periodic, cooldownMS: [0, 0])
        ))
        let handoff = PetFrameRenderHandoff()
        let generation = UUID()
        handoff.begin(generation: generation, stateID: "idle", enteredAt: 0)
        #expect(handoff.publish(prepared, generation: generation))

        let afterOneDay = handoff.lookup(at: 86_400, reducedMotion: false)
        #expect(afterOneDay.frame?.hitTestIdentity
            == prepared.readyFrame(at: 0)?.hitTestIdentity)
        _ = handoff.nextBoundaryDelay(after: 86_400, reducedMotion: false)

        // A degenerate authored range has no random choices to instantiate.
        #expect(cooldowns.sampleCount <= 1)
    }

    @Test
    func variablePeriodicCooldownBoundsSamplingWorkAfterALongStall() async throws {
        let cooldowns = PeriodicCooldownCounter(value: 0)
        let pipeline = makePipeline(
            probe: FrameDecoderProbe(),
            frameCount: 2,
            periodicCooldownSampler: { range in cooldowns.next(in: range) }
        )
        let prepared = try await pipeline.prepare(request(
            quality: .standard,
            stateName: "idle",
            frameDurationsMS: [50, 50],
            playback: PlaybackContract(mode: .periodic, cooldownMS: [0, 1])
        ))
        let handoff = PetFrameRenderHandoff()
        let generation = UUID()
        handoff.begin(generation: generation, stateID: "idle", enteredAt: 0)
        #expect(handoff.publish(prepared, generation: generation))

        _ = handoff.lookup(at: 86_400, reducedMotion: false)
        let samplesAfterStall = cooldowns.sampleCount
        _ = handoff.lookup(at: 86_400, reducedMotion: false)
        _ = handoff.nextBoundaryDelay(after: 86_400, reducedMotion: false)

        // The renderer lock may inspect a small bounded prefix, then it must
        // re-anchor instead of materializing every missed random cycle.
        #expect(samplesAfterStall <= 10)
        #expect(cooldowns.sampleCount == samplesAfterStall)
    }

    @Test
    func sixtySecondPeriodicIdleRequestsOnlyAuthoredBoundaryDraws() async throws {
        let idle = try #require(PetAnimationContract.defaultStates.first {
            $0.name == "idle"
        })
        let cooldownMS = try #require(idle.playback.cooldownMS)
        try #require(cooldownMS.count == 2)
        let sampledCooldownMS = cooldownMS[0] + (cooldownMS[1] - cooldownMS[0]) / 2
        let pipeline = makePipeline(
            probe: FrameDecoderProbe(),
            frameCount: idle.frameDurationsMS.count,
            periodicCooldownSampler: { range in
                range.lowerBound + (range.upperBound - range.lowerBound) / 2
            }
        )
        let prepared = try await pipeline.prepare(request(
            quality: .standard,
            stateName: idle.name,
            frameDurationsMS: idle.frameDurationsMS,
            playback: idle.playback,
            reducedMotionFrameIndex: idle.reducedMotionFrameIndex
        ))
        let handoff = PetFrameRenderHandoff()
        let generation = UUID()
        handoff.begin(generation: generation, stateID: "idle", enteredAt: 0)
        #expect(handoff.publish(prepared, generation: generation))

        // One periodic cycle wakes once per authored frame and once when the
        // cooldown hold ends. Deriving the schedule from the authored contract
        // keeps this a statement about playback behavior instead of a snapshot
        // of whichever idle timing the default pet currently ships.
        let authoredIntervalsMS = idle.frameDurationsMS + [sampledCooldownMS]
        var expectedBoundaryDraws = 0
        var referenceMS = 0.0
        reference: while true {
            for intervalMS in authoredIntervalsMS {
                referenceMS += Double(intervalMS)
                guard referenceMS <= 60_000 else { break reference }
                expectedBoundaryDraws += 1
            }
        }

        var virtualTime = 0.0
        var scheduledBoundaryDraws = 0
        var unauthoredDelaysMS: [Double] = []
        while scheduledBoundaryDraws < 1_000 {
            let delay = try #require(handoff.nextBoundaryDelay(
                after: virtualTime,
                reducedMotion: false
            ))
            // Each wake re-anchors on the next authored boundary and only adds
            // the sub-millisecond guard against an early duplicate draw, so an
            // unauthored intermediate draw shows up as a mismatched delay.
            let expectedMS = Double(
                authoredIntervalsMS[scheduledBoundaryDraws % authoredIntervalsMS.count]
            )
            if abs(delay * 1_000 - expectedMS) > 1 {
                unauthoredDelaysMS.append(delay * 1_000)
            }
            virtualTime += delay
            guard virtualTime <= 60 else { break }
            scheduledBoundaryDraws += 1
        }

        #expect(unauthoredDelaysMS.isEmpty)
        #expect(scheduledBoundaryDraws == expectedBoundaryDraws)
        // The initial presentation plus the authored boundary wakes stays two
        // orders of magnitude below a continuously running 60 Hz display link
        // (3,600 draws in the same window).
        #expect(1 + scheduledBoundaryDraws < 360)
        #expect(handoff.nextBoundaryDelay(after: 60, reducedMotion: true) == nil)
    }

    @Test
    func shippedToolActionDrawsEveryAuthoredPassOfItsEntryBurst() async throws {
        let tool = try #require(PetAnimationContract.defaultStates.first {
            $0.name == "tool"
        })
        try #require(tool.playback.mode == .burstThenIdle)
        let repeats = try #require(tool.playback.entryRepeatCount)
        let pipeline = makePipeline(
            probe: FrameDecoderProbe(),
            frameCount: tool.frameDurationsMS.count
        )
        let prepared = try await pipeline.prepare(request(
            quality: .standard,
            stateName: tool.name,
            frameDurationsMS: tool.frameDurationsMS,
            playback: tool.playback,
            reducedMotionFrameIndex: tool.reducedMotionFrameIndex
        ))
        let handoff = PetFrameRenderHandoff()
        let generation = UUID()
        handoff.begin(generation: generation, stateID: "tool", enteredAt: 0)
        #expect(handoff.publish(prepared, generation: generation))

        func presentedFrameIndex(at virtualTime: TimeInterval) -> Int? {
            let identity = handoff.lookup(
                at: virtualTime,
                reducedMotion: false
            ).frame?.hitTestIdentity
            return tool.frameDurationsMS.indices.first {
                prepared.readyFrame(at: $0)?.hitTestIdentity == identity
            }
        }

        // Walk the schedule the renderer actually asks for and record every
        // frame it presents, so this measures drawn playback rather than the
        // timeline arithmetic behind it.
        var presented: [Int] = []
        var virtualTime = 0.0
        while presented.count < 100 {
            let index = try #require(presentedFrameIndex(at: virtualTime))
            if presented.last != index {
                presented.append(index)
            }
            guard let delay = handoff.nextBoundaryDelay(
                after: virtualTime,
                reducedMotion: false
            ) else { break }
            virtualTime += delay
        }

        let onePass = Array(tool.frameDurationsMS.indices)
        #expect(presented == (0..<repeats).flatMap { _ in onePass })
        let burstDurationMS = tool.frameDurationsMS.reduce(0, +) * repeats
        #expect(abs(virtualTime * 1_000 - Double(burstDurationMS)) < 1)

        // The burst ends on its own instead of freezing mid-animation, which is
        // where the overlay hands the pet back to idle for the rest of the lease.
        #expect(!handoff.lookup(
            at: Double(burstDurationMS) / 1_000 - 0.001,
            reducedMotion: false
        ).shouldPauseAfterDraw)
        let settled = handoff.lookup(at: Double(burstDurationMS) / 1_000, reducedMotion: false)
        #expect(settled.shouldPauseAfterDraw)
        #expect(settled.frame?.hitTestIdentity
            == prepared.readyFrame(at: tool.frameDurationsMS.count - 1)?.hitTestIdentity)
        #expect(handoff.nextBoundaryDelay(
            after: Double(burstDurationMS) / 1_000,
            reducedMotion: false
        ) == nil)
    }

    @Test
    func burstThenSettleSkipsMissedFramesAfterAStall() async throws {
        let pipeline = makePipeline(probe: FrameDecoderProbe(), frameCount: 4)
        let prepared = try await pipeline.prepare(request(
            quality: .standard,
            stateName: "thinking",
            frameDurationsMS: [100, 200, 100, 200],
            playback: PlaybackContract(
                mode: .burstThenSettle,
                entryRepeatCount: 2,
                settleFrameIndex: 1
            )
        ))
        let handoff = PetFrameRenderHandoff()
        let generation = UUID()
        handoff.begin(generation: generation, stateID: "start", enteredAt: 10)
        #expect(handoff.publish(prepared, generation: generation))

        let afterStall = handoff.lookup(at: 10.95, reducedMotion: false)
        #expect(afterStall.frame?.hitTestIdentity == prepared.readyFrame(at: 2)?.hitTestIdentity)

        let settled = handoff.lookup(at: 11.21, reducedMotion: false)
        #expect(settled.frame?.hitTestIdentity == prepared.readyFrame(at: 1)?.hitTestIdentity)
        #expect(settled.shouldPauseAfterDraw)
        #expect(handoff.nextBoundaryDelay(after: 11.21, reducedMotion: false) == nil)
    }

    @Test
    func testPreparedFramesExposeStableUnionOfVisibleActionBounds() async throws {
        let urls = (0..<2).map { URL(fileURLWithPath: "/virtual/visible-\($0).png") }
        let pipeline = PetFramePipeline(
            memoryBudgetBytes: 1_024 * 1_024,
            catalog: { _, _ in PetFrameAssetCatalog(frameURLs: urls, coverURL: nil) },
            decoder: { url in
                let index = url.deletingPathExtension().lastPathComponent.hasSuffix("1") ? 1 : 0
                let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 120))
                return PetDecodedFrame(
                    image: image,
                    pixelWidth: 100,
                    pixelHeight: 120,
                    visibleBounds: index == 0
                        ? CGRect(x: 10, y: 15, width: 70, height: 80)
                        : CGRect(x: 20, y: 5, width: 65, height: 110)
                )
            }
        )

        let prepared = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))

        #expect(prepared.visualEnvelope == OverlayPetVisualEnvelope(
            canvasSize: CGSize(width: 100, height: 120),
            visibleBounds: CGRect(x: 10, y: 5, width: 75, height: 110)
        ))
    }

    @Test
    func testPlaybackRestartKeepsPreparedFramesAndGeneration() async throws {
        let pipeline = makePipeline(probe: FrameDecoderProbe(), frameCount: 2)
        let prepared = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))
        let handoff = PetFrameRenderHandoff()
        let generation = UUID()

        handoff.begin(generation: generation, stateID: "tool:first", enteredAt: 10)
        #expect(handoff.publish(prepared, generation: generation))
        #expect(handoff.lookup(at: 10, reducedMotion: false).frame != nil)

        handoff.restartPlayback(stateID: "tool:second", enteredAt: 20)
        let restarted = handoff.lookup(at: 20, reducedMotion: false)

        #expect(restarted.generation == generation)
        #expect(restarted.frame != nil)
    }

    @Test
    func finitePlaybackDoesNotReplayAfterCanonicalABARotation() {
        var history = PetPlaybackEntryHistory(capacity: 8)
        let sessionA = "done:codex:session-a:activation-1"
        let sessionB = "done:codex:session-b:activation-1"

        #expect(history.transition(to: sessionA, playbackMode: .burstThenIdle).shouldRestartPlayback)
        #expect(history.transition(to: sessionB, playbackMode: .burstThenIdle).shouldRestartPlayback)

        let rotatedBack = history.transition(to: sessionA, playbackMode: .burstThenIdle)
        #expect(rotatedBack.isNewEntry)
        #expect(!rotatedBack.shouldRestartPlayback)
    }

    @Test
    func finitePlaybackReplaysForGenuineNewActivation() {
        var history = PetPlaybackEntryHistory(capacity: 8)
        let firstActivation = "done:codex:session-a:activation-1"
        let otherSession = "done:codex:session-b:activation-1"
        let nextActivation = "done:codex:session-a:activation-2"

        #expect(history.transition(
            to: firstActivation,
            playbackMode: .burstThenSettle
        ).shouldRestartPlayback)
        #expect(history.transition(
            to: otherSession,
            playbackMode: .burstThenSettle
        ).shouldRestartPlayback)
        #expect(history.transition(to: firstActivation, playbackMode: .burstThenSettle).isNewEntry)
        #expect(history.transition(
            to: nextActivation,
            playbackMode: .burstThenSettle
        ).shouldRestartPlayback)
    }

    @Test
    func testLoopingPlaybackRetainsCurrentEntryRestartSemantics() {
        var history = PetPlaybackEntryHistory(capacity: 8)

        #expect(history.transition(to: "tool", playbackMode: .loop).shouldRestartPlayback)
        let duplicate = history.transition(to: "tool", playbackMode: .loop)
        #expect(!duplicate.isNewEntry)
        #expect(!duplicate.shouldRestartPlayback)
        #expect(history.transition(to: "waiting", playbackMode: .loop).shouldRestartPlayback)
        #expect(history.transition(to: "tool", playbackMode: .loop).shouldRestartPlayback)
    }

    @Test
    func testPeriodicPlaybackRetainsRepeatingEntrySemantics() {
        var history = PetPlaybackEntryHistory(capacity: 8)

        #expect(history.transition(
            to: "start:session-a",
            playbackMode: .periodic
        ).shouldRestartPlayback)
        #expect(history.transition(
            to: "start:session-b",
            playbackMode: .periodic
        ).shouldRestartPlayback)
        #expect(history.transition(
            to: "start:session-a",
            playbackMode: .periodic
        ).shouldRestartPlayback)
    }

    @Test
    func finitePlaybackHistoryIsBounded() {
        var history = PetPlaybackEntryHistory(capacity: 2)

        #expect(history.transition(to: "done:a:1", playbackMode: .burstThenIdle).shouldRestartPlayback)
        #expect(history.transition(to: "done:b:1", playbackMode: .burstThenIdle).shouldRestartPlayback)
        #expect(history.transition(to: "done:c:1", playbackMode: .burstThenIdle).shouldRestartPlayback)
        #expect(history.transition(to: "done:a:1", playbackMode: .burstThenIdle).shouldRestartPlayback)
    }

    @Test
    func testAlphaVisibleBoundsFindsOnlyOpaquePixels() throws {
        let width = 8
        let height = 10
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
        let image = rgba.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 2, y: 3, width: 4, height: 5))
            return context.makeImage()
        }
        let decoded = try #require(image)

        #expect(PetFramePipeline.alphaVisibleBounds(of: decoded) == CGRect(
            x: 2,
            y: 3,
            width: 4,
            height: 5
        ))
    }

    @Test
    func alphaHitMaskPreservesTransparentHolesThresholdAndBottomLeftLookup() throws {
        let width = 3
        let height = 2
        // CGImage provider rows are top-to-bottom. Alpha 2 is deliberately at
        // the interaction threshold and must remain click-through; alpha 3 is
        // the first value considered interactive.
        let alphaRows: [UInt8] = [
            0, 2, 3,
            255, 0, 1,
        ]
        var rgba: [UInt8] = []
        for alpha in alphaRows {
            rgba.append(contentsOf: [0, 0, 0, alpha])
        }
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let image = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let mask = try #require(PetFramePipeline.alphaHitTestMask(of: image))

        #expect(mask.storageByteCount == 1)
        #expect(mask.containsOpaquePixel(atBottomLeftPoint: CGPoint(x: 0.5, y: 0.5)))
        #expect(mask.containsOpaquePixel(atBottomLeftPoint: CGPoint(x: 2.5, y: 1.5)))
        #expect(!mask.containsOpaquePixel(atBottomLeftPoint: CGPoint(x: 1.5, y: 1.5)))
        #expect(!mask.containsOpaquePixel(atBottomLeftPoint: CGPoint(x: 2.5, y: 0.5)))
        #expect(!mask.containsOpaquePixel(atBottomLeftPoint: CGPoint(x: -0.1, y: 0.5)))
        #expect(!mask.containsOpaquePixel(atBottomLeftPoint: CGPoint(x: 3, y: 0.5)))
    }

    @Test
    func playbackLookupAdvancesTheAlphaMaskWithThePresentedAnimationFrame() async throws {
        let urls = (0..<2).map { URL(fileURLWithPath: "/virtual/mask-frame-\($0).png") }
        let pipeline = PetFramePipeline(
            memoryBudgetBytes: 1_024,
            catalog: { _, _ in PetFrameAssetCatalog(frameURLs: urls, coverURL: nil) },
            decoder: { url in
                let second = url.lastPathComponent.contains("frame-1")
                let mask = OverlayPetAlphaMask(
                    pixelWidth: 1,
                    pixelHeight: 1,
                    alphaValuesTopToBottom: [second ? 255 : 0]
                )
                return PetDecodedFrame(
                    image: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)),
                    pixelWidth: 1,
                    pixelHeight: 1,
                    alphaMask: mask
                )
            }
        )
        let prepared = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))
        let handoff = PetFrameRenderHandoff()
        let generation = UUID()
        handoff.begin(generation: generation, stateID: "tool", enteredAt: 10)
        #expect(handoff.publish(prepared, generation: generation))

        let first = try #require(handoff.lookup(at: 10, reducedMotion: false).frameHitTest)
        let second = try #require(handoff.lookup(
            at: 10.101,
            reducedMotion: false
        ).frameHitTest)

        #expect(first.frameID != second.frameID)
        #expect(!first.alphaMask.containsOpaquePixel(atBottomLeftPoint: CGPoint(x: 0.5, y: 0.5)))
        #expect(second.alphaMask.containsOpaquePixel(atBottomLeftPoint: CGPoint(x: 0.5, y: 0.5)))
    }

    @Test
    func testPreparingAnotherStateDropsStaleDecodedNamespaces() async throws {
        let probe = FrameDecoderProbe(pixelWidth: 2, pixelHeight: 2)
        let pipeline = makePipeline(
            probe: probe,
            frameCount: 3,
            memoryBudgetBytes: 1_024
        )

        _ = try await pipeline.prepare(request(
            quality: .standard,
            stateName: "idle",
            frameCount: 3
        ))
        let firstMetrics = await pipeline.cacheMetrics()
        let prepared = try await pipeline.prepare(request(
            quality: .standard,
            stateName: "tool",
            frameCount: 3
        ))
        let secondMetrics = await pipeline.cacheMetrics()

        #expect(firstMetrics.frameCount == 3)
        #expect(secondMetrics.frameCount == 3)
        #expect(secondMetrics.byteCount == prepared.estimatedReadyBytes)
    }

    @Test
    func testTelemetryIncludesTrackedDecodedCacheMetrics() async throws {
        let probe = FrameDecoderProbe(pixelWidth: 4, pixelHeight: 5)
        let pipeline = makePipeline(probe: probe, frameCount: 2)
        let prepared = try await pipeline.prepare(request(quality: .standard, stateName: "tool"))
        let cacheMetrics = await pipeline.cacheMetrics()

        let telemetry = PetRendererTelemetry(
            prepared: prepared,
            active: true,
            cacheMetrics: cacheMetrics
        )

        #expect(telemetry.readyDecodedBytes == 160)
        #expect(telemetry.readyDecodedFrameCount == 2)
        #expect(telemetry.pipelineCacheBytes == 160)
        #expect(telemetry.pipelineCacheFrameCount == 2)
        #expect(telemetry.frameDurationsMS == [100, 100])
        #expect(telemetry.totalDurationMS == 200)
        #expect(telemetry.playbackMode == PetPlaybackMode.loop.rawValue)
        #expect(telemetry.reducedMotionFrameIndex == 0)
        #expect(telemetry.sourceFrameCount == 2)
        #expect(telemetry.frameCount == 2)
    }

    @MainActor
    @Test
    func testPointerTrackingPreDispatchesMouseDownWithoutEagerPolling() {
        let monitor = OverlayPointerEventMonitor()

        #expect(!monitor.usesPolling)
        #expect(OverlayPointerEventMonitor.eventMask.contains(.mouseMoved))
        #expect(OverlayPointerEventMonitor.eventMask.contains(.leftMouseDown))
        #expect(OverlayPointerEventMonitor.eventMask.contains(.leftMouseUp))
        #expect(OverlayPointerEventMonitor.preDispatchEventTypes.contains(.leftMouseDown))
        #expect(!OverlayPointerEventMonitor.eventMask.contains(.leftMouseDragged))
        #expect(!monitor.isRunning)
    }

    private func makePipeline(
        probe: FrameDecoderProbe,
        frameCount: Int,
        memoryBudgetBytes: Int = 1_024 * 1_024,
        periodicCooldownSampler: @escaping PetFramePipeline.PeriodicCooldownSampler = {
            Int.random(in: $0)
        }
    ) -> PetFramePipeline {
        let urls = (0..<frameCount).map { URL(fileURLWithPath: "/virtual/frame-\($0).png") }
        return PetFramePipeline(
            memoryBudgetBytes: memoryBudgetBytes,
            catalog: { _, _ in PetFrameAssetCatalog(frameURLs: urls, coverURL: nil) },
            decoder: { url in probe.decode(url) },
            periodicCooldownSampler: periodicCooldownSampler
        )
    }

    private func request(
        quality: QualityLevel,
        stateName: String,
        frameCount: Int = 2,
        frameDurationsMS: [Int]? = nil,
        playback: PlaybackContract = PlaybackContract(mode: .loop),
        reducedMotionFrameIndex: Int = 0
    ) -> PetFrameLoadRequest {
        let durations = frameDurationsMS
            ?? [Int](repeating: 100, count: frameCount)
        let timing = PetStateTiming(
            name: stateName,
            framesDir: "assets/frames/\(stateName)",
            frameDurationsMS: durations,
            playback: playback,
            reducedMotionFrameIndex: reducedMotionFrameIndex
        )
        return PetFrameLoadRequest(
            pet: PetSummary(
                id: "pet_test",
                name: "Test",
                style: "pixel",
                quality: quality,
                renderSize: quality.renderSize,
                petpackPath: "/virtual/test.petpack",
                coverPath: "",
                active: true,
                createdAt: "2026-07-10T00:00:00Z"
            ),
            stateName: stateName,
            timing: timing
        )
    }

    private func presentationHitTest(alpha: UInt8) throws -> OverlayPetFrameHitTest {
        let mask = try #require(OverlayPetAlphaMask(
            pixelWidth: 1,
            pixelHeight: 1,
            alphaValuesTopToBottom: [alpha]
        ))
        return OverlayPetFrameHitTest(
            canvasSize: CGSize(width: 1, height: 1),
            alphaMask: mask
        )
    }
}

struct PlaybackMatrixFixture: Sendable, CustomTestStringConvertible {
    let name: String
    let contract: PlaybackContract

    var testDescription: String { name }
}

private final class FrameDecoderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let pixelWidth: Int
    private let pixelHeight: Int
    private var _decodeCount = 0
    private var _didDecodeOnMainThread = false
    private var _decodedPaths: [String] = []

    init(pixelWidth: Int = 2, pixelHeight: Int = 2) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    var decodeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _decodeCount
    }

    var didDecodeOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _didDecodeOnMainThread
    }

    var decodedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _decodedPaths
    }

    func decode(_ url: URL) -> PetDecodedFrame? {
        lock.lock()
        _decodeCount += 1
        _didDecodeOnMainThread = _didDecodeOnMainThread || Thread.isMainThread
        _decodedPaths.append(url.path)
        lock.unlock()

        let image = CIImage(color: .white).cropped(to: CGRect(
            x: 0,
            y: 0,
            width: pixelWidth,
            height: pixelHeight
        ))
        return PetDecodedFrame(image: image, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
}

private final class PeriodicCooldownSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [Int]
    private var consumed: [Int] = []

    init(values: [Int]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    func next(in range: ClosedRange<Int>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let value = values[min(consumed.count, values.count - 1)]
        precondition(range.contains(value))
        consumed.append(value)
        return value
    }

    func snapshot() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return consumed
    }
}

private final class PeriodicCooldownCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let value: Int
    private var count = 0

    init(value: Int) {
        self.value = value
    }

    var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func next(in range: ClosedRange<Int>) -> Int {
        precondition(range.contains(value))
        lock.lock()
        count += 1
        lock.unlock()
        return value
    }
}
