import Testing
@testable import AgentPetCompanionCore

@Suite
struct FrameSchedulerTests {
    @Test
    func oneShotStopsOnLastFrame() {
        let scheduler = FrameScheduler(fps: 12, frameCount: 4, loops: false)

        #expect(scheduler.frameIndex(elapsedSeconds: 0) == 0)
        #expect(scheduler.frameIndex(elapsedSeconds: 0.25) == 3)
        #expect(scheduler.frameIndex(elapsedSeconds: 10) == 3)
        #expect(scheduler.hasCompleted(elapsedSeconds: 10))
    }

    @Test
    func loopingStateWraps() {
        let scheduler = FrameScheduler(fps: 12, frameCount: 4, loops: true)

        #expect(scheduler.frameIndex(elapsedSeconds: 4.0 / 12.0) == 0)
        #expect(scheduler.frameIndex(elapsedSeconds: 5.0 / 12.0) == 1)
        #expect(!scheduler.hasCompleted(elapsedSeconds: 10))
    }

    @Test
    func stateChangeResetsFrame() {
        let scheduler = FrameScheduler(fps: 12, frameCount: 8, loops: false)
        var playback = FramePlaybackState(stateID: "start", enteredAt: 10)

        #expect(playback.frameIndex(at: 10.5, scheduler: scheduler) == 6)
        playback.enter(stateID: "done", at: 11)
        #expect(playback.frameIndex(at: 11, scheduler: scheduler) == 0)
    }
}
