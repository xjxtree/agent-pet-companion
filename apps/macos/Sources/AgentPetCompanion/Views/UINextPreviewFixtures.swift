import AgentPetCompanionCore
import AppKit
#if DEBUG
import Darwin
#endif
import Foundation
import SwiftUI

/// Typed, deterministic surfaces used by the UI Next preview gallery and by
/// non-interactive regression tests. Keeping the matrix here prevents visual
/// acceptance from drifting into an undocumented collection of screenshots.
enum UINextOverlayFixtureState: String, CaseIterable, Identifiable, Hashable {
    case idle
    case start
    case tool
    case waiting
    case review
    case done
    case failed

    var id: String { rawValue }

    var eventKind: AgentEventKind? {
        switch self {
        case .idle: nil
        case .start: .start
        case .tool: .tool
        case .waiting: .waiting
        case .review: .review
        case .done: .done
        case .failed: .failed
        }
    }
}

enum UINextOverlayGroupFixturePresentation: String, CaseIterable, Identifiable, Hashable {
    case automatic
    case stacked
    case expanded

    var id: String { rawValue }

    func isExpanded(sessionCount: Int) -> Bool {
        switch self {
        case .automatic:
            sessionCount == 1
        case .stacked:
            false
        case .expanded:
            true
        }
    }
}

enum UINextOverlayControlFixturePresentation: String, CaseIterable, Identifiable, Hashable {
    case resting
    case hovered
    case resizing

    var id: String { rawValue }
    var controlsVisible: Bool { self != .resting }
    var showsScaleValue: Bool { self == .resizing }
}

enum UINextOverlayContentFixtureProfile: String, CaseIterable, Identifiable, Hashable {
    case singleAgent
    case mixedAgents

    var id: String { rawValue }
}

enum UINextAccessibilityFixtureMode: String, CaseIterable, Identifiable, Hashable {
    case standard
    case reduceTransparency
    case increasedContrast
    case reduceMotion

    var id: String { rawValue }

    var presentation: APCVisualAccessibilityPresentation {
        switch self {
        case .standard:
            .init(reduceTransparency: false, increasedContrast: false, reduceMotion: false)
        case .reduceTransparency:
            .init(reduceTransparency: true, increasedContrast: false, reduceMotion: false)
        case .increasedContrast:
            .init(reduceTransparency: false, increasedContrast: true, reduceMotion: false)
        case .reduceMotion:
            .init(reduceTransparency: false, increasedContrast: false, reduceMotion: true)
        }
    }

    var overrides: APCVisualAccessibilityOverrides {
        .init(
            reduceTransparency: presentation.reduceTransparency,
            increasedContrast: presentation.increasedContrast,
            reduceMotion: presentation.reduceMotion
        )
    }
}

enum UINextMakerSessionFixture: String, CaseIterable, Identifiable, Hashable {
    case idle
    case modifyingRunning
    case failedNeedsReferences

    var id: String { rawValue }
}

enum UINextConnectionOperationFixturePresentation: String, CaseIterable, Identifiable, Hashable {
    case idle
    case busy
    case failure

    var id: String { rawValue }
}

/// Curated connection-page states, kept deliberately smaller than a Cartesian
/// matrix. Each profile drives the production connection view through typed
/// PetCore models instead of preview-only labels or branches.
enum UINextConnectionFixtureProfile: String, CaseIterable, Identifiable, Hashable {
    case full
    case light
    case missing
    case needsFix = "needs-fix"
    case unverified
    case unsupported
    case busy
    case failure
    case invalidDirectory = "invalid-directory"

    var id: String { rawValue }

    var checkMode: ConnectionCheckMode {
        self == .light ? .light : .runtime
    }

    var expectedCheckStatus: CheckStatus {
        switch self {
        case .full, .light, .busy, .failure:
            .ok
        case .missing, .invalidDirectory:
            .missing
        case .needsFix:
            .needsFix
        case .unverified:
            .unverified
        case .unsupported:
            .unsupported
        }
    }

    var operationPresentation: UINextConnectionOperationFixturePresentation {
        switch self {
        case .busy:
            .busy
        case .failure:
            .failure
        case .full, .light, .missing, .needsFix, .unverified, .unsupported,
             .invalidDirectory:
            .idle
        }
    }
}

enum UINextVisualFixtureSurface: Hashable {
    case root(NavigationSection)
    case libraryEditSheet
    case about
    case menuBarExtra
    case overlay(UINextOverlayFixtureState)
}

struct UINextVisualFixtureScenario: Identifiable {
    let id: String
    let surface: UINextVisualFixtureSurface
    let width: Int
    let height: Int
    let theme: AppearanceTheme
    let localeIdentifier: String
    let displayScale: CGFloat
    let accessibilityMode: UINextAccessibilityFixtureMode
    let serviceState: PetCoreOperationalState
    let agentSource: AgentSource
    let activeSessionCount: Int
    let overlayGroupPresentation: UINextOverlayGroupFixturePresentation
    let overlayControlPresentation: UINextOverlayControlFixturePresentation
    let overlayContentProfile: UINextOverlayContentFixtureProfile
    let configurationSection: BehaviorSettingsSection
    let makerSession: UINextMakerSessionFixture
    let connectionProfile: UINextConnectionFixtureProfile

    init(
        id: String,
        surface: UINextVisualFixtureSurface,
        width: Int,
        height: Int,
        theme: AppearanceTheme,
        localeIdentifier: String,
        displayScale: CGFloat,
        accessibilityMode: UINextAccessibilityFixtureMode,
        serviceState: PetCoreOperationalState = .online,
        agentSource: AgentSource = .codex,
        activeSessionCount: Int = 1,
        overlayGroupPresentation: UINextOverlayGroupFixturePresentation = .automatic,
        overlayControlPresentation: UINextOverlayControlFixturePresentation = .resting,
        overlayContentProfile: UINextOverlayContentFixtureProfile = .singleAgent,
        configurationSection: BehaviorSettingsSection = .appearance,
        makerSession: UINextMakerSessionFixture = .idle,
        connectionProfile: UINextConnectionFixtureProfile = .full
    ) {
        self.id = id
        self.surface = surface
        self.width = width
        self.height = height
        self.theme = theme
        self.localeIdentifier = localeIdentifier
        self.displayScale = displayScale
        self.accessibilityMode = accessibilityMode
        self.serviceState = serviceState
        self.agentSource = agentSource
        self.activeSessionCount = min(8, max(0, activeSessionCount))
        self.overlayGroupPresentation = overlayGroupPresentation
        self.overlayControlPresentation = overlayControlPresentation
        self.overlayContentProfile = overlayContentProfile
        self.configurationSection = configurationSection
        self.makerSession = makerSession
        self.connectionProfile = connectionProfile
    }

    var rootSection: NavigationSection? {
        guard case let .root(section) = surface else { return nil }
        return section
    }

    var overlayState: UINextOverlayFixtureState? {
        guard case let .overlay(state) = surface else { return nil }
        return state
    }

    var accessibilityPresentation: APCVisualAccessibilityPresentation {
        accessibilityMode.presentation
    }

    var fixtureSelections: APCVisualFixtureSelections {
        .init(
            configurationSection: configurationSection,
            connectionSource: agentSource
        )
    }
}

