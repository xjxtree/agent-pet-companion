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
