import AgentPetCompanionCore
import Foundation

enum APCLocalizationKey: String, CaseIterable, Sendable {
    case navigationStudio = "nav.studio"
    case navigationBehavior = "nav.behavior"
    case navigationConnections = "nav.connections"
    case studioTabNew = "studio.tab.new"
    case studioTabLibrary = "studio.tab.library"
    case studioPickerLabel = "studio.picker.label"
    case libraryEmptyTitle = "library.empty.title"
    case libraryEmptyDetail = "library.empty.detail"
    case libraryEmptyAction = "library.empty.action"
    case libraryImportAction = "library.import.action"
    case libraryImportInProgress = "library.import.in_progress"
    case libraryImportTitle = "library.import.title"
    case libraryImportMessage = "library.import.message"
    case libraryFormatAppOwned = "library.format.app_owned"
    case libraryValidationInvalid = "library.validation.invalid"
    case libraryValidationUnverifiedTitle = "library.validation.unverified_title"
    case libraryValidationUnverified = "library.validation.unverified"
    case librarySpecificationUnavailable = "library.specification.unavailable"
    case libraryStateNotActive = "library.state.not_active"
    case libraryStateIdle = "library.state.idle"
    case controlEnabled = "control.enabled"
    case controlDisabled = "control.disabled"
    case controlSelected = "control.selected"
    case controlUnselected = "control.unselected"
    case controlSourceLabel = "control.source.label"
    case controlEventLabel = "control.event.label"
    case controlStyleLabel = "control.style.label"
    case controlQualityLabel = "control.quality.label"
    case errorPetpackImportFailed = "error.petpack.import_failed"
}

enum APCLocalization {
    static let requiredV1Keys = APCLocalizationKey.allCases
    // V1 still contains Chinese product copy outside this catalog. Selecting a
    // partial English catalog at runtime creates mixed-language controls and
    // accessibility labels, so the shipped V1 interface uses its complete
    // zh-Hans surface. English entries remain executable/tested translation
    // assets and can become selectable once the full interface reaches parity.
    static let interfaceLocaleIdentifier = "zh-Hans"

    static func text(_ key: APCLocalizationKey) -> String {
        localizedValue(for: key, locale: interfaceLocaleIdentifier)
            ?? catalogValue(for: key, locale: interfaceLocaleIdentifier)
            ?? key.rawValue
    }

    static func format(_ key: APCLocalizationKey, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    static func localizedValue(
        for key: APCLocalizationKey,
        locale identifier: String
    ) -> String? {
        let language = localeCandidates(for: identifier).lazy.compactMap { locale in
            Bundle.module.path(forResource: locale, ofType: "lproj")
        }.first
        guard let language, let bundle = Bundle(path: language) else { return nil }
        let value = bundle.localizedString(forKey: key.rawValue, value: key.rawValue, table: nil)
        return value == key.rawValue ? nil : value
    }

    static func catalogValue(
        for key: APCLocalizationKey,
        locale identifier: String
    ) -> String? {
        let locale = identifier.lowercased() == "zh-hans" ? "zh-Hans" : identifier
        return catalog?.strings[key.rawValue]?.localizations[locale]?.stringUnit.value
    }

    private static func localeCandidates(for identifier: String) -> [String] {
        switch identifier.lowercased() {
        case "zh-hans", "zh_cn", "zh-cn":
            ["zh-hans", "zh-Hans", "zh_CN", "zh"]
        case "en", "en-us", "en_us":
            ["en", "Base"]
        default:
            [identifier]
        }
    }

    private static let catalog: StringCatalog? = {
        guard let url = Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings"),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? JSONDecoder().decode(StringCatalog.self, from: data)
    }()

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

enum UIControlSemantics {
    static func sourceLabel(_ source: AgentSource) -> String {
        APCLocalization.format(.controlSourceLabel, source.title)
    }

    static func eventLabel(_ event: AgentEventKind) -> String {
        APCLocalization.format(.controlEventLabel, event.title)
    }

    static func styleLabel(_ style: StylePreset) -> String {
        APCLocalization.format(.controlStyleLabel, style.rawValue)
    }

    static func qualityLabel(_ quality: QualityLevel) -> String {
        APCLocalization.format(.controlQualityLabel, quality.title)
    }

    static func toggleValue(isOn: Bool) -> String {
        APCLocalization.text(isOn ? .controlEnabled : .controlDisabled)
    }

    static func selectionValue(isSelected: Bool) -> String {
        APCLocalization.text(isSelected ? .controlSelected : .controlUnselected)
    }
}
