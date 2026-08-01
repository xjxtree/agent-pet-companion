import Testing
@testable import AgentPetCompanionCore

@Suite("Per-frame animation timeline")
struct FrameTimelineTests {
    @Test("periodic cooldown accepts the V2 boundary and rejects values outside it")
    func periodicCooldownBounds() {
        func timing(_ cooldownMS: [Int]) -> PetStateTiming {
            PetStateTiming(
                name: "idle",
                framesDir: "assets/frames/idle",
                frameDurationsMS: [100, 100],
                playback: PlaybackContract(mode: .periodic, cooldownMS: cooldownMS),
                reducedMotionFrameIndex: 1
            )
        }

        let maximum = PlaybackContract.maximumPeriodicCooldownMS
        #expect(timing([0, maximum]).isValid)
        #expect(!timing([-1, maximum]).isValid)
        #expect(!timing([0, maximum + 1]).isValid)
    }

    @Test("non-uniform frame durations switch at authored boundaries")
    func nonUniformBoundaries() {
        let timeline = FrameTimeline(
            durationsMS: [100, 250, 50],
            playback: PlaybackContract(mode: .loop),
            reducedMotionFrameIndex: 1
        )

        #expect(timeline.frameIndex(elapsedMS: 0) == 0)
        #expect(timeline.frameIndex(elapsedMS: 99) == 0)
        #expect(timeline.frameIndex(elapsedMS: 100) == 1)
        #expect(timeline.frameIndex(elapsedMS: 349) == 1)
        #expect(timeline.frameIndex(elapsedMS: 350) == 2)
        #expect(timeline.frameIndex(elapsedMS: 399) == 2)
        #expect(timeline.frameIndex(elapsedMS: 400) == 0)
    }

    @Test("loop repeats the complete authored timeline")
    func loopPlayback() {
        let timeline = FrameTimeline(
            durationsMS: [100, 300],
            playback: PlaybackContract(mode: .loop),
            reducedMotionFrameIndex: 0
        )

        #expect(timeline.frameIndex(elapsedMS: 399) == 1)
        #expect(timeline.frameIndex(elapsedMS: 400) == 0)
        #expect(timeline.frameIndex(elapsedMS: 500) == 1)
        #expect(!timeline.hasCompleted(elapsedMS: 10_000))
    }

    @Test("once-hold completes once and holds its declared settle frame")
    func onceHoldPlayback() {
        let timeline = FrameTimeline(
            durationsMS: [100, 250, 50],
            playback: PlaybackContract(mode: .onceHold, settleFrameIndex: 1),
            reducedMotionFrameIndex: 2
        )

        #expect(timeline.frameIndex(elapsedMS: 399) == 2)
        #expect(!timeline.hasCompleted(elapsedMS: 399))
        #expect(timeline.frameIndex(elapsedMS: 400) == 1)
        #expect(timeline.hasCompleted(elapsedMS: 400))
        #expect(timeline.frameIndex(elapsedMS: 20_000) == 1)
    }

    @Test("periodic playback holds during cooldown and starts a new authored cycle")
    func periodicPlayback() {
        let timeline = FrameTimeline(
            durationsMS: [100, 300],
            playback: PlaybackContract(mode: .periodic, cooldownMS: [600, 600]),
            settleFrameIndex: 1,
            reducedMotionFrameIndex: 1,
            periodicCooldownMS: 600
        )

        #expect(timeline.frameIndex(elapsedMS: 399) == 1)
        #expect(timeline.frameIndex(elapsedMS: 400) == 1)
        #expect(timeline.frameIndex(elapsedMS: 999) == 1)
        #expect(timeline.frameIndex(elapsedMS: 1_000) == 0)
        #expect(!timeline.hasCompleted(elapsedMS: 10_000))
    }

    @Test("burst-then-settle repeats the entry burst exactly and then settles")
    func burstThenSettlePlayback() {
        let timeline = FrameTimeline(
            durationsMS: [100, 250, 50],
            playback: PlaybackContract(
                mode: .burstThenSettle,
                entryRepeatCount: 2,
                settleFrameIndex: 1
            ),
            reducedMotionFrameIndex: 2
        )

        #expect(timeline.frameIndex(elapsedMS: 399) == 2)
        #expect(timeline.frameIndex(elapsedMS: 400) == 0)
        #expect(timeline.frameIndex(elapsedMS: 799) == 2)
        #expect(!timeline.hasCompleted(elapsedMS: 799))
        #expect(timeline.frameIndex(elapsedMS: 800) == 1)
        #expect(timeline.hasCompleted(elapsedMS: 800))
    }

    @Test("a 300 ms stall resolves directly to the current authored frame")
    func wallClockStallSkipsMissedBoundaries() {
        let timeline = FrameTimeline(
            durationsMS: [100, 100, 100, 100],
            playback: PlaybackContract(mode: .loop),
            reducedMotionFrameIndex: 2
        )

        #expect(timeline.frameIndex(elapsedMS: 50) == 0)
        #expect(timeline.resolvedFrameAfterStall(elapsedMS: 350) == 3)
    }

    @Test("re-entering the same semantic state is idempotent")
    func unchangedEntryDoesNotRestart() {
        let timeline = FrameTimeline(
            durationsMS: [100, 100],
            playback: PlaybackContract(mode: .loop),
            reducedMotionFrameIndex: 0
        )
        var playback = FramePlaybackState(stateID: "tool", enteredAt: 10)

        playback.enter(stateID: "tool", at: 10.15)

        #expect(playback.enteredAt == 10)
        #expect(playback.frameIndex(at: 10.25, timeline: timeline) == 0)
    }

    @Test("a changed semantic state enters at its first authored frame")
    func changedEntryRestarts() {
        let timeline = FrameTimeline(
            durationsMS: [100, 100],
            playback: PlaybackContract(mode: .loop),
            reducedMotionFrameIndex: 0
        )
        var playback = FramePlaybackState(stateID: "start", enteredAt: 10)

        playback.enter(stateID: "done", at: 11)

        #expect(playback.stateID == "done")
        #expect(playback.enteredAt == 11)
        #expect(playback.frameIndex(at: 11, timeline: timeline) == 0)
    }

    @Test("reduced motion always presents the authored representative frame")
    func reducedMotionIsStatic() {
        let timeline = FrameTimeline(
            durationsMS: [100, 250, 50],
            playback: PlaybackContract(mode: .loop),
            reducedMotionFrameIndex: 1
        )

        #expect(timeline.frameIndex(elapsedMS: 0, reducedMotion: true) == 1)
        #expect(timeline.frameIndex(elapsedMS: 10_000, reducedMotion: true) == 1)
    }
}