enum UINextVisualFixtureCatalog {
    static let windowWidths = [760, 880, 1_120, 1_440]
    static let themes = AppearanceTheme.allCases
    static let localeIdentifiers = ["en", "zh-Hans"]
    static let displayScales: [CGFloat] = [1, 2]
    static let accessibilityModes = UINextAccessibilityFixtureMode.allCases
    static let serviceStates: [PetCoreOperationalState] = [
        .checking,
        .recovering,
        .online,
        .offline,
        .runtimeMismatch,
        .error,
    ]
    static let agentSources = AgentSource.allCases
    static let activeSessionCounts = [0, 1, 8]
    static let configurationSections = BehaviorSettingsSection.allCases
    static let connectionProfiles = UINextConnectionFixtureProfile.allCases

    /// A compact representative matrix. Every declared axis value is consumed
    /// by at least one renderable scenario without paying the cost of a full
    /// Cartesian product in previews or CI.
    static let regressionScenarios: [UINextVisualFixtureScenario] = [
        UINextVisualFixtureScenario(
            id: "regression.library.compact-checking",
            surface: .root(.library),
            width: 760,
            height: 720,
            theme: .light,
            localeIdentifier: "en",
            displayScale: 1,
            accessibilityMode: .standard,
            serviceState: .checking,
            agentSource: .codex,
            activeSessionCount: 0
        ),
        UINextVisualFixtureScenario(
            id: "regression.maker.narrow-recovering",
            surface: .root(.maker),
            width: 880,
            height: 720,
            theme: .dark,
            localeIdentifier: "zh-Hans",
            displayScale: 2,
            accessibilityMode: .reduceTransparency,
            serviceState: .recovering,
            agentSource: .claudeCode,
            activeSessionCount: 1
        ),
        UINextVisualFixtureScenario(
            id: "regression.configuration.standard-online",
            surface: .root(.configuration),
            width: 1_120,
            height: 720,
            theme: .system,
            localeIdentifier: "en",
            displayScale: 1,
            accessibilityMode: .increasedContrast,
            serviceState: .online,
            agentSource: .pi,
            activeSessionCount: 8,
            configurationSection: .messages
        ),
        UINextVisualFixtureScenario(
            id: "regression.connections.wide-offline",
            surface: .root(.connections),
            width: 1_440,
            height: 800,
            theme: .light,
            localeIdentifier: "zh-Hans",
            displayScale: 2,
            accessibilityMode: .reduceMotion,
            serviceState: .offline,
            agentSource: .opencode,
            activeSessionCount: 0
        ),
        UINextVisualFixtureScenario(
            id: "regression.connections.list-light",
            surface: .root(.connections),
            width: 880,
            height: 720,
            theme: .light,
            localeIdentifier: "zh-Hans",
            displayScale: 2,
            accessibilityMode: .standard,
            agentSource: .claudeCode,
            connectionProfile: .light
        ),
        UINextVisualFixtureScenario(
            id: "regression.connections.compact-missing",
            surface: .root(.connections),
            width: 760,
            height: 720,
            theme: .dark,
            localeIdentifier: "en",
            displayScale: 1,
            accessibilityMode: .standard,
            agentSource: .pi,
            connectionProfile: .missing
        ),
        UINextVisualFixtureScenario(
            id: "regression.connections.list-needs-fix",
            surface: .root(.connections),
            width: 880,
            height: 720,
            theme: .light,
            localeIdentifier: "zh-Hans",
            displayScale: 2,
            accessibilityMode: .standard,
            agentSource: .codex,
            connectionProfile: .needsFix
        ),
        UINextVisualFixtureScenario(
            id: "regression.connections.compact-unverified",
            surface: .root(.connections),
            width: 760,
            height: 720,
            theme: .dark,
            localeIdentifier: "en",
            displayScale: 1,
            accessibilityMode: .standard,
            agentSource: .opencode,
            connectionProfile: .unverified
        ),
        UINextVisualFixtureScenario(
            id: "regression.connections.list-unsupported",
            surface: .root(.connections),
            width: 880,
            height: 720,
            theme: .light,
            localeIdentifier: "zh-Hans",
            displayScale: 2,
            accessibilityMode: .standard,
            agentSource: .claudeCode,
            connectionProfile: .unsupported
        ),
        UINextVisualFixtureScenario(
            id: "regression.connections.compact-busy",
            surface: .root(.connections),
            width: 760,
            height: 720,
            theme: .dark,
            localeIdentifier: "en",
            displayScale: 1,
            accessibilityMode: .standard,
            agentSource: .codex,
            connectionProfile: .busy
        ),
        UINextVisualFixtureScenario(
            id: "regression.connections.list-failure",
            surface: .root(.connections),
            width: 880,
            height: 720,
            theme: .light,
            localeIdentifier: "zh-Hans",
            displayScale: 2,
            accessibilityMode: .standard,
            agentSource: .pi,
            connectionProfile: .failure
        ),
        UINextVisualFixtureScenario(
            id: "regression.connections.compact-invalid-directory",
            surface: .root(.connections),
            width: 760,
            height: 720,
            theme: .dark,
            localeIdentifier: "en",
            displayScale: 1,
            accessibilityMode: .standard,
            agentSource: .opencode,
            connectionProfile: .invalidDirectory
        ),
        UINextVisualFixtureScenario(
            id: "regression.diagnostics.runtime-mismatch",
            surface: .root(.diagnostics),
            width: 880,
            height: 720,
            theme: .dark,
            localeIdentifier: "en",
            displayScale: 2,
            accessibilityMode: .standard,
            serviceState: .runtimeMismatch,
            agentSource: .codex,
            activeSessionCount: 1
        ),
        UINextVisualFixtureScenario(
            id: "regression.about.error",
            surface: .about,
            width: 440,
            height: 360,
            theme: .system,
            localeIdentifier: "zh-Hans",
            displayScale: 1,
            accessibilityMode: .reduceTransparency,
            serviceState: .error,
            agentSource: .claudeCode,
            activeSessionCount: 8
        ),
        UINextVisualFixtureScenario(
            id: "regression.library.edit-sheet",
            surface: .libraryEditSheet,
            width: 780,
            height: 700,
            theme: .light,
            localeIdentifier: "zh-Hans",
            displayScale: 2,
            accessibilityMode: .standard
        ),
        UINextVisualFixtureScenario(
            id: "regression.maker.modification-running",
            surface: .root(.maker),
            width: 1_120,
            height: 720,
            theme: .light,
            localeIdentifier: "zh-Hans",
            displayScale: 2,
            accessibilityMode: .standard,
            makerSession: .modifyingRunning
        ),
        UINextVisualFixtureScenario(
            id: "regression.maker.failed-reference-reselection",
            surface: .root(.maker),
            width: 1_120,
            height: 720,
            theme: .dark,
            localeIdentifier: "en",
            displayScale: 1,
            accessibilityMode: .standard,
            makerSession: .failedNeedsReferences
        ),
        UINextVisualFixtureScenario(
            id: "regression.overlay.codex-idle",
            surface: .overlay(.idle),
            width: 520,
            height: 280,
            theme: .system,
            localeIdentifier: "en",
            displayScale: 1,
            accessibilityMode: .standard,
            agentSource: .codex,
            activeSessionCount: 0
        ),
        UINextVisualFixtureScenario(
            id: "regression.overlay.claude-tool",
            surface: .overlay(.tool),
            width: 520,
            height: 280,
            theme: .dark,
            localeIdentifier: "zh-Hans",
            displayScale: 2,
            accessibilityMode: .reduceTransparency,
            agentSource: .claudeCode,
            activeSessionCount: 1
        ),
        UINextVisualFixtureScenario(
            id: "regression.overlay.pi-waiting",
            surface: .overlay(.waiting),
            width: 520,
            height: 720,
            theme: .light,
            localeIdentifier: "en",
            displayScale: 1,
            accessibilityMode: .increasedContrast,
            agentSource: .pi,
            activeSessionCount: 8
        ),
        UINextVisualFixtureScenario(
            id: "regression.overlay.opencode-failed",
            surface: .overlay(.failed),
            width: 520,
            height: 280,
            theme: .dark,
            localeIdentifier: "zh-Hans",
            displayScale: 2,
            accessibilityMode: .reduceMotion,
            agentSource: .opencode,
            activeSessionCount: 1
        ),
    ]

