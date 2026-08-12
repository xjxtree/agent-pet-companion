import AgentPetCompanionCore
import Foundation
import SwiftUI

enum APCLocalizationTable: String, CaseIterable, Sendable {
    case common = "Common"
    case petLibrary = "PetLibrary"
    case maker = "Maker"
    case connections = "Connections"
    case overlay = "Overlay"
    case settings = "Settings"
    case diagnostics = "Diagnostics"
}

struct APCLocalizationKey: Hashable, CaseIterable, Sendable {
    let rawValue: String
    let table: APCLocalizationTable

    init(_ rawValue: String, table: APCLocalizationTable) {
        self.rawValue = rawValue
        self.table = table
    }

    static let allCases: [APCLocalizationKey] =
        commonCases
        + petLibraryCases
        + makerCases
        + connectionsCases
        + overlayCases
        + settingsCases
        + diagnosticsCases
}

private final class APCLocalizationPreference: @unchecked Sendable {
    private let lock = NSLock()
    private var language: InterfaceLanguage = .system

    func read() -> InterfaceLanguage {
        lock.lock()
        defer { lock.unlock() }
        return language
    }

    func write(_ next: InterfaceLanguage) {
        lock.lock()
        language = next
        lock.unlock()
    }
}

/// Caches each feature/locale `.strings` table after its first read.
///
/// The tables are immutable bundle resources, so one parse per locale candidate
/// is authoritative for the process lifetime. Without this cache every single
/// A feature lookup now parses only its bounded table. A missing or unparsable
/// file is cached as absent so a broken candidate does not retry disk I/O from
/// every SwiftUI body evaluation.
private final class APCLocalizationStringsCache: @unchecked Sendable {
    static let shared = APCLocalizationStringsCache()

    private enum Entry {
        case present([String: String])
        case absent
    }

    private let lock = NSLock()
    private var tables: [String: Entry] = [:]

    func table(
        _ table: APCLocalizationTable,
        for locale: String
    ) -> [String: String]? {
        let identity = "\(table.rawValue)|\(locale)"
        lock.lock()
        if let cached = tables[identity] {
            lock.unlock()
            return switch cached {
            case let .present(values): values
            case .absent: nil
            }
        }
        lock.unlock()

        let loaded = Self.load(table: table, locale: locale)

        lock.lock()
        tables[identity] = loaded.map(Entry.present) ?? .absent
        lock.unlock()
        return loaded
    }

    private static func load(
        table: APCLocalizationTable,
        locale: String
    ) -> [String: String]? {
        let url = APCResourceBundle.resourceURL(
            "Localization/\(table.rawValue)/\(locale).lproj/\(table.rawValue).strings"
        )
        guard let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: String]
        else {
            return nil
        }
        return values
    }
}

enum APCLocalization {
    static let requiredV1Keys = APCLocalizationKey.allCases
    private static let preference = APCLocalizationPreference()

    static var interfaceLanguage: InterfaceLanguage {
        preference.read()
    }

    static var interfaceLocaleIdentifier: String {
        resolvedInterfaceLocaleIdentifier(
            interfaceLanguage: interfaceLanguage,
            preferredLanguages: Locale.preferredLanguages
        )
    }

    static func applyInterfaceLanguage(_ language: InterfaceLanguage) {
        preference.write(language)
    }

    static func resolvedInterfaceLocaleIdentifier(
        interfaceLanguage: InterfaceLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        switch interfaceLanguage {
        case .system:
            resolvedInterfaceLocaleIdentifier(preferredLanguages: preferredLanguages)
        case .english:
            "en"
        case .simplifiedChinese:
            "zh-Hans"
        }
    }

    static func resolvedInterfaceLocaleIdentifier(
        preferredLanguages: [String]
    ) -> String {
        for identifier in preferredLanguages {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if normalized == "zh"
                || normalized.hasPrefix("zh-hans")
                || normalized.hasPrefix("zh-cn")
                || normalized.hasPrefix("zh-sg") {
                return "zh-Hans"
            }
            if normalized == "en" || normalized.hasPrefix("en-") {
                return "en"
            }
        }
        return "en"
    }

    static func text(_ key: APCLocalizationKey) -> String {
        text(key, locale: interfaceLocaleIdentifier)
    }

    static func text(_ key: APCLocalizationKey, locale identifier: String) -> String {
        let locale = supportedLocaleIdentifier(for: identifier)
        return localizedValue(for: key, locale: locale)
            ?? catalogValue(for: key, locale: locale)
            ?? key.rawValue
    }

    static func format(_ key: APCLocalizationKey, _ arguments: CVarArg...) -> String {
        formatted(key, locale: interfaceLocaleIdentifier, arguments: arguments)
    }

