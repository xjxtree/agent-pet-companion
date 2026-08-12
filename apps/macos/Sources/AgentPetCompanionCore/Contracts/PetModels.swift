import Foundation

public enum QualityLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case low
    case standard
    case high

    public static let studioCases: [Self] = [.low, .standard]

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .low: "标清"
        case .standard: "标准"
        case .high: "高清"
        }
    }

    public var detail: String {
        let size = renderSize
        switch self {
        case .standard:
            return "\(size.width)×\(size.height) · 推荐"
        default:
            return "\(size.width)×\(size.height)"
        }
    }

    public var renderSize: RenderSize {
        switch self {
        case .low: RenderSize(width: 192, height: 208)
        case .standard: RenderSize(width: 384, height: 416)
        case .high: RenderSize(width: 576, height: 624)
        }
    }

    public var isStudioSupported: Bool { Self.studioCases.contains(self) }
}

public struct RenderSize: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Closed preview/runtime action vocabulary for one V3 pet package.
///
/// The first six cases are Agent-driven semantic states. The final three are
/// local-only overlay interactions and never become Agent session state.
public enum PetAnimationAction: String, CaseIterable, Codable, Hashable, Sendable {
    case idle
    case thinking
    case tool
    case waiting
    case done
    case failed
    case acknowledge
    case dragLeft = "drag_left"
    case dragRight = "drag_right"
}

public enum PetAnimationContract {
    public static let orderedSemanticStateNames = [
        "idle",
        "thinking",
        "tool",
        "waiting",
        "done",
        "failed",
    ]
    public static let orderedInteractionStateNames = [
        "acknowledge",
        "drag_left",
        "drag_right",
    ]
    public static let orderedStateNames =
        orderedSemanticStateNames + orderedInteractionStateNames
    public static let defaultStates: [PetStateTiming] = [
        .init(
            name: "idle",
            framesDir: "assets/frames/idle",
            frameDurationsMS: [260, 220, 240, 260, 380, 640],
            playback: .init(mode: .periodic, cooldownMS: [2_500, 5_000]),
            reducedMotionFrameIndex: 2
        ),
        .init(
            name: "thinking",
            framesDir: "assets/frames/thinking",
            frameDurationsMS: [120, 140, 160, 180],
            playback: .init(mode: .burstThenIdle, entryRepeatCount: 3),
            reducedMotionFrameIndex: 2
        ),
        .init(
            name: "tool",
            framesDir: "assets/frames/tool",
            frameDurationsMS: [150, 150, 170, 330],
            playback: .init(
                mode: .burstThenIdle,
                entryRepeatCount: 3
            ),
            reducedMotionFrameIndex: 2
        ),
        .init(
            name: "waiting",
            framesDir: "assets/frames/waiting",
            frameDurationsMS: [100, 100, 110, 110, 120, 130, 160, 230],
            playback: .init(
                mode: .burstThenSettle,
                entryRepeatCount: 3,
                settleFrameIndex: 7
            ),
            reducedMotionFrameIndex: 4
        ),
        .init(
            name: "done",
            framesDir: "assets/frames/done",
            frameDurationsMS: [120, 140, 160, 230],
            playback: .init(mode: .burstThenIdle, entryRepeatCount: 3),
            reducedMotionFrameIndex: 2
        ),
        .init(
            name: "failed",
            framesDir: "assets/frames/failed",
            frameDurationsMS: [80, 80, 90, 100, 110, 120, 190, 290],
            playback: .init(
                mode: .burstThenSettle,
                entryRepeatCount: 3,
                settleFrameIndex: 7
            ),
            reducedMotionFrameIndex: 2
        ),
        .init(
            name: "acknowledge",
            framesDir: "assets/frames/acknowledge",
            frameDurationsMS: [180, 140, 180, 300],
            playback: .init(mode: .onceThenReturn),
            reducedMotionFrameIndex: 1
        ),
        .init(
            name: "drag_left",
            framesDir: "assets/frames/drag_left",
            frameDurationsMS: [100, 90, 100, 110, 100, 200],
            playback: .init(mode: .loop),
            reducedMotionFrameIndex: 2
        ),
        .init(
            name: "drag_right",
            framesDir: "assets/frames/drag_right",
            frameDurationsMS: [100, 90, 100, 110, 100, 200],
            playback: .init(mode: .loop),
            reducedMotionFrameIndex: 2
        ),
    ]

