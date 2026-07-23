import Testing
@testable import AgentPetCompanionCore

@Suite
struct FrameSchedulerTests {
    @Test
    func oneShotUsesTheFullAuthoredDurationBeforeStoppingOnLastFrame() {
        let scheduler = FrameScheduler(
            fps: 10,
            frameCount: 10,
            durationMS: 1_000,
            loops: false
        )

        #expect(scheduler.frameIndex(elapsedSeconds: 0) == 0)
        #expect(scheduler.frameIndex(elapsedSeconds: 0.9) == 9)
        #expect(!scheduler.hasCompleted(elapsedSeconds: 1.0.nextDown))
        #expect(scheduler.frameIndex(elapsedSeconds: 1) == 9)
        #expect(scheduler.hasCompleted(elapsedSeconds: 1))
        #expect(scheduler.frameIndex(elapsedSeconds: 10) == 9)
    }

    @Test
    func loopingStateWrapsAtTheExplicitTwoSecondBoundary() {
        let scheduler = FrameScheduler(
            fps: 20,
            frameCount: 40,
            durationMS: 2_000,
            loops: true
        )

        #expect(scheduler.frameIndex(elapsedSeconds: 1.95) == 39)
        #expect(scheduler.frameIndex(elapsedSeconds: 2) == 0)
        #expect(scheduler.frameIndex(elapsedSeconds: 2.05) == 1)
        #expect(!scheduler.hasCompleted(elapsedSeconds: 10))
    }

    @Test
    func stateChangeResetsFrame() {
        let scheduler = FrameScheduler(
            fps: 10,
            frameCount: 10,
            durationMS: 1_000,
            loops: false
        )
        var playback = FramePlaybackState(stateID: "start", enteredAt: 10)

        #expect(playback.frameIndex(at: 10.5, scheduler: scheduler) == 5)
        playback.enter(stateID: "done", at: 11)
        #expect(playback.frameIndex(at: 11, scheduler: scheduler) == 0)
    }

    @Test
    func smoothLoopDownsamplesByExactlyEveryOtherSourceFrame() {
        let plan = FrameSamplingPlan(
            nativeFPS: 20,
            requestedFPS: 10,
            durationMS: 2_000,
            loops: true,
            sourceFrameCount: 40
        )

        #expect(plan.effectiveFPS == 10)
        #expect(plan.sourceIndices == Array(stride(from: 0, to: 40, by: 2)))
    }

    @Test
    func smoothOneShotDownsamplingPreservesBothAuthoredEndpoints() {
        let plan = FrameSamplingPlan(
            nativeFPS: 20,
            requestedFPS: 10,
            durationMS: 1_000,
            loops: false,
            sourceFrameCount: 20
        )

        #expect(plan.sourceIndices.count == 10)
        #expect(plan.sourceIndices.first == 0)
        #expect(plan.sourceIndices.last == 19)
        #expect(Set(plan.sourceIndices).count == 10)
    }

    @Test
    func nativeStandardPetDefensivelyRejectsSmoothPlayback() {
        let plan = FrameSamplingPlan(
            nativeFPS: 10,
            requestedFPS: 20,
            durationMS: 2_000,
            loops: true,
            sourceFrameCount: 20
        )

        #expect(plan.effectiveFPS == 10)
        #expect(plan.sourceIndices == Array(0..<20))
    }
}
