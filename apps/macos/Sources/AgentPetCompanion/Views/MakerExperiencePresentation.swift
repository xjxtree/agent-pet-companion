import AgentPetCompanionCore
import Foundation

enum MakerResultReadiness: Equatable {
    case notApplicable
    case missing
    case previewNeedsRepair
    case ready

    init(
        session: GenerationSession,
        resultPetAvailable: Bool,
        resultPreviewAvailable: Bool
    ) {
        guard session.state == .succeeded else {
            self = .notApplicable
            return
        }
        if !resultPetAvailable {
            self = .missing
        } else if !resultPreviewAvailable {
            self = .previewNeedsRepair
        } else {
            self = .ready
        }
    }

    var needsRecovery: Bool {
        self == .missing || self == .previewNeedsRepair
    }
}

/// Layout decisions for the three product phases of AI Pet Maker.
///
/// The view consumes this projection instead of inferring its hierarchy from
/// individual job-state strings.
struct MakerExperiencePresentation: Equatable {
    let phase: PetMakerPhase
    let showsCenteredBrief: Bool
    let showsSession: Bool
    let showsBaselineInspector: Bool
    let showsResult: Bool
    let primaryAction: PetMakerPrimaryAction
    let secondaryActions: [PetMakerPrimaryAction]
    let resultReadiness: MakerResultReadiness

    init(
        session: GenerationSession,
        resultPetAvailable: Bool,
        resultPreviewAvailable: Bool = true,
        referenceReselectionCount: Int = 0
    ) {
        let product = PetMakerProductPresentation(
            session: session,
            resultPetAvailable: resultPetAvailable,
            resultPreviewAvailable: resultPreviewAvailable,
            referenceReselectionCount: referenceReselectionCount
        )
        phase = product.phase
        primaryAction = product.primaryAction
        secondaryActions = product.secondaryActions
        showsCenteredBrief = phase == .describe
        showsSession = phase != .describe
        showsBaselineInspector = session.operation == .modify && phase != .describe
        showsResult = phase == .result
        resultReadiness = MakerResultReadiness(
            session: session,
            resultPetAvailable: resultPetAvailable,
            resultPreviewAvailable: resultPreviewAvailable
        )
    }
}

/// Stable, compact display projection of the immutable submitted form.
///
/// It deliberately omits reference paths and package-authored animation
/// mechanics from the ordinary summary.
struct MakerSubmittedBriefPresentation: Equatable {
    static let maximumDescriptionScalars = 180

    let descriptionSummary: String
    let styleTitle: String
    let qualityTitle: String
    let referenceCount: Int

    init(
        form: GenerationForm,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier,
        maximumDescriptionScalars: Int = Self.maximumDescriptionScalars
    ) {
        descriptionSummary = Self.boundedSummary(
            form.description,
            maximumScalars: maximumDescriptionScalars
        )
        if let style = StylePreset(rawValue: form.style) {
            styleTitle = APCLocalizedPresentation.styleTitle(
                style,
                locale: localeIdentifier
            )
        } else {
            styleTitle = Self.boundedSummary(form.style, maximumScalars: 80)
        }
        qualityTitle = APCLocalizedPresentation.qualityTitle(
            form.quality,
            locale: localeIdentifier
        )
        referenceCount = min(
            MakerReferenceImagePolicy.maximumCount,
            max(0, form.referenceImages.count)
        )
    }

    static func boundedSummary(
        _ value: String,
        maximumScalars: Int
    ) -> String {
        guard maximumScalars > 0 else { return "" }
        let normalized = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let scalars = normalized.unicodeScalars
        guard scalars.count > maximumScalars else { return normalized }
        return String(
            String.UnicodeScalarView(scalars.prefix(maximumScalars))
        ) + "…"
    }
}

enum MakerResultPresentation {
    static func resultPet(
        for session: GenerationSession,
        in pets: [PetSummary]
    ) -> PetSummary? {
        guard session.state == .succeeded,
              let resultPetID = session.resultPetID,
              !resultPetID.isEmpty
        else { return nil }
        return pets.first { $0.id == resultPetID }
    }
}

/// The stable, user-facing filters supported by creation history.
///
/// Active jobs deliberately remain in `all`: the terminal filters describe
/// outcomes and must not make an in-progress task look successful or failed.
enum MakerHistoryFilter: String, CaseIterable, Identifiable, Equatable, Hashable {
    case all
    case succeeded
    case failed
    case cancelled

    var id: String { rawValue }

    var localizationKey: APCLocalizationKey {
        switch self {
        case .all: .studioHistoryFilterAll
        case .succeeded: .studioHistoryFilterSucceeded
        case .failed: .studioHistoryFilterFailed
        case .cancelled: .studioHistoryFilterCancelled
        }
    }

    func title(
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalization.text(localizationKey, locale: localeIdentifier)
    }

    func matches(_ status: GenerationJobHistoryStatus) -> Bool {
        switch self {
        case .all:
            true
        case .succeeded:
            status == .completed
        case .failed:
            status == .failed
        case .cancelled:
            status == .canceled
        }
    }
}

/// Supplies compact row copy without losing the exact timestamp needed by a
/// detail pane, tooltip, or accessibility value.
struct MakerHistoryTimestampPresentation: Equatable {
    let relative: String
    let absolute: String