    static func format(
        _ key: APCLocalizationKey,
        locale identifier: String,
        _ arguments: CVarArg...
    ) -> String {
        formatted(key, locale: identifier, arguments: arguments)
    }

    private static func formatted(
        _ key: APCLocalizationKey,
        locale identifier: String,
        arguments: [CVarArg]
    ) -> String {
        let locale = supportedLocaleIdentifier(for: identifier)
        return String(
            format: text(key, locale: locale),
            locale: Locale(identifier: locale),
            arguments: arguments
        )
    }

    static func localizedValue(
        for key: APCLocalizationKey,
        locale identifier: String
    ) -> String? {
        for locale in localeCandidates(for: identifier) {
            guard let values = APCLocalizationStringsCache.shared.table(
                key.table,
                for: locale
            ),
                  let value = values[key.rawValue],
                  value != key.rawValue else {
                continue
            }
            return value
        }
        return nil
    }

    static func catalogValue(
        for key: APCLocalizationKey,
        locale identifier: String
    ) -> String? {
        let locale = supportedLocaleIdentifier(for: identifier)
        return catalogs[key.table]?
            .strings[key.rawValue]?
            .localizations[locale]?
            .stringUnit.value
    }

    private static func localeCandidates(for identifier: String) -> [String] {
        switch supportedLocaleIdentifier(for: identifier) {
        case "zh-Hans":
            ["zh-hans", "zh-Hans", "zh_CN", "zh"]
        case "en":
            ["en", "Base"]
        default:
            ["en", "Base"]
        }
    }

    private static func supportedLocaleIdentifier(for identifier: String) -> String {
        resolvedInterfaceLocaleIdentifier(preferredLanguages: [identifier])
    }

    private static let catalogs: [APCLocalizationTable: StringCatalog] =
        Dictionary(
            uniqueKeysWithValues: APCLocalizationTable.allCases.compactMap { table in
                let url = APCResourceBundle.resourceURL(
                    "Localization/\(table.rawValue)/\(table.rawValue).xcstrings"
                )
                guard let data = try? Data(contentsOf: url),
                      let catalog = try? JSONDecoder().decode(StringCatalog.self, from: data)
                else {
                    return nil
                }
                return (table, catalog)
            }
        )

    private struct StringCatalog: Decodable, Sendable {
        var strings: [String: Entry]

        struct Entry: Decodable, Sendable {
            var localizations: [String: Localization]
        }

        struct Localization: Decodable, Sendable {
            var stringUnit: StringUnit
        }

        struct StringUnit: Decodable, Sendable {
            var value: String
        }
    }
}

private struct APCInterfaceLanguageModifier: ViewModifier {
    @ObservedObject var store: AppStore

    func body(content: Content) -> some View {
        content
            .environment(
                \.locale,
                Locale(identifier: store.interfaceLocaleIdentifier)
            )
            .id(store.behavior.interfaceLanguage)
    }
}

extension View {
    func apcInterfaceLanguage(_ store: AppStore) -> some View {
        modifier(APCInterfaceLanguageModifier(store: store))
    }
}

enum UIControlSemantics {
    static func sourceLabel(_ source: AgentSource) -> String {
        APCLocalization.format(.controlSourceLabel, source.title)
    }

    static func eventLabel(_ event: AgentEventKind) -> String {
        APCLocalization.format(.controlEventLabel, APCLocalizedPresentation.eventTitle(event))
    }

    static func styleLabel(_ style: StylePreset) -> String {
        APCLocalization.format(.controlStyleLabel, APCLocalizedPresentation.styleTitle(style))
    }

    static func qualityLabel(_ quality: QualityLevel) -> String {
        APCLocalization.format(.controlQualityLabel, APCLocalizedPresentation.qualityTitle(quality))
    }

    static func toggleValue(isOn: Bool) -> String {
        APCLocalization.text(isOn ? .controlEnabled : .controlDisabled)
    }

    static func selectionValue(isSelected: Bool) -> String {
        APCLocalization.text(isSelected ? .controlSelected : .controlUnselected)
    }
}

enum APCLocalizedPresentation {
    static func animationActionTitle(
        _ action: PetAnimationAction,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        switch action {
        case .idle:
            lifecycleTitle(.idle, locale: locale)
        case .thinking:
            lifecycleTitle(.thinking, locale: locale)
        case .tool:
            lifecycleTitle(.tool, locale: locale)
        case .waiting:
            lifecycleTitle(.waiting, locale: locale)
        case .done:
            lifecycleTitle(.done, locale: locale)
        case .failed:
            lifecycleTitle(.failed, locale: locale)
        case .acknowledge:
            APCLocalization.text(.productInteractionAcknowledge, locale: locale)
        case .dragLeft:
            APCLocalization.text(.productInteractionDragLeft, locale: locale)
        case .dragRight:
            APCLocalization.text(.productInteractionDragRight, locale: locale)
        }
    }