    /// Every root surface at the product's true minimum content size. The four
    /// binary display-axis combinations form a compact pairwise matrix; the
    /// fifth scenario keeps the remaining root page in the same acceptance set.
    static let minimumWindowAcceptanceScenarios: [UINextVisualFixtureScenario] = [
        UINextVisualFixtureScenario(
            id: "acceptance.minimum-window.library",
            surface: .root(.library),
            width: 760,
            height: 520,
            theme: .light,
            localeIdentifier: "en",
            displayScale: 1,
            accessibilityMode: .standard,
            serviceState: .checking
        ),
        UINextVisualFixtureScenario(
            id: "acceptance.minimum-window.maker",
            surface: .root(.maker),
            width: 760,
            height: 520,
            theme: .dark,
            localeIdentifier: "en",
            displayScale: 2,
            accessibilityMode: .standard,
            serviceState: .recovering
        ),
        UINextVisualFixtureScenario(
            id: "acceptance.minimum-window.configuration",
            surface: .root(.configuration),
            width: 760,
            height: 520,
            theme: .dark,
            localeIdentifier: "zh-Hans",
            displayScale: 1,
            accessibilityMode: .standard,
            serviceState: .online,
            configurationSection: .messages
        ),
        UINextVisualFixtureScenario(
            id: "acceptance.minimum-window.connections",
            surface: .root(.connections),
            width: 760,
            height: 520,
            theme: .light,
            localeIdentifier: "zh-Hans",
            displayScale: 2,
            accessibilityMode: .standard,
            serviceState: .offline,
            agentSource: .opencode
        ),
        UINextVisualFixtureScenario(
            id: "acceptance.minimum-window.diagnostics",
            surface: .root(.diagnostics),
            width: 760,
            height: 520,
            theme: .dark,
            localeIdentifier: "en",
            displayScale: 1,
            accessibilityMode: .standard,
            serviceState: .runtimeMismatch
        ),
    ]

    /// Explicit UI-710/UI-720 acceptance states kept separate from the broad
    /// matrix above. These pair the same non-attention sessions in collapsed
    /// and expanded form, cover mixed Agent groups, then expose the production
    /// hover and resize controls.
    static let overlayAcceptanceScenarios: [UINextVisualFixtureScenario] = [
        UINextVisualFixtureScenario(
            id: "acceptance.overlay.multisession-stacked",
            surface: .overlay(.tool),
            width: 640,
            height: 720,
            theme: .light,
            localeIdentifier: "en",
            displayScale: 1,
            accessibilityMode: .standard,
            agentSource: .codex,
            activeSessionCount: 8,
            overlayGroupPresentation: .stacked
        ),
        UINextVisualFixtureScenario(
            id: "acceptance.overlay.multisession-expanded",
            surface: .overlay(.tool),
            width: 640,
            height: 720,
            theme: .light,
            localeIdentifier: "en",
            displayScale: 1,
            accessibilityMode: .standard,
            agentSource: .codex,
            activeSessionCount: 8,
            overlayGroupPresentation: .expanded
        ),
        UINextVisualFixtureScenario(
            id: "acceptance.overlay.multi-agent-mixed",
            surface: .overlay(.tool),
            width: 640,
            height: 720,
            theme: .light,
            localeIdentifier: "en",
            displayScale: 1,
            accessibilityMode: .standard,
            agentSource: .codex,
            activeSessionCount: 8,
            overlayContentProfile: .mixedAgents
        ),
        UINextVisualFixtureScenario(
            id: "acceptance.overlay.hover-controls",
            surface: .overlay(.tool),
            width: 640,
            height: 360,
            theme: .light,
            localeIdentifier: "en",
            displayScale: 2,
            accessibilityMode: .standard,
            agentSource: .codex,
            activeSessionCount: 2,
            overlayGroupPresentation: .stacked,
            overlayControlPresentation: .hovered
        ),
        UINextVisualFixtureScenario(
            id: "acceptance.overlay.resize-active",
            surface: .overlay(.tool),
            width: 640,
            height: 360,
            theme: .light,
            localeIdentifier: "en",
            displayScale: 2,
            accessibilityMode: .standard,
            agentSource: .codex,
            activeSessionCount: 2,
            overlayGroupPresentation: .stacked,
            overlayControlPresentation: .resizing
        ),
    ]

    static let baselineScenarios: [UINextVisualFixtureScenario] = {
        let roots = NavigationSection.allCases.map { section in
            UINextVisualFixtureScenario(
                id: "root.\(section.rawValue)",
                surface: .root(section),
                width: 1_120,
                height: 720,
                theme: .system,
                localeIdentifier: "zh-Hans",
                displayScale: 2,
                accessibilityMode: .standard
            )
        }
        let auxiliary = [
            UINextVisualFixtureScenario(
                id: "auxiliary.about",
                surface: .about,
                width: 440,
                height: 360,
                theme: .system,
                localeIdentifier: "zh-Hans",
                displayScale: 2,
                accessibilityMode: .standard
            ),
            UINextVisualFixtureScenario(
                id: "auxiliary.menu-bar-extra",
                surface: .menuBarExtra,
                width: 320,
                height: 420,
                theme: .system,
                localeIdentifier: "zh-Hans",
                displayScale: 2,
                accessibilityMode: .standard
            ),
        ]
        let overlays = UINextOverlayFixtureState.allCases.map { state in
            UINextVisualFixtureScenario(
                id: "overlay.\(state.rawValue)",
                surface: .overlay(state),
                width: 520,
                height: 280,
                theme: .system,
                localeIdentifier: "zh-Hans",
                displayScale: 2,
                accessibilityMode: .standard
            )
        }
        return roots + auxiliary + overlays
    }()
}

#if DEBUG
enum UINextVisualFixtureIsolation {
    /// `/dev/null` is a non-directory device, so this child path can never be
    /// a live Unix-domain socket even when the user's real PetCore is running.
    static let petCoreSocketPath = "/dev/null/agent-pet-companion-ui-next-fixture.sock"
    static let allowsHitTesting = false

    static var petCoreClient: PetCoreClient {
        PetCoreClient(socketPath: petCoreSocketPath)
    }
}

enum UINextOverlayBubbleLayoutMetadata {
    static let markerIdentifierPrefix = "fixture.overlay.bubble-layout."

