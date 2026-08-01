import Foundation

public struct FrameTimeline: Equatable, Sendable {
    public let durationsMS: [Int]
    public let cumulativeMS: [Int]
    public let playback: PlaybackContract
    public let settleFrameIndex: Int?
    public let reducedMotionFrameIndex: Int
    public let periodicCooldownMS: Int?

    public init(
        durationsMS: [Int],
        playback: PlaybackContract,
        settleFrameIndex: Int? = nil,
        reducedMotionFrameIndex: Int,
        periodicCooldownMS: Int? = nil
    ) {
        precondition((2...40).contains(durationsMS.count))
        precondition(durationsMS.allSatisfy { (50...2_000).contains($0) })
        precondition(durationsMS.reduce(0, +) <= 5_000)
        precondition(durationsMS.indices.contains(reducedMotionFrameIndex))
        if let settleFrameIndex {
            precondition(durationsMS.indices.contains(settleFrameIndex))
        }
        self.durationsMS = durationsMS
        var elapsed = 0
        cumulativeMS = durationsMS.map { duration in
            elapsed += duration
            return elapsed
        }
        self.playback = playback
        self.settleFrameIndex = settleFrameIndex ?? playback.settleFrameIndex
        self.reducedMotionFrameIndex = reducedMotionFrameIndex
        if let periodicCooldownMS, let cooldownMS = playback.cooldownMS {
            precondition(cooldownMS.count == 2)
            precondition((cooldownMS[0]...cooldownMS[1]).contains(periodicCooldownMS))
        }
        self.periodicCooldownMS = periodicCooldownMS
    }

    public init(state: PetStateTiming, periodicCooldownMS: Int? = nil) {
        self.init(
            durationsMS: state.frameDurationsMS,
            playback: state.playback,
            settleFrameIndex: state.playback.mode == .periodic
                ? state.reducedMotionFrameIndex
                : state.playback.settleFrameIndex,
            reducedMotionFrameIndex: state.reducedMotionFrameIndex,
            periodicCooldownMS: periodicCooldownMS
        )
    }

    public var totalDurationMS: Int {
        cumulativeMS.last ?? 0
    }

    public var frameCount: Int {
        durationsMS.count
    }

    public func frameIndex(elapsedMS: Int, reducedMotion: Bool = false) -> Int {
        if reducedMotion {
            return reducedMotionFrameIndex
        }
        let elapsed = max(0, elapsedMS)
        switch playback.mode {
        case .loop:
            return authoredFrame(at: elapsed % totalDurationMS)
        case .onceHold:
            guard elapsed < totalDurationMS else {
                return settleFrameIndex ?? frameCount - 1
            }
            return authoredFrame(at: elapsed)
        case .periodic:
            guard let periodicCooldownMS else {
                preconditionFailure("periodic playback requires one sampled cooldown")
            }
            let cycle = totalDurationMS + periodicCooldownMS
            let phase = cycle > 0 ? elapsed % cycle : 0
            guard phase < totalDurationMS else {
                return settleFrameIndex ?? frameCount - 1
            }
            return authoredFrame(at: phase)
        case .burstThenSettle:
            let repeats = max(1, playback.entryRepeatCount ?? 1)
            let activeDuration = totalDurationMS * repeats
            guard elapsed < activeDuration else {
                return settleFrameIndex ?? frameCount - 1
            }
            return authoredFrame(at: elapsed % totalDurationMS)
        }
    }

    public func hasCompleted(elapsedMS: Int) -> Bool {
        let elapsed = max(0, elapsedMS)
        switch playback.mode {
        case .loop, .periodic:
            return false
        case .onceHold:
            return elapsed >= totalDurationMS
        case .burstThenSettle:
            return elapsed >= totalDurationMS * max(1, playback.entryRepeatCount ?? 1)
        }
    }

    /// Resolves directly from wall-clock elapsed time. Missed boundaries are
    /// intentionally not replayed after a stall.
    public func resolvedFrameAfterStall(
        elapsedMS: Int,
        reducedMotion: Bool = false
    ) -> Int {
        frameIndex(elapsedMS: elapsedMS, reducedMotion: reducedMotion)
    }

    /// Resolves a frame inside one authored pass. Periodic scheduling owns
    /// cooldown selection separately so repeated lookups cannot resample it.
    public func authoredFrameIndex(elapsedMS: Int) -> Int {
        authoredFrame(at: min(max(0, elapsedMS), max(0, totalDurationMS - 1)))
    }

    private func authoredFrame(at phaseMS: Int) -> Int {
        let target = max(0, phaseMS)
        var low = 0
        var high = cumulativeMS.count
        while low < high {
            let middle = (low + high) / 2
            if target < cumulativeMS[middle] {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return min(low, frameCount - 1)
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

    public func frameIndex(
        at time: TimeInterval,
        timeline: FrameTimeline,
        reducedMotion: Bool = false
    ) -> Int {
        timeline.frameIndex(
            elapsedMS: Int(max(0, time - enteredAt) * 1_000),
            reducedMotion: reducedMotion
        )
    }

    public func hasCompleted(at time: TimeInterval, timeline: FrameTimeline) -> Bool {
        timeline.hasCompleted(elapsedMS: Int(max(0, time - enteredAt) * 1_000))
    }
}

public struct RendererBudget: Equatable, Sendable {
    public var quality: QualityLevel
    public var frameCount: Int
    public var decodedStateMB: Double
    public var rendererBudgetMB: Int
    public var usesRingCache: Bool

    public init(quality: QualityLevel, frameCount: Int) {
        self.quality = quality
        self.frameCount = min(max(frameCount, 2), 40)
        let size = quality.renderSize
        decodedStateMB = Double(size.width * size.height * 4 * self.frameCount)
            / 1024.0 / 1024.0
        rendererBudgetMB = max(64, Int(ceil(decodedStateMB * 3)))
        usesRingCache = false
    }
}