    static func lifecycleTitle(
        _ state: ProductLifecycleState,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch state {
        case .idle: .productLifecycleIdle
        case .thinking: .productLifecycleThinking
        case .tool: .productLifecycleTool
        case .waiting: .productLifecycleWaiting
        case .done: .productLifecycleDone
        case .failed: .productLifecycleFailed
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func navigationActionTitle(
        _ capability: NavigationCapability,
        source: AgentSource,
        navigation: AgentSessionNavigation? = nil,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String? {
        switch capability {
        case .exactSession:
            APCLocalization.text(.productNavigationExactSession, locale: locale)
        case .agentHost:
            APCLocalization.format(
                .productNavigationAgentHostFormat,
                locale: locale,
                navigationHostTitle(source: source, navigation: navigation) ?? source.title
            )
        case .unavailable:
            nil
        }
    }

    static func sessionSurfaceTitle(
        _ kind: OverlaySessionSurfaceKind,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalization.text(
            kind == .app ? .productSessionSurfaceApp : .productSessionSurfaceCLI,
            locale: locale
        )
    }

    private static func navigationHostTitle(
        source: AgentSource,
        navigation: AgentSessionNavigation?
    ) -> String? {
        guard let navigation else { return nil }
        return switch (source, navigation.surface) {
        case (.codex, "chatgpt_app"):
            "ChatGPT"
        case (.claudeCode, "claude_app"):
            "Claude"
        case (.opencode, "opencode_app"):
            "OpenCode"
        case (_, "cli_terminal"):
            switch navigation.terminalApp {
            case "warp": "Warp"
            case "terminal": "Terminal"
            case "iterm2": "iTerm2"
            case "ghostty": "Ghostty"
            default: nil
            }
        default:
            nil
        }
    }

    static func navigationUnavailableTitle(
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalization.text(.productNavigationUnavailable, locale: locale)
    }

    static func attentionPresetTitle(
        _ preset: AttentionPreset,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch preset {
        case .onlyWhenNeeded: .productAttentionOnlyWhenNeeded
        case .standard: .productAttentionStandard
        case .allActivity: .productAttentionAllActivity
        case .custom: .productAttentionCustom
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func connectionHealthTitle(
        _ health: AgentConnectionHealthState,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch health {
        case .notChecked: .productConnectionNotChecked
        case .checking: .productConnectionChecking
        case .connected: .productConnectionConnected
        case .needsRepair: .productConnectionNeedsRepair
        case .unavailable: .productConnectionUnavailable
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func primaryActionTitle(
        _ action: PetLibraryPrimaryAction,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String? {
        let key: APCLocalizationKey? = switch action {
        case .usePet: .productActionUsePet
        case .createPet: .libraryEmptyAction
        case .importPet: .libraryImportAction
        case .unavailable: nil
        }
        return key.map { APCLocalization.text($0, locale: locale) }
    }

    static func primaryActionTitle(
        _ action: PetMakerPrimaryAction,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String? {
        let key: APCLocalizationKey? = switch action {
        case .createPet: .studioActionStart
        case .sendReply: .studioReplySend
        case .cancel: .studioActionCancelTask
        case .retry: .commonRetry
        case .reselectReferences: .studioReferencesPanelTitle
        case .usePet: .productActionUsePet
        case .continueEditing: .productActionContinueEditing
        case .unavailable: nil
        }
        return key.map { APCLocalization.text($0, locale: locale) }
    }

    static func primaryActionTitle(
        _ action: AgentConnectionPrimaryAction,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String? {
        let key: APCLocalizationKey? = switch action {
        case .connect: .productActionConnect
        case .repair: .connectionsInstallRepair
        case .verify: .productActionVerify
        case .retry: .commonRetry
        case .unavailable: nil
        }
        return key.map { APCLocalization.text($0, locale: locale) }
    }

    static func primaryActionTitle(
        _ action: ServiceDiagnosticsPrimaryAction,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String? {
        let key: APCLocalizationKey? = switch action {
        case .refresh: .diagnosticsRefresh
        case .recover: .diagnosticsRecover
        case .retry: .commonRetry
        case .unavailable: nil
        }
        return key.map { APCLocalization.text($0, locale: locale) }
    }

    static func eventTitle(
        _ event: AgentEventKind,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch event {
        case .start: .productEventStart
        case .thinking: .productEventThinking
        case .plan: .productEventPlan
        case .tool: .productEventTool
        case .waiting: .productEventWaiting
        case .done: .productEventDone
        case .failed: .productEventFailed
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func overlayEventTitle(
        _ event: AgentOverlaySummaryKind,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch event {
        case .start: .productEventStart
        case .thinking: .productEventThinking
        case .plan: .productEventPlan
        case .command: .overlayActivityCommand
        case .file: .overlayActivityFile
        case .fileChange: .overlayActivityFileChange
        case .tool: .productEventTool
        case .subagent: .overlayActivitySubagent
        case .search: .overlayActivitySearch
        case .network: .overlayActivityNetwork
        case .image: .overlayActivityImage
        case .compaction: .overlayActivityCompaction
        case .needsInput: .productEventWaiting
        case .done: .productEventDone
        case .failed: .productEventFailed
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func styleTitle(
        _ style: StylePreset,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch style {
        case .realistic: .styleRealistic
        case .semiRealistic: .styleSemiRealistic
        case .modern: .styleModern
        case .pixel: .stylePixel
        case .anime: .styleAnime
        case .unspecified: .styleUnspecified
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func qualityTitle(
        _ quality: QualityLevel,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch quality {
        case .low: .qualityLow
        case .standard: .qualityStandard
        case .high: .qualityHigh
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func qualityDetail(
        _ quality: QualityLevel,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let size = quality.renderSize
        let key: APCLocalizationKey = switch quality {
        case .low: .qualityLowDetailFormat
        case .standard: .qualityStandardDetailFormat
        case .high: .qualityHighDetailFormat
        }
        return APCLocalization.format(
            key,
            locale: locale,
            size.width,
            size.height
        )
    }

    static func appearanceTitle(
        _ theme: AppearanceTheme,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch theme {
        case .system: .appearanceSystem
        case .light: .appearanceLight
        case .dark: .appearanceDark
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func interfaceLanguageTitle(
        _ language: InterfaceLanguage,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch language {
        case .system: .interfaceLanguageSystem
        case .english: .interfaceLanguageEnglish
        case .simplifiedChinese: .interfaceLanguageSimplifiedChinese
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func sessionGroupTitle(
        _ display: SessionGroupDisplay,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalization.text(
            display == .stacked ? .sessionGroupStacked : .sessionGroupExpanded,
            locale: locale
        )
    }

    static func bubbleFontScaleTitle(
        _ scale: BubbleFontScale,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalization.text(
            scale == .standard ? .bubbleFontScaleStandard : .bubbleFontScaleLarge,
            locale: locale
        )
    }

    static func checkStatusTitle(
        _ status: CheckStatus,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch status {
        case .ok: .checkStatusOK
        case .needsFix: .checkStatusNeedsFix
        case .missing: .checkStatusMissing
        case .unverified: .checkStatusUnverified
        case .unsupported: .checkStatusUnsupported
        case .notRequired: .checkStatusNotRequired
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func connectionCheckModeTitle(
        _ mode: ConnectionCheckMode,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalization.text(
            mode == .light ? .connectionModeLight : .connectionModeRuntime,
            locale: locale
        )
    }

    static func verificationStatusTitle(
        _ status: AgentVerificationStatus,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch status {
        case .verified: .verificationStatusVerified
        case .actionRequired: .verificationStatusActionRequired
        case .unverified: .verificationStatusUnverified
        case .notRequired: .verificationStatusNotRequired
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func generationStateTitle(
        _ state: GenerationSessionState,
        operation: GenerationOperation,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = if operation == .modify {
            switch state {
            case .idle: .generationModifyIdle
            case .starting: .generationModifyStarting
            case .running: .generationModifyRunning
            case .waitingForInput: .generationModifyWaiting
            case .paused, .recoverableFailed: .generationModifyFailed
            case .cancelling: .generationModifyCancelling
            case .cancelCleanup: .generationModifyCancelling
            case .succeeded: .generationModifySucceeded
            case .failed: .generationModifyFailed
            case .cancelled: .generationModifyCancelled
            }
        } else {
            switch state {
            case .idle: .generationCreateIdle
            case .starting: .generationCreateStarting
            case .running: .generationCreateRunning
            case .waitingForInput: .generationCreateWaiting
            case .paused, .recoverableFailed: .generationCreateFailed
            case .cancelling: .generationCreateCancelling
            case .cancelCleanup: .generationCreateCancelling
            case .succeeded: .generationCreateSucceeded
            case .failed: .generationCreateFailed
            case .cancelled: .generationCreateCancelled
            }
        }
        return APCLocalization.text(key, locale: locale)
    }
}