    public static func hasValidStates(_ states: [PetStateTiming]) -> Bool {
        states.count == orderedStateNames.count
            && Set(states.map(\.name)) == Set(orderedStateNames)
            && states.allSatisfy(\.isValid)
    }
}

public enum PetPlaybackMode: String, Codable, Hashable, Sendable {
    case loop
    case periodic
    case burstThenSettle = "burst_then_settle"
    case burstThenIdle = "burst_then_idle"
    case onceThenReturn = "once_then_return"
}

public struct PlaybackContract: Codable, Hashable, Sendable {
    public static let maximumPeriodicCooldownMS = 86_400_000

    public var mode: PetPlaybackMode
    public var entryRepeatCount: Int?
    public var settleFrameIndex: Int?
    public var cooldownMS: [Int]?

    public init(
        mode: PetPlaybackMode,
        entryRepeatCount: Int? = nil,
        settleFrameIndex: Int? = nil,
        cooldownMS: [Int]? = nil
    ) {
        self.mode = mode
        self.entryRepeatCount = entryRepeatCount
        self.settleFrameIndex = settleFrameIndex
        self.cooldownMS = cooldownMS
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case entryRepeatCount = "entry_repeat_count"
        case settleFrameIndex = "settle_frame_index"
        case cooldownMS = "cooldown_ms"
    }
}

public struct PetStateTiming: Codable, Hashable, Sendable {
    public var name: String
    public var framesDir: String
    public var frameDurationsMS: [Int]
    public var playback: PlaybackContract
    public var reducedMotionFrameIndex: Int

    public init(
        name: String,
        framesDir: String,
        frameDurationsMS: [Int],
        playback: PlaybackContract,
        reducedMotionFrameIndex: Int
    ) {
        self.name = name
        self.framesDir = framesDir
        self.frameDurationsMS = frameDurationsMS
        self.playback = playback
        self.reducedMotionFrameIndex = reducedMotionFrameIndex
    }

    enum CodingKeys: String, CodingKey {
        case name
        case framesDir = "frames_dir"
        case frameDurationsMS = "frame_durations_ms"
        case playback
        case reducedMotionFrameIndex = "reduced_motion_frame_index"
    }

    public var isValid: Bool {
        guard (2...40).contains(frameDurationsMS.count),
              frameDurationsMS.allSatisfy({ (50...2_000).contains($0) }),
              frameDurationsMS.reduce(0, +) <= 5_000,
              frameDurationsMS.indices.contains(reducedMotionFrameIndex)
        else { return false }
        let modeContractValid: Bool
        switch playback.mode {
        case .loop:
            modeContractValid = playback.entryRepeatCount == nil
                && playback.settleFrameIndex == nil
                && playback.cooldownMS == nil
        case .periodic:
            modeContractValid = playback.entryRepeatCount == nil
                && playback.settleFrameIndex == nil
                && playback.cooldownMS?.count == 2
                && playback.cooldownMS.map { $0[0] <= $0[1] } == true
                && playback.cooldownMS.map { cooldowns in
                    cooldowns.allSatisfy {
                        (0...PlaybackContract.maximumPeriodicCooldownMS).contains($0)
                    }
                } == true
        case .burstThenSettle:
            modeContractValid = playback.cooldownMS == nil
                && playback.entryRepeatCount.map { (1...8).contains($0) } == true
                && playback.settleFrameIndex.map(frameDurationsMS.indices.contains) == true
        case .burstThenIdle:
            modeContractValid = playback.cooldownMS == nil
                && playback.settleFrameIndex == nil
                && playback.entryRepeatCount.map { (1...8).contains($0) } == true
        case .onceThenReturn:
            modeContractValid = playback.entryRepeatCount == nil
                && playback.settleFrameIndex == nil
                && playback.cooldownMS == nil
        }
        guard modeContractValid else { return false }
        let expectedMode: PetPlaybackMode? = switch name {
        case "idle": .periodic
        case "thinking", "tool", "done": .burstThenIdle
        case "waiting", "failed": .burstThenSettle
        case "acknowledge": .onceThenReturn
        case "drag_left", "drag_right": .loop
        default: nil
        }
        return playback.mode == expectedMode
    }
}