    static func markerIdentifier(for contentID: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(markerIdentifierPrefix + contentID)
    }

    static func contentID(
        from identifier: NSUserInterfaceItemIdentifier?
    ) -> String? {
        guard
            let rawValue = identifier?.rawValue,
            rawValue.hasPrefix(markerIdentifierPrefix)
        else {
            return nil
        }
        return String(rawValue.dropFirst(markerIdentifierPrefix.count))
    }
}

struct UINextOverlayBubbleLayoutMarker: NSViewRepresentable {
    let contentID: String

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        view.identifier = UINextOverlayBubbleLayoutMetadata.markerIdentifier(
            for: contentID
        )
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        view.identifier = UINextOverlayBubbleLayoutMetadata.markerIdentifier(
            for: contentID
        )
    }
}

enum UINextVisualFixtureData {
    static let repositoryRoot: URL = {
        (0 ..< 6).reduce(URL(fileURLWithPath: #filePath)) { url, _ in
            url.deletingLastPathComponent()
        }
    }()

    private static func assetRoot(_ name: String) -> URL {
        repositoryRoot.appendingPathComponent(
            "ui-next/codex/assets/\(name)",
            isDirectory: true
        )
    }

    /// Three production-shaped Agent groups plus the bounded-overflow summary.
    /// The groups intentionally mix collapsed and expanded presentation while
    /// waiting/failed rows exercise the production attention-pinning rule.
    static var mixedAgentBubbleContents: [OverlayBubbleContent] {
        [
            mixedAgentBubbleContent(
                source: .codex,
                eventType: .tool,
                count: 3,
                isExpanded: false
            ),
            mixedAgentBubbleContent(
                source: .claudeCode,
                eventType: .waiting,
                count: 3,
                isExpanded: true
            ),
            mixedAgentBubbleContent(
                source: .pi,
                eventType: .failed,
                count: 2,
                isExpanded: false
            ),
            .omittedSummary(count: 3),
        ]
    }

    private static func mixedAgentBubbleContent(
        source: AgentSource,
        eventType: AgentEventKind,
        count: Int,
        isExpanded: Bool
    ) -> OverlayBubbleContent {
        let sessions = (0 ..< count).map { index in
            OverlaySessionContent(
                id: "fixture-mixed-\(source.rawValue)-\(index)",
                source: source,
                sessionID: "fixture-mixed-session-\(source.rawValue)-\(index)",
                eventType: eventType,
                sessionTitle: APCLocalization.format(
                    .overlaySessionTitleFormat,
                    "\(source.shortTitle) \(index + 1)"
                ),
                messageText: APCLocalizedPresentation.eventTitle(eventType),
                statusText: APCLocalizedPresentation.eventTitle(eventType),
                actionLabel: APCLocalization.text(.overlayActionOpen)
            )
        }
        return OverlayBubbleContent(
            id: "fixture-mixed-agent-\(source.rawValue)",
            source: source,
            agentName: source.title,
            sessions: sessions,
            isExpanded: isExpanded
        )
    }

    private static let xingwuAssetRoot = assetRoot("xingwu")

    private static var libraryBytebud: PetSummary {
        var pet = OverlayCoreFixturePet.bytebud
        pet.active = false
        return pet
    }

    static let pets = [
        PetSummary(
            id: "pet_xingwutuanzi",
            name: "星雾团子",
            style: StylePreset.semiRealistic.rawValue,
            quality: .high,
            renderSize: QualityLevel.high.renderSize,
            petpackPath: xingwuAssetRoot
                .appendingPathComponent(PetAssetLocator.uiNextFixturePetpackMarker)
                .path,
            coverPath: xingwuAssetRoot
                .appendingPathComponent("assets/preview/cover.png")
                .path,
            origin: .verifiedSkillSource,
            generator: "agent-pet-companion.release-inventory",
            provenance: "apc.bundled-pets.v1",
            revisionID: "rev_fixture_xingwu",
            revisionCount: 1,
            active: true,
            createdAt: "2026-07-21T00:00:00Z"
        ),
        libraryBytebud,
    ]

    static let editableBytebud: PetSummary = {
        var pet = OverlayCoreFixturePet.bytebud
        pet.id = "pet_bytebud_custom"
        pet.name = "Bytebud 工作副本"
        pet.origin = .generatedByPetcoreJob
        pet.generator = "agent-pet-companion"
        pet.provenance = "apc.generation-job.v1"
        pet.revisionID = "rev_fixture_bytebud_current"
        pet.revisionCount = 2
        pet.active = false
        return pet
    }()

    static let editableBytebudHistory = PetHistorySnapshot(
        petID: editableBytebud.id,
        currentRevisionID: "rev_fixture_bytebud_current",
        revisions: [
            PetRevisionHistoryRecord(
                revisionID: "rev_fixture_bytebud_current",
                current: true,
                validated: true,
                coverPath: editableBytebud.coverPath,
                validationSummary: GenerationValidationSummary(
                    ok: true,
                    stateCount: 7,
                    frameCount: 84,
                    warningCount: 0
                )
            ),
            PetRevisionHistoryRecord(
                revisionID: "rev_fixture_bytebud_previous",
                current: false,
                validated: true,
                coverPath: editableBytebud.coverPath,
                validationSummary: GenerationValidationSummary(
                    ok: true,
                    stateCount: 7,
                    frameCount: 84,
                    warningCount: 0
                )
            ),
        ],
        jobs: [
            GenerationJobHistoryRecord(
                jobID: "job_fixture_bytebud_modify",
                status: .completed,
                operation: .modify,
                baselineRevisionID: "rev_fixture_bytebud_previous",
                revisionID: "rev_fixture_bytebud_current",
                validationSummary: GenerationValidationSummary(
                    ok: true,
                    stateCount: 7,
                    frameCount: 84,
                    warningCount: 0
                ),
                createdAt: "2026-07-21T08:00:00Z",
                updatedAt: "2026-07-21T08:05:00Z"
            ),
        ]
    )

    static func generationRestore(
        for fixture: UINextMakerSessionFixture
    ) -> GenerationSessionRestore? {
        switch fixture {
        case .idle:
            return nil
        case .modifyingRunning:
            let form = GenerationForm(
                description: "保留字节芽的轮廓，只调整 tool 状态的动作节奏。",
                style: StylePreset.pixel.rawValue,
                quality: .high,
                referenceImages: []
            )
            return GenerationSessionRestore(
                state: .running,
                jobID: "job_fixture_bytebud_running",
                submittedForm: form,
                messages: [
                    GenerationMessage(
                        id: "message_fixture_user",
                        role: "user",
                        content: form.description,
                        progress: 0,
                        createdAt: "2026-07-21T09:00:00Z"
                    ),
                    GenerationMessage(
                        id: "message_fixture_assistant",
                        role: "assistant",
                        content: "正在生成新的不可变 revision；当前已提交基线保持只读。",
                        progress: 0.62,
                        createdAt: "2026-07-21T09:00:04Z"
                    ),
                ],
                progress: 0.62,
                messageRevision: "2",
                operation: .modify,
                resultPetID: editableBytebud.id,
                baselineRevisionID: "rev_fixture_bytebud_current"
            )
        case .failedNeedsReferences:
            let form = GenerationForm(
                description: "A tiny data-sprite with translucent fins.",
                style: StylePreset.modern.rawValue,
                quality: .high,
                referenceImages: []
            )
            return GenerationSessionRestore(
                state: .failed,
                jobID: "job_fixture_reference_reselection",
                submittedForm: form,
                messages: [GenerationMessage(
                    id: "message_fixture_reference_failure",
                    role: "assistant",
                    content: "The safe reference copies are no longer available.",
                    progress: 1,
                    createdAt: "2026-07-21T09:05:00Z",
                    kind: "generation_failed"
                )],
                progress: 1,
                messageRevision: "3",
                referenceReselectionCount: 2
            )
        }
    }

    static let invalidProjectDirectoryPath = "/fixture/projects/missing-agent-workspace"

    static let connections = connections(for: .full, selectedSource: .codex)

    static func connections(
        for profile: UINextConnectionFixtureProfile,
        selectedSource: AgentSource
    ) -> [AgentConnectionStatus] {
        AgentSource.allCases.map { source in
            connectionStatus(
                source: source,
                profile: source == selectedSource ? profile : .full
            )
        }
    }

    static func connectionOperationState(
        for profile: UINextConnectionFixtureProfile,
        selectedSource: AgentSource
    ) -> AgentConnectionOperationState {
        switch profile.operationPresentation {
        case .idle:
            .idle
        case .busy:
            .running(AgentConnectionOperation(kind: .check, sources: [selectedSource]))
        case .failure:
            .failed(AgentConnectionOperationFailure(
                operation: AgentConnectionOperation(kind: .repair, sources: [selectedSource]),
                reason: .partialFailure
            ))
        }
    }

    static func connectionCheckCWD(
        for profile: UINextConnectionFixtureProfile
    ) -> String? {
        profile == .invalidDirectory ? invalidProjectDirectoryPath : nil
    }

    private static func connectionStatus(
        source: AgentSource,
        profile: UINextConnectionFixtureProfile
    ) -> AgentConnectionStatus {
        switch profile {
        case .full, .busy, .failure:
            connectionStatus(
                source: source,
                item: ConnectionCheckItem(
                    code: .eventDelivery,
                    name: "Event delivery",
                    status: .ok,
                    detail: "Typed local event delivery completed a bounded round trip."
                ),
                verification: AgentVerification(
                    status: .verified,
                    title: "Agent event verified",
                    detail: "A bounded fixture event completed the local round trip.",
                    lastVerifiedAt: "2026-07-21T00:00:00Z",
                    lastEvent: "tool"
                )
            )
        case .light:
            connectionStatus(
                source: source,
                item: ConnectionCheckItem(
                    code: .agentCLI,
                    name: "Agent CLI",
                    status: .ok,
                    detail: "The Agent CLI location is available."
                ),
                checkMode: .light,
                verification: AgentVerification(
                    status: .notRequired,
                    title: "Runtime verification not requested",
                    detail: "This fixture intentionally represents a light check."
                )
            )
        case .missing:
            connectionStatus(
                source: source,
                item: ConnectionCheckItem(
                    code: .agentCLI,
                    name: "Agent CLI",
                    status: .missing,
                    detail: "The Agent CLI was not found on the bounded fixture path.",
                    recoveryAction: .recheck
                ),
                installPaths: [],
                connectorInstalled: false,
                verification: AgentVerification(
                    status: .actionRequired,
                    title: "Agent CLI required",
                    detail: "Install or locate the Agent CLI, then check again."
                )
            )
        case .needsFix:
            connectionStatus(
                source: source,
                item: ConnectionCheckItem(
                    code: .managedConnector,
                    name: "Managed connector",
                    status: .needsFix,
                    detail: "The managed connector differs from the supported template.",
                    recoveryAction: .confirmManagedRepair
                ),
                verification: AgentVerification(
                    status: .actionRequired,
                    title: "Managed repair available",
                    detail: "Review and confirm the bounded managed repair."
                ),
                repairableConnectorIssue: true
            )
        case .unverified:
            connectionStatus(
                source: source,
                item: ConnectionCheckItem(
                    code: .hostVerification,
                    name: "Host verification",
                    status: .unverified,
                    detail: "No Agent-side event has completed the verification round trip.",
                    recoveryAction: .testChannel
                ),
                verification: AgentVerification(
                    status: .unverified,
                    title: "Agent-side verification pending",
                    detail: "Trigger one bounded event from the selected Agent."
                )
            )
        case .unsupported:
            connectionStatus(
                source: source,
                item: ConnectionCheckItem(
                    code: .hostRuntime,
                    name: "Host runtime",
                    status: .unsupported,
                    detail: "This host runtime cannot expose the optional verification channel."
                ),
                verification: AgentVerification(
                    status: .notRequired,
                    title: "Verification unavailable",
                    detail: "The optional host verification channel is unsupported."
                )
            )
        case .invalidDirectory:
            connectionStatus(
                source: source,
                item: ConnectionCheckItem(
                    code: .projectDirectory,
                    name: "Project directory",
                    status: .missing,
                    detail: "The selected project directory is unavailable.",
                    recoveryAction: .chooseProjectDirectory
                ),
                installPaths: [],
                connectorInstalled: false,
                verification: AgentVerification(
                    status: .actionRequired,
                    title: "Choose a valid project directory",
                    detail: "The full check could not inspect the selected directory.",
                    actionDetail: "Choose another directory and run the full check again.",
                    checkedCWD: invalidProjectDirectoryPath
                )
            )
        }
    }

    private static func connectionStatus(
        source: AgentSource,
        item: ConnectionCheckItem,
        installPaths: [String]? = nil,
        connectorInstalled: Bool = true,
        checkMode: ConnectionCheckMode = .runtime,
        verification: AgentVerification,
        repairableConnectorIssue: Bool = false
    ) -> AgentConnectionStatus {
        AgentConnectionStatus(
            source: source,
            items: [item],
            installPaths: installPaths ?? ["/fixture/\(source.rawValue)"],
            connectorInstalled: connectorInstalled,
            checkMode: checkMode,
            checkedAt: "2026-07-21T00:00:00Z",
            verification: verification,
            capabilities: AgentConnectorCapabilities(
                contractVersion: "\(source.rawValue)-ui-next-fixture-v1",
                auditedEvents: ["start", "tool", "waiting", "review", "done", "failed"],
                subscribedEvents: ["start", "tool", "waiting", "review", "done", "failed"],
                mappedInformation: ["source", "session_id", "event_type", "title", "detail"],
                privacyExclusions: ["credentials", "tokens", "cookies"],
                repairableConnectorIssue: repairableConnectorIssue,
                managedPathConflict: false,
                canUninstallManagedConnector: false
            )
        )
    }

    static let event = AgentEvent(
        id: "fixture-recent-event",
        source: .codex,
        sessionID: "fixture-session",
        eventType: .tool,
        title: "Working",
        detail: "Updating the UI Next workspace",
        createdAt: "2026-07-21T00:00:00Z"
    )
}

@MainActor
struct UINextVisualFixtureView: View {
    let scenario: UINextVisualFixtureScenario
    @StateObject private var store: AppStore