    init(
        value: String,
        now: Date = Date(),
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier,
        timeZone: TimeZone = .current
    ) {
        guard let date = Self.parse(value) else {
            relative = "—"
            absolute = "—"
            return
        }

        let locale = Locale(identifier: localeIdentifier)
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.locale = locale
        relativeFormatter.unitsStyle = .full
        relativeFormatter.dateTimeStyle = .numeric
        relativeFormatter.formattingContext = .standalone
        relative = relativeFormatter.localizedString(
            fromTimeInterval: date.timeIntervalSince(now)
        )

        let absoluteFormatter = DateFormatter()
        absoluteFormatter.locale = locale
        absoluteFormatter.timeZone = timeZone
        absoluteFormatter.dateStyle = .medium
        absoluteFormatter.timeStyle = .short
        absolute = absoluteFormatter.string(from: date)
    }

    private static func parse(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }
}

struct MakerHistoryProgressItem: Equatable, Identifiable {
    let id: String
    let content: String
}

/// A bounded compatibility projection for historical progress emitted before
/// PetCore switched to neutral product copy. It removes only recognisable
/// technical identifiers and keeps ordinary brief prose intact.
enum MakerHistoryProgressPresentation {
    static let maximumItems = 12
    static let maximumContentScalars = 220

    private static let identifierPatterns = [
        #"(?i)\b(?:thread|turn)(?:[_\s]?id)?\s*[:=#]\s*[0-9a-z][0-9a-z_-]{11,}\b"#,
        #"(?i)\b(?:thread|turn)[_-][0-9a-z][0-9a-z_-]{11,}\b"#,
        #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
    ]

    static func items(
        _ messages: [GenerationMessage],
        maximumItems: Int = maximumItems,
        maximumContentScalars: Int = maximumContentScalars
    ) -> [MakerHistoryProgressItem] {
        guard maximumItems > 0, maximumContentScalars > 0 else { return [] }

        var projected: [MakerHistoryProgressItem] = []
        var previousComparableContent: String?
        for message in messages {
            let content = sanitizedContent(
                message.content,
                maximumScalars: maximumContentScalars
            )
            guard !content.isEmpty else { continue }

            let comparable = content.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard comparable != previousComparableContent else { continue }
            projected.append(MakerHistoryProgressItem(
                id: message.id,
                content: content
            ))
            previousComparableContent = comparable
        }
        return Array(projected.suffix(maximumItems))
    }

    static func sanitizedContent(
        _ value: String,
        maximumScalars: Int = maximumContentScalars
    ) -> String {
        guard maximumScalars > 0 else { return "" }
        var result = value
        for pattern in identifierPatterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: []
            ) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: ""
            )
        }

        result = result
            .replacingOccurrences(of: "Codex App Server 会话", with: "Codex 会话")
            .replacingOccurrences(of: "Pet Studio brief turn", with: "创作方案")
            .replacingOccurrences(
                of: "Codex App Server thread",
                with: "Codex session",
                options: .caseInsensitive
            )
            .replacingOccurrences(
                of: "brief turn",
                with: "creation brief",
                options: .caseInsensitive
            )
            .replacingOccurrences(
                of: #"\(\s*\)|（\s*）"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+([，。！？、,.;!?：:])"#,
                with: "$1",
                options: .regularExpression
            )

        return MakerSubmittedBriefPresentation.boundedSummary(
            result,
            maximumScalars: maximumScalars
        )
    }
}

enum MakerBriefPresentation {
    static let descriptionCountVisibilityThreshold = 0.8

    static func showsDescriptionCount(
        scalarCount: Int,
        maximum: Int = AIPetMakerDefaults.maximumDescriptionCharacters
    ) -> Bool {
        guard maximum > 0 else { return false }
        return Double(max(0, scalarCount)) / Double(maximum)
            > descriptionCountVisibilityThreshold
    }

    static func descriptionCount(
        scalarCount: Int,
        maximum: Int = AIPetMakerDefaults.maximumDescriptionCharacters,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalization.format(
            .studioDescriptionCountFormat,
            locale: localeIdentifier,
            max(0, scalarCount),
            max(0, maximum)
        )
    }

    static func qualityGuidance(
        _ quality: QualityLevel,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let contract = APCLocalization.format(
            .studioQualityContractFormat,
            locale: localeIdentifier,
            APCLocalizedPresentation.qualityDetail(
                quality,
                locale: localeIdentifier
            )
        )
        let capability = APCLocalization.text(
            .studioHighQualityUnsupported,
            locale: localeIdentifier
        )
        return "\(contract) \(capability)"
    }
}

enum MakerBriefTemplate: String, CaseIterable, Identifiable {
    case appearance
    case action
    case palette

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .appearance: "person.crop.circle.badge.plus"
        case .action: "figure.walk.motion"
        case .palette: "paintpalette"
        }
    }

    var title: String {
        title(localeIdentifier: APCLocalization.interfaceLocaleIdentifier)
    }

    var insertionText: String {
        insertionText(localeIdentifier: APCLocalization.interfaceLocaleIdentifier)
    }

    func title(
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalization.text(titleKey, locale: localeIdentifier)
    }

    func insertionText(
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalization.text(promptKey, locale: localeIdentifier)
    }

    private var titleKey: APCLocalizationKey {
        switch self {
        case .appearance: .studioDescriptionTemplateAppearanceTitle
        case .action: .studioDescriptionTemplateActionTitle
        case .palette: .studioDescriptionTemplatePaletteTitle
        }
    }

    private var promptKey: APCLocalizationKey {
        switch self {
        case .appearance: .studioDescriptionTemplateAppearancePrompt
        case .action: .studioDescriptionTemplateActionPrompt
        case .palette: .studioDescriptionTemplatePalettePrompt
        }
    }
}