public struct PetSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var style: String
    public var quality: QualityLevel
    public var renderSize: RenderSize
    public var petpackPath: String
    public var coverPath: String
    public var origin: PetOrigin
    public var generator: String?
    public var provenance: String?
    public var revisionID: String?
    public var revisionCount: Int
    public var states: [PetStateTiming]
    public var active: Bool
    public var createdAt: String

    public init(
        id: String,
        name: String,
        style: String,
        quality: QualityLevel,
        renderSize: RenderSize,
        petpackPath: String,
        coverPath: String,
        origin: PetOrigin = .externalImport,
        generator: String? = nil,
        provenance: String? = nil,
        revisionID: String? = nil,
        revisionCount: Int = 0,
        states: [PetStateTiming] = PetAnimationContract.defaultStates,
        active: Bool,
        createdAt: String
    ) {
        precondition(PetAnimationContract.hasValidStates(states))
        self.id = id
        self.name = name
        self.style = style
        self.quality = quality
        self.renderSize = renderSize
        self.petpackPath = petpackPath
        self.coverPath = coverPath
        self.origin = origin
        self.generator = generator
        self.provenance = provenance
        self.revisionID = revisionID
        self.revisionCount = max(0, revisionCount)
        self.states = states
        self.active = active
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case style
        case quality
        case renderSize = "render_size"
        case petpackPath = "petpack_path"
        case coverPath = "cover_path"
        case origin
        case generator
        case provenance
        case revisionID = "revision_id"
        case revisionCount = "revision_count"
        case states
        case active
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        style = try container.decode(String.self, forKey: .style)
        quality = try container.decode(QualityLevel.self, forKey: .quality)
        renderSize = try container.decode(RenderSize.self, forKey: .renderSize)
        petpackPath = try container.decode(String.self, forKey: .petpackPath)
        coverPath = try container.decode(String.self, forKey: .coverPath)
        origin = try container.decodeIfPresent(PetOrigin.self, forKey: .origin) ?? .externalImport
        generator = try container.decodeIfPresent(String.self, forKey: .generator)
        provenance = try container.decodeIfPresent(String.self, forKey: .provenance)
        revisionID = try container.decodeIfPresent(String.self, forKey: .revisionID)
        revisionCount = max(0, try container.decodeIfPresent(Int.self, forKey: .revisionCount) ?? 0)
        states = try container.decode([PetStateTiming].self, forKey: .states)
        guard PetAnimationContract.hasValidStates(states) else {
            throw DecodingError.dataCorruptedError(
                forKey: .states,
                in: container,
                debugDescription: "states must contain the nine valid V3 timing contracts"
            )
        }
        active = try container.decode(Bool.self, forKey: .active)
        createdAt = try container.decode(String.self, forKey: .createdAt)
    }

    public func timing(for stateName: String) -> PetStateTiming {
        states.first(where: { $0.name == stateName })
            ?? PetAnimationContract.defaultStates.first(where: { $0.name == stateName })
            ?? PetAnimationContract.defaultStates[0]
    }

    /// Mirrors PetCore's closed bundled identity. A
    /// display name or package-declared marker alone never grants this status.
    public var isBundled: Bool {
        Self.includedCompanionIDSet.contains(id)
            && origin == .verifiedSkillSource
            && generator == "agent-pet-companion.release-inventory"
            && provenance == "apc.bundled-pets.v1"
    }

    /// Stable logical identities reserved for the three companions shipped with
    /// the App. An existing same-ID pet remains user-owned and is never granted
    /// bundled permissions, but it is still a valid first-run choice after an
    /// upgrade because inventory seeding deliberately preserves it.
    public static let includedCompanionIDs = [
        "pet_xingwutuanzi",
        "pet_bytebudcodex",
        "pet_pinklace"
    ]

    public var isIncludedCompanionCandidate: Bool {
        Self.includedCompanionIDSet.contains(id)
    }

    private static let includedCompanionIDSet = Set(includedCompanionIDs)

    public var generationSourceTitle: String {
        if isBundled { return "App 内置" }
        return switch origin {
        case .verifiedSkillSource:
            "已验证 Skill 来源"
        case .generatedByPetcoreJob:
            provenance == "skill-full-source" ? "App 内生成" : "本地动画预览"
        case .externalImport:
            "外部导入"
        }
    }

    public var generationSourceDetail: String {
        if isBundled { return "随 Agent Pet Companion 提供" }
        let claimed = [generator, provenance].compactMap { $0 }.joined(separator: " · ")
        switch origin {
        case .verifiedSkillSource:
            return claimed.isEmpty ? "已通过 App Server Skill source 校验" : "已验证 · \(claimed)"
        case .generatedByPetcoreJob:
            if provenance == "deterministic_preview" || provenance == "local_form" {
                return claimed.isEmpty ? "确定性预览，不代表 AI 图像生成" : "确定性预览 · \(claimed)"
            }
            if provenance == "codex_app_server_brief" {
                return claimed.isEmpty ? "AI brief + 本地预览渲染" : "AI brief + 本地预览 · \(claimed)"
            }
            return claimed.isEmpty ? "由本 App generation job 写入" : "App job · \(claimed)"
        case .externalImport:
            return claimed.isEmpty ? "外部 .petpack 未记录包内声明" : "外部导入 · 包内声明：\(claimed)"
        }
    }
}
public struct PetAssetWarning: Codable, Hashable, Sendable {
    public var petId: String
    public var code: String
    public var fingerprint: String
    public var message: String