    init(scenario: UINextVisualFixtureScenario) {
        self.scenario = scenario
        _store = StateObject(wrappedValue: Self.makeStore(for: scenario))
    }

    var body: some View {
        fixtureSurface
            .frame(width: CGFloat(scenario.width), height: CGFloat(scenario.height))
            .environment(\.locale, Locale(identifier: scenario.localeIdentifier))
            .environment(\.displayScale, scenario.displayScale)
            .environment(
                \.apcVisualAccessibilityOverrides,
                scenario.accessibilityMode.overrides
            )
            .environment(\.apcVisualFixtureSelections, scenario.fixtureSelections)
            .preferredColorScheme(colorScheme)
            .accessibilityIdentifier(
                "fixture.accessibility.\(scenario.accessibilityMode.rawValue)"
            )
            .allowsHitTesting(UINextVisualFixtureIsolation.allowsHitTesting)
    }

    @ViewBuilder
    private var fixtureSurface: some View {
        switch scenario.surface {
        case .root:
            ContentView()
                .environmentObject(store)
                .apcAppearanceTheme(scenario.theme)
        case .libraryEditSheet:
            UINextPetHistorySheetFixture(pet: UINextVisualFixtureData.editableBytebud)
                .environmentObject(store)
                .apcAppearanceTheme(scenario.theme)
        case .about:
            AboutView(store: store)
                .apcAppearanceTheme(scenario.theme)
        case .menuBarExtra:
            UINextMenuBarFixtureSurface(store: store)
                .apcAppearanceTheme(scenario.theme)
        case let .overlay(state):
            OverlayCoreFixtureView(
                state: state,
                theme: scenario.theme,
                source: scenario.agentSource,
                activeSessionCount: scenario.activeSessionCount,
                groupPresentation: scenario.overlayGroupPresentation,
                controlPresentation: scenario.overlayControlPresentation,
                mixedAgentBubbleContents: scenario.overlayContentProfile == .mixedAgents
                    ? UINextVisualFixtureData.mixedAgentBubbleContents
                    : nil
            )
            .environmentObject(store)
        }
    }

