import Foundation

public struct FrameScheduler: Equatable, Sendable {
    public var fps: Int
    public var frameCount: Int
    public var loops: Bool

    public init(fps: Int, frameCount: Int, loops: Bool = true) {
        self.fps = max(1, fps)
        self.frameCount = max(1, frameCount)
        self.loops = loops
    }

    public func frameIndex(elapsedSeconds: TimeInterval) -> Int {
        let raw = Int(floor(max(0, elapsedSeconds) * Double(fps)))
        return loops ? raw % frameCount : min(raw, frameCount - 1)
    }

    public func hasCompleted(elapsedSeconds: TimeInterval) -> Bool {
        guard !loops else { return false }
        let raw = Int(floor(max(0, elapsedSeconds) * Double(fps)))
        return raw >= frameCount - 1
    }
}

public struct FramePlaybackState: Equatable, Sendable {
    public private(set) var stateID: String
    public private(set) var enteredAt: TimeInterval

    public init(stateID: String, enteredAt: TimeInterval) {
        self.stateID = stateID
        self.enteredAt = enteredAt
    }

    public mutating func enter(stateID: String, at time: TimeInterval) {
        guard stateID != self.stateID else { return }
        self.stateID = stateID
        enteredAt = time
    }

    public func frameIndex(at time: TimeInterval, scheduler: FrameScheduler) -> Int {
        scheduler.frameIndex(elapsedSeconds: max(0, time - enteredAt))
    }

    public func hasCompleted(at time: TimeInterval, scheduler: FrameScheduler) -> Bool {
        scheduler.hasCompleted(elapsedSeconds: max(0, time - enteredAt))
    }
}

public struct RendererBudget: Equatable, Sendable {
    public var quality: QualityLevel
    public var fpsProfile: FpsProfile
    public var decodedStateMB: Double
    public var rendererBudgetMB: Int
    public var usesRingCache: Bool

    public init(quality: QualityLevel, fpsProfile: FpsProfile) {
        self.quality = quality
        self.fpsProfile = fpsProfile
        let size = quality.renderSize
        let frames = fpsProfile.fps * 2
        decodedStateMB = Double(size.width * size.height * 4 * frames) / 1024.0 / 1024.0
        switch (quality, fpsProfile) {
        case (.original, .smooth):
            rendererBudgetMB = 420
        case (.original, .standard):
            rendererBudgetMB = 320
        case (_, .smooth):
            rendererBudgetMB = 260
        case (_, .standard):
            rendererBudgetMB = 180
        }
        usesRingCache = quality == .original
    }
}