    public init(petId: String, code: String, fingerprint: String, message: String) {
        self.petId = petId
        self.code = code
        self.fingerprint = fingerprint
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case petId = "pet_id"
        case code
        case fingerprint
        case message
    }
}

public struct PetAssetRepairOutcome: Codable, Hashable, Sendable {
    public var pet: PetSummary
    public var warning: PetAssetWarning?

    public init(pet: PetSummary, warning: PetAssetWarning?) {
        self.pet = pet
        self.warning = warning
    }
}

public struct PetAssetWarningIndex: Equatable, Sendable {
    private var warningsByPetID: [String: PetAssetWarning]

    public init(_ warnings: [PetAssetWarning] = []) {
        warningsByPetID = Dictionary(warnings.map { ($0.petId, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    public subscript(petID: String) -> PetAssetWarning? {
        warningsByPetID[petID]
    }
}

public enum PetOrigin: String, Codable, Hashable, Sendable {
    case externalImport = "external_import"
    case generatedByPetcoreJob = "generated_by_petcore_job"
    case verifiedSkillSource = "verified_skill_source"
}

/// The single cross-process equality and normalization contract for overlay
/// placement. A 1/256 pt grid is exactly representable by IEEE-754 binary
/// floating point, so canonical coordinates survive Swift/JSON/Rust round
/// trips without an epsilon comparison.
public enum OverlayPlacementCanonicalization {
    public static let gridUnitsPerPoint = 256.0
    public static let quantumPt = 1.0 / gridUnitsPerPoint
    public static let maximumCoordinateMagnitude =
        Double.greatestFiniteMagnitude / gridUnitsPerPoint

    public static func coordinate(_ value: Double) -> Double? {
        guard value.isFinite,
              abs(value) <= maximumCoordinateMagnitude else {
            return nil
        }
        let canonical = (value * gridUnitsPerPoint)
            .rounded(.toNearestOrAwayFromZero) / gridUnitsPerPoint
        guard canonical.isFinite else { return nil }
        return canonical == 0 ? 0 : canonical
    }

    /// Canonicalizes a Core Graphics coordinate while preserving an invalid
    /// input for the caller's existing validation path.
    public static func cgFloatCoordinate(_ value: CGFloat) -> CGFloat {
        guard let canonical = coordinate(Double(value)) else { return value }
        return CGFloat(canonical)
    }

    public static func placement(
        _ placement: OverlayPlacement
    ) -> OverlayPlacement? {
        guard let x = coordinate(placement.x),
              let y = coordinate(placement.y),
              placement.displayWidthPt.isFinite,
              (OverlayPlacement.minimumDisplayWidthPt
                ... OverlayPlacement.maximumDisplayWidthPt)
                .contains(placement.displayWidthPt),
              !placement.displayId.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            return nil
        }
        var canonical = placement
        canonical.x = x
        canonical.y = y
        return canonical
    }

    public static func areEquivalent(
        _ lhs: OverlayPlacement,
        _ rhs: OverlayPlacement
    ) -> Bool {
        guard let lhs = placement(lhs),
              let rhs = placement(rhs) else {
            return false
        }
        return lhs.x == rhs.x
            && lhs.y == rhs.y
            && lhs.displayWidthPt == rhs.displayWidthPt
            && lhs.displayId == rhs.displayId
    }

    public static func inwardLowerBound(_ value: Double) -> Double? {
        guard value.isFinite,
              abs(value) <= maximumCoordinateMagnitude else {
            return nil
        }
        let canonical = (value * gridUnitsPerPoint)
            .rounded(.up)
            / gridUnitsPerPoint
        return canonical == 0 ? 0 : canonical
    }

    public static func inwardUpperBound(_ value: Double) -> Double? {
        guard value.isFinite,
              abs(value) <= maximumCoordinateMagnitude else {
            return nil
        }
        let canonical = (value * gridUnitsPerPoint)
            .rounded(.down)
            / gridUnitsPerPoint
        return canonical == 0 ? 0 : canonical
    }
}

public struct OverlayPlacement: Codable, Hashable, Sendable {
    public static let minimumDisplayWidthPt = 100.0
    public static let maximumDisplayWidthPt = 300.0
    public static let defaultDisplayWidthPt = 112.0

    public var x: Double
    public var y: Double
    public var displayWidthPt: Double
    public var displayId: String

    public init(
        x: Double = 0,
        y: Double = 0,
        displayWidthPt: Double = defaultDisplayWidthPt,
        displayId: String = "main"
    ) {
        self.x = OverlayPlacementCanonicalization.coordinate(x) ?? x
        self.y = OverlayPlacementCanonicalization.coordinate(y) ?? y
        self.displayWidthPt = Self.clampedDisplayWidth(displayWidthPt)
        self.displayId = displayId
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case x
        case y
        case displayWidthPt = "display_width_pt"
        case displayId = "display_id"
    }

    public init(from decoder: Decoder) throws {
        try OverlayPlacementClosedDecoding.requireOnlyKeys(
            CodingKeys.self,
            from: decoder
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedX = try container.decode(Double.self, forKey: .x)
        let decodedY = try container.decode(Double.self, forKey: .y)
        let decodedDisplayWidthPt = try container.decode(
            Double.self,
            forKey: .displayWidthPt
        )
        let decodedDisplayId = try container.decode(String.self, forKey: .displayId)
        guard decodedX.isFinite,
              decodedY.isFinite,
              decodedDisplayWidthPt.isFinite,
              (Self.minimumDisplayWidthPt ... Self.maximumDisplayWidthPt)
                  .contains(decodedDisplayWidthPt),
              !decodedDisplayId.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Overlay placement values are outside the closed contract"
                )
            )
        }
        guard let canonicalX = OverlayPlacementCanonicalization.coordinate(decodedX),
              let canonicalY = OverlayPlacementCanonicalization.coordinate(decodedY) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Overlay placement coordinates cannot be canonicalized"
                )
            )
        }
        x = canonicalX
        y = canonicalY
        displayWidthPt = decodedDisplayWidthPt
        displayId = decodedDisplayId
    }

    public func encode(to encoder: Encoder) throws {
        guard let canonical = OverlayPlacementCanonicalization.placement(self) else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Overlay placement values are outside the closed contract"
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canonical.x, forKey: .x)
        try container.encode(canonical.y, forKey: .y)
        try container.encode(canonical.displayWidthPt, forKey: .displayWidthPt)
        try container.encode(canonical.displayId, forKey: .displayId)
    }

    private static func clampedDisplayWidth(_ value: Double) -> Double {
        guard value.isFinite else { return defaultDisplayWidthPt }
        return min(maximumDisplayWidthPt, max(minimumDisplayWidthPt, value))
    }
}

private enum OverlayPlacementClosedDecoding {
    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    static func requireOnlyKeys<Key>(
        _ keyType: Key.Type,
        from decoder: Decoder
    ) throws where Key: CodingKey & CaseIterable {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let allowed = Set(keyType.allCases.map(\.stringValue))
        let unknown = container.allKeys
            .map(\.stringValue)
            .filter { !allowed.contains($0) }
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown overlay placement fields: \(unknown.sorted())"
                )
            )
        }
    }
}