    private var colorScheme: ColorScheme? {
        switch scenario.theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static func makeStore(for scenario: UINextVisualFixtureScenario) -> AppStore {
        let store = AppStore(
            client: UINextVisualFixtureIsolation.petCoreClient,
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            )
        )
        store.selection = scenario.rootSection ?? .library
        store.behavior.appearanceTheme = scenario.theme
        store.updateGenerationDescription(
            "一只安静陪伴编程、动作清晰、适合透明桌面背景的小型数字宠物"
        )
        store.selectGenerationStyle(.pixel)
        store.selectGenerationQuality(.high)
        let includesEditablePet = scenario.surface == .libraryEditSheet
            || scenario.makerSession != .idle
        let fixturePets = includesEditablePet
            ? UINextVisualFixtureData.pets + [UINextVisualFixtureData.editableBytebud]
            : UINextVisualFixtureData.pets
        let fixtureHistories = includesEditablePet
            ? [
                UINextVisualFixtureData.editableBytebud.id:
                    UINextVisualFixtureData.editableBytebudHistory,
            ]
            : [:]
        store.configureForUINextVisualFixture(
            pets: fixturePets,
            connections: UINextVisualFixtureData.connections(
                for: scenario.connectionProfile,
                selectedSource: scenario.agentSource
            ),
            events: [UINextVisualFixtureData.event],
            operationalState: scenario.serviceState,
            connectionOperationState: UINextVisualFixtureData.connectionOperationState(
                for: scenario.connectionProfile,
                selectedSource: scenario.agentSource
            ),
            connectionCheckCWD: UINextVisualFixtureData.connectionCheckCWD(
                for: scenario.connectionProfile
            ),
            petHistories: fixtureHistories,
            generationRestore: UINextVisualFixtureData.generationRestore(
                for: scenario.makerSession
            )
        )
        return store
    }
}

struct UINextRenderedVisualFixture {
    let id: String
    let logicalSize: CGSize
    let pixelWidth: Int
    let pixelHeight: Int
    let resolvedLocaleIdentifier: String
    let localizationProbe: [String]
    let accessibilityPresentation: APCVisualAccessibilityPresentation
    let offscreenHostState: UINextOffscreenHostState
    let overlayBubbleRegions: [UINextOverlayBubbleRenderRegion]
    let pngData: Data
}

struct UINextOverlayBubbleRenderRegion: Equatable {
    let contentID: String
    /// Top-left logical coordinates matching the rendered PNG.
    let frame: CGRect
}

struct UINextOffscreenHostState: Equatable {
    let wasVisible: Bool
    let wasKeyWindow: Bool
    let wasMainWindow: Bool
    let intersectedAnyScreen: Bool
    let preservedApplicationKeyWindow: Bool
    let preservedApplicationMainWindow: Bool
    let preservedApplicationActivation: Bool
}

enum UINextVisualFixtureRendererError: Error {
    case invalidPixelSize
    case bitmapAllocationFailed
    case windowCaptureUnavailable
    case windowCaptureFailed
    case pngEncodingFailed
}

private typealias UINextWindowCaptureFunction = @convention(c) (
    CGRect,
    CGWindowListOption,
    CGWindowID,
    CGWindowImageOption
) -> Unmanaged<CGImage>?

/// Performs the complete offscreen layout and bitmap transaction inside the
/// task-local locale scope. A never-fronted borderless window, ordered behind
/// other windows entirely outside every screen, gives AppKit-backed SwiftUI
/// controls their real lifecycle without taking focus or presenting UI.
@MainActor
enum UINextVisualFixtureRenderer {
    static func render(
        _ scenario: UINextVisualFixtureScenario
    ) throws -> UINextRenderedVisualFixture {
        try APCLocalizationFixtureScope.withLocale(scenario.localeIdentifier) {
            let logicalSize = CGSize(width: scenario.width, height: scenario.height)
            let pixelWidth = Int((CGFloat(scenario.width) * scenario.displayScale).rounded())
            let pixelHeight = Int((CGFloat(scenario.height) * scenario.displayScale).rounded())
            guard pixelWidth > 0, pixelHeight > 0 else {
                throw UINextVisualFixtureRendererError.invalidPixelSize
            }

            let appearance = APCApplicationAppearance.nsAppearance(for: scenario.theme)
            let application = NSApplication.shared
            let keyWindowBeforeRender = application.keyWindow
            let mainWindowBeforeRender = application.mainWindow
            let applicationWasActive = application.isActive
            let controller = UINextOffscreenFixtureViewController(
                scenario: scenario,
                logicalSize: logicalSize
            )
            let window = UINextNonActivatingOffscreenWindow(
                contentRect: NSRect(
                    origin: offscreenOrigin(for: logicalSize),
                    size: logicalSize
                ),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior = [.transient, .ignoresCycle]
            window.appearance = appearance
            window.backgroundColor = scenario.requiresOpaqueCanvas
                ? .windowBackgroundColor
                : .clear
            window.isOpaque = scenario.requiresOpaqueCanvas
            window.contentViewController = controller
            window.setContentSize(logicalSize)
            // Native List and Button hosts only complete their AppKit drawing
            // lifecycle once their window is ordered. Ordering an interaction-
            // disabled window behind all peers at a coordinate outside every
            // attached display realizes those controls without presenting UI.
            window.orderBack(nil)
            _ = RunLoop.main.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.01)
            )
            defer {
                window.orderOut(nil)
                window.contentViewController = nil
                window.close()
            }

            let host = controller.view
            host.frame = NSRect(origin: .zero, size: logicalSize)
            host.appearance = appearance
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            controller.hostingView.needsLayout = true
            controller.hostingView.layoutSubtreeIfNeeded()
            host.needsDisplay = true
            controller.hostingView.needsDisplay = true
            controller.hostingView.displayIfNeededIgnoringOpacity()
            host.displayIfNeededIgnoringOpacity()
            controller.hostingView.layoutSubtreeIfNeeded()
            controller.hostingView.displayIfNeededIgnoringOpacity()

            let offscreenHostState = UINextOffscreenHostState(
                wasVisible: window.isVisible,
                wasKeyWindow: window.isKeyWindow,
                wasMainWindow: window.isMainWindow,
                intersectedAnyScreen: NSScreen.screens.contains {
                    window.frame.intersects($0.frame)
                },
                preservedApplicationKeyWindow: application.keyWindow === keyWindowBeforeRender,
                preservedApplicationMainWindow: application.mainWindow === mainWindowBeforeRender,
                preservedApplicationActivation: application.isActive == applicationWasActive
            )

            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bitmapFormat: [],
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else {
                throw UINextVisualFixtureRendererError.bitmapAllocationFailed
            }
            bitmap.size = logicalSize
            try captureWindowServerComposite(
                window,
                into: bitmap,
                logicalSize: logicalSize
            )
            let outputBitmap: NSBitmapImageRep
            if scenario.requiresOpaqueCanvas {
                outputBitmap = try opaqueComposite(
                    bitmap,
                    logicalSize: logicalSize,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    appearance: appearance
                )
            } else {
                outputBitmap = bitmap
            }
            guard let pngData = outputBitmap.representation(
                using: .png,
                properties: [:]
            ) else {
                throw UINextVisualFixtureRendererError.pngEncodingFailed
            }

            return UINextRenderedVisualFixture(
                id: scenario.id,
                logicalSize: logicalSize,
                pixelWidth: outputBitmap.pixelsWide,
                pixelHeight: outputBitmap.pixelsHigh,
                resolvedLocaleIdentifier: APCLocalization.interfaceLocaleIdentifier,
                localizationProbe: [
                    APCLocalization.text(.navigationLibrary),
                    APCLocalization.text(.appActionAbout),
                ],
                accessibilityPresentation: scenario.accessibilityPresentation,
                offscreenHostState: offscreenHostState,
                overlayBubbleRegions: controller.overlayBubbleRegions,
                pngData: pngData
            )
        }
    }

