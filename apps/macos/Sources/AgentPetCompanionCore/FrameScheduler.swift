import Foundation

public struct FrameScheduler: Equatable, Sendable {
    public var fps: Int
    public var frameCount: Int

    public init(fps: Int, frameCount: Int) {
        self.fps = max(1, fps)
        self.frameCount = max(1, frameCount)
    }

    public func frameIndex(elapsedSeconds: TimeInterval) -> Int {
        let raw = Int(floor(max(0, elapsedSeconds) * Double(fps)))
        return raw % frameCount
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
