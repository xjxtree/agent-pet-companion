import Foundation

public struct FrameScheduler: Equatable, Sendable {
    public var fps: Int
    public var frameCount: Int
    public var durationMS: Int
    public var loops: Bool

    public init(
        fps: Int,
        frameCount: Int,
        durationMS: Int,
        loops: Bool = true
    ) {
        precondition(PetAnimationContract.supportedDurationsMS.contains(durationMS))
        self.fps = max(1, fps)
        self.frameCount = max(1, frameCount)
        self.durationMS = durationMS
        self.loops = loops
    }

    public func frameIndex(elapsedSeconds: TimeInterval) -> Int {
        let elapsed = max(0, elapsedSeconds)
        let duration = Double(durationMS) / 1_000
        if !loops, elapsed >= duration {
            return frameCount - 1
        }
        let phase = loops ? elapsed.truncatingRemainder(dividingBy: duration) : elapsed
        // Display-link timestamps commonly land a few ulps below an exact
        // frame boundary (for example 2.05 at 20 FPS). A nanosecond-scale
        // tolerance keeps those mathematical boundaries deterministic
        // without changing any visible frame interval.
        let raw = Int(floor(phase * Double(fps) + 1e-9))
        return min(raw, frameCount - 1)
    }

    public func hasCompleted(elapsedSeconds: TimeInterval) -> Bool {
        guard !loops else { return false }
        return max(0, elapsedSeconds) >= Double(durationMS) / 1_000
    }
}

public struct FrameSamplingPlan: Equatable, Sendable {
    public let nativeFPS: Int
    public let requestedFPS: Int
    public let effectiveFPS: Int
    public let durationMS: Int
    public let loops: Bool
    public let sourceFrameCount: Int
    public let sourceIndices: [Int]

    public init(
        nativeFPS: Int,
        requestedFPS: Int,
        durationMS: Int,
        loops: Bool,
        sourceFrameCount: Int
    ) {
        precondition(PetAnimationContract.supportedNativeFPS.contains(nativeFPS))
        precondition(PetAnimationContract.supportedNativeFPS.contains(requestedFPS))
        precondition(PetAnimationContract.supportedDurationsMS.contains(durationMS))
        self.nativeFPS = nativeFPS
        self.requestedFPS = requestedFPS
        effectiveFPS = nativeFPS == FpsProfile.standard.fps
            ? FpsProfile.standard.fps
            : requestedFPS
        self.durationMS = durationMS
        self.loops = loops
        let resolvedSourceFrameCount = max(0, sourceFrameCount)
        self.sourceFrameCount = resolvedSourceFrameCount

        let targetCount = min(
            resolvedSourceFrameCount,
            effectiveFPS * durationMS / 1_000
        )
        guard targetCount > 0 else {
            sourceIndices = []
            return
        }
        guard targetCount < resolvedSourceFrameCount else {
            sourceIndices = Array(0..<resolvedSourceFrameCount)
            return
        }

        if loops {
            sourceIndices = (0..<targetCount).map { logicalIndex in
                logicalIndex * resolvedSourceFrameCount / targetCount
            }
        } else if targetCount == 1 {
            sourceIndices = [resolvedSourceFrameCount - 1]
        } else {
            sourceIndices = (0..<targetCount).map { logicalIndex in
                Int((Double(logicalIndex)
                    * Double(resolvedSourceFrameCount - 1)
                    / Double(targetCount - 1)).rounded())
            }
        }
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