    private static func offscreenOrigin(for logicalSize: CGSize) -> CGPoint {
        let screenFrames = NSScreen.screens.map(\.frame)
        let minimumX = screenFrames.map(\.minX).min() ?? 0
        let minimumY = screenFrames.map(\.minY).min() ?? 0
        return CGPoint(
            x: minimumX - logicalSize.width - 2_048,
            y: minimumY - logicalSize.height - 2_048
        )
    }

    private static func opaqueComposite(
        _ source: NSBitmapImageRep,
        logicalSize: CGSize,
        pixelWidth: Int,
        pixelHeight: Int,
        appearance: NSAppearance?
    ) throws -> NSBitmapImageRep {
        guard let output = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw UINextVisualFixtureRendererError.bitmapAllocationFailed
        }
        output.size = logicalSize
        guard let context = NSGraphicsContext(bitmapImageRep: output) else {
            throw UINextVisualFixtureRendererError.bitmapAllocationFailed
        }
        let bounds = NSRect(origin: .zero, size: logicalSize)
        let draw = {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            source.draw(
                in: bounds,
                from: bounds,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: false,
                hints: nil
            )
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return output
    }

    /// View-cache, CALayer and PDF rendering omit WindowServer-owned native
    /// control surfaces (notably SwiftUI List rows and some Button labels).
    /// Capturing this process's one interaction-disabled window by number
    /// preserves the composed hierarchy without reading any other window.
    private static func captureWindowServerComposite(
        _ window: NSWindow,
        into bitmap: NSBitmapImageRep,
        logicalSize: CGSize
    ) throws {
        // CGWindowListCreateImage is deprecated in the macOS 14 SDK and the
        // newer async ScreenCaptureKit API can require screen-recording
        // consent in CI. Resolve the public compatibility symbol only in this
        // DEBUG fixture path, and fail explicitly if a future OS removes it.
        // Darwin does not import the RTLD_DEFAULT macro; its documented
        // sentinel value is -2 on macOS.
        let defaultSymbolHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(defaultSymbolHandle, "CGWindowListCreateImage") else {
            throw UINextVisualFixtureRendererError.windowCaptureUnavailable
        }
        let capture = unsafeBitCast(
            symbol,
            to: UINextWindowCaptureFunction.self
        )
        guard let retainedWindowImage = capture(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            throw UINextVisualFixtureRendererError.windowCaptureFailed
        }
        let windowImage = retainedWindowImage.takeRetainedValue()
        guard windowImage.width > 0, windowImage.height > 0 else {
            throw UINextVisualFixtureRendererError.windowCaptureFailed
        }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw UINextVisualFixtureRendererError.bitmapAllocationFailed
        }
        let graphicsContext = context.cgContext
        let bounds = CGRect(origin: .zero, size: logicalSize)
        graphicsContext.saveGState()
        graphicsContext.clear(bounds)
        graphicsContext.interpolationQuality = .high
        graphicsContext.draw(windowImage, in: bounds)
        graphicsContext.restoreGState()
        context.flushGraphics()
    }

}

private final class UINextNonActivatingOffscreenWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension UINextVisualFixtureScenario {
    var requiresOpaqueCanvas: Bool {
        switch surface {
        case .root, .libraryEditSheet, .about, .menuBarExtra:
            true
        case .overlay:
            false
        }
    }
}

@MainActor
private final class UINextOffscreenFixtureViewController: NSViewController {
    let hostingController: NSHostingController<UINextVisualFixtureView>

    var hostingView: NSView {
        hostingController.view
    }

    var overlayBubbleRegions: [UINextOverlayBubbleRenderRegion] {
        let canvasBounds = view.bounds
        var framesByContentID: [String: CGRect] = [:]

        func collect(from candidate: NSView) {
            if let contentID = UINextOverlayBubbleLayoutMetadata.contentID(
                from: candidate.identifier
            ) {
                let frame = candidate.convert(candidate.bounds, to: view).standardized
                let topLeftFrame = CGRect(
                    x: frame.minX,
                    y: canvasBounds.height - frame.maxY,
                    width: frame.width,
                    height: frame.height
                )
                if let existing = framesByContentID[contentID] {
                    if topLeftFrame.width * topLeftFrame.height
                        > existing.width * existing.height
                    {
                        framesByContentID[contentID] = topLeftFrame
                    }
                } else {
                    framesByContentID[contentID] = topLeftFrame
                }
            }
            candidate.subviews.forEach(collect)
        }

        collect(from: view)
        return framesByContentID
            .map {
                UINextOverlayBubbleRenderRegion(
                    contentID: $0.key,
                    frame: $0.value
                )
            }
            .sorted {
                if $0.frame.minY == $1.frame.minY {
                    return $0.contentID < $1.contentID
                }
                return $0.frame.minY < $1.frame.minY
            }
    }

    init(scenario: UINextVisualFixtureScenario, logicalSize: CGSize) {
        hostingController = NSHostingController(
            rootView: UINextVisualFixtureView(scenario: scenario)
        )
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = logicalSize
        view = UINextOffscreenCanvasView(
            frame: NSRect(origin: .zero, size: logicalSize),
            drawsOpaqueBackground: scenario.requiresOpaqueCanvas
        )
        addChild(hostingController)
        hostingView.frame = view.bounds
        hostingView.autoresizingMask = [.width, .height]
        view.addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

private final class UINextOffscreenCanvasView: NSView {
    private let drawsOpaqueBackground: Bool

    init(frame frameRect: NSRect, drawsOpaqueBackground: Bool) {
        self.drawsOpaqueBackground = drawsOpaqueBackground
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isOpaque: Bool {
        drawsOpaqueBackground
    }

    override func draw(_ dirtyRect: NSRect) {
        guard drawsOpaqueBackground else { return }
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

enum UINextVisualFixtureEvidenceExporterError: Error, Equatable {
    case outputDirectoryMustBeAbsolute
    case outputDirectoryMustNotBeFilesystemRoot
    case outputDirectoryMustBeOutsideRepository
    case outputPathIsNotDirectory
    case invalidScenarioIdentifier(String)
    case duplicateOutputFileName(String)
}

/// Opt-in PNG evidence export for local review and CI artifacts. Normal test
/// runs return before rendering or touching the filesystem; callers opt in by
/// setting `APC_VISUAL_OUTPUT_DIR` to an absolute path outside the repository.
enum UINextVisualFixtureEvidenceExporter {
    static let environmentKey = "APC_VISUAL_OUTPUT_DIR"
    static let repositoryRoot = UINextVisualFixtureData.repositoryRoot

    /// Baseline surfaces come first, followed by matrix-specific variants.
    /// ID-based first-wins deduplication keeps filenames and output order
    /// stable if a representative scenario also becomes a baseline later.
    static let evidenceScenarios: [UINextVisualFixtureScenario] = {
        var seenIDs = Set<String>()
        return (
            UINextVisualFixtureCatalog.baselineScenarios
                + UINextVisualFixtureCatalog.regressionScenarios
                + UINextVisualFixtureCatalog.minimumWindowAcceptanceScenarios
                + UINextVisualFixtureCatalog.overlayAcceptanceScenarios
        ).filter { scenario in
            seenIDs.insert(scenario.id).inserted
        }
    }()

    static func outputDirectory(
        from environment: [String: String],
        fileManager: FileManager = .default
    ) throws -> URL? {
        guard let value = environment[environmentKey] else { return nil }
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        guard (path as NSString).isAbsolutePath else {
            throw UINextVisualFixtureEvidenceExporterError.outputDirectoryMustBeAbsolute
        }

        let outputURL = canonicalFileURL(for: path, isDirectory: true)
        guard outputURL.path != "/" else {
            throw UINextVisualFixtureEvidenceExporterError
                .outputDirectoryMustNotBeFilesystemRoot
        }
        let canonicalRepositoryRoot = repositoryRoot
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard !contains(outputURL, inside: canonicalRepositoryRoot) else {
            throw UINextVisualFixtureEvidenceExporterError
                .outputDirectoryMustBeOutsideRepository
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: outputURL.path, isDirectory: &isDirectory),
           !isDirectory.boolValue
        {
            throw UINextVisualFixtureEvidenceExporterError.outputPathIsNotDirectory
        }
        return outputURL
    }

    static func stableFileName(
        for scenario: UINextVisualFixtureScenario
    ) throws -> String {
        var slug = ""
        var needsSeparator = false
        for scalar in scenario.id.lowercased().unicodeScalars {
            let isASCIILetter = (97 ... 122).contains(scalar.value)
            let isASCIIDigit = (48 ... 57).contains(scalar.value)
            if isASCIILetter || isASCIIDigit {
                if needsSeparator, !slug.isEmpty {
                    slug.append("-")
                }
                slug.unicodeScalars.append(scalar)
                needsSeparator = false
            } else {
                needsSeparator = true
            }
        }
        guard !slug.isEmpty else {
            throw UINextVisualFixtureEvidenceExporterError
                .invalidScenarioIdentifier(scenario.id)
        }
        return "\(slug).png"
    }

    /// Usage:
    /// `APC_VISUAL_OUTPUT_DIR=/absolute/output swift test --filter UINextVisualRendererTests`
    @MainActor
    static func exportIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        scenarios: [UINextVisualFixtureScenario] = evidenceScenarios,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        guard let directory = try outputDirectory(
            from: environment,
            fileManager: fileManager
        ) else {
            return []
        }
        guard !scenarios.isEmpty else { return [] }

        var outputNames = Set<String>()
        let namedScenarios = try scenarios.map { scenario in
            let fileName = try stableFileName(for: scenario)
            guard outputNames.insert(fileName).inserted else {
                throw UINextVisualFixtureEvidenceExporterError
                    .duplicateOutputFileName(fileName)
            }
            return (scenario, fileName)
        }

        // Finish every AppKit render before creating the output directory so a
        // renderer failure cannot leave a partial evidence set behind.
        let renderedFixtures = try namedScenarios.map { scenario, fileName in
            (try UINextVisualFixtureRenderer.render(scenario), fileName)
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        return try renderedFixtures.map { rendered, fileName in
            let outputURL = directory.appendingPathComponent(
                fileName,
                isDirectory: false
            )
            try rendered.pngData.write(to: outputURL, options: .atomic)
            return outputURL
        }
    }

    private static func canonicalFileURL(
        for path: String,
        isDirectory: Bool
    ) -> URL {
        URL(fileURLWithPath: path, isDirectory: isDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private static func contains(_ candidate: URL, inside root: URL) -> Bool {
        candidate.path == root.path
            || candidate.path.hasPrefix(root.path + "/")
    }
}

private struct UINextMenuBarFixtureSurface: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AppStatusMenuContent(store: store, performsActions: false)
        }
        .buttonStyle(.plain)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("fixture.menu-bar-extra")
    }
}

/// Xcode previews display the exact bitmap produced by the executable fixture
/// renderer, so locale, accessibility, size, scale, and theme cannot silently
/// fall back to the preview host's process-wide settings.
@MainActor
private struct UINextRenderedFixturePreview: View {
    let scenario: UINextVisualFixtureScenario
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: CGFloat(scenario.width), height: CGFloat(scenario.height))
        .background(Color(nsColor: .windowBackgroundColor))
        .allowsHitTesting(false)
        .task(id: scenario.id) {
            guard image == nil,
                  let rendered = try? UINextVisualFixtureRenderer.render(scenario)
            else { return }
            image = NSImage(data: rendered.pngData)
        }
    }
}

struct UINextVisualFixtures_Previews: PreviewProvider {
    @MainActor
    static var previews: some View {
        ForEach(
            UINextVisualFixtureCatalog.baselineScenarios
                + UINextVisualFixtureCatalog.regressionScenarios
                + UINextVisualFixtureCatalog.minimumWindowAcceptanceScenarios
        ) { scenario in
            UINextRenderedFixturePreview(scenario: scenario)
                .previewDisplayName(scenario.id)
                .previewLayout(.sizeThatFits)
        }
    }
}
#endif
