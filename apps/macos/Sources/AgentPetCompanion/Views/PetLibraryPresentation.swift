import AgentPetCompanionCore
import Foundation

struct PetLibraryPresentation {
    enum ValidationStatus: Equatable {
        case verified
        case invalid
        case notFullyReported
    }

    let pet: PetSummary
    let assetWarning: PetAssetWarning?

    private var hasVerifiedSkillContract: Bool {
        assetWarning == nil && pet.origin == .verifiedSkillSource
    }

    var validationStatus: ValidationStatus {
        if assetWarning != nil { return .invalid }
        return hasVerifiedSkillContract ? .verified : .notFullyReported
    }

    var validationTitle: String {
        switch validationStatus {
        case .verified:
            APCLocalization.text(.libraryValidationVerifiedTitle)
        case .invalid:
            APCLocalization.text(.libraryValidationInvalid)
        case .notFullyReported:
            APCLocalization.text(.libraryValidationUnverifiedTitle)
        }
    }

    var validationDetail: String {
        if let assetWarning { return assetWarning.message }
        return APCLocalization.text(
            hasVerifiedSkillContract ? .libraryValidationVerified : .libraryValidationUnverified
        )
    }

    // verified_skill_source is assigned only after PetCore validates the fixed
    // V1 manifest contract and all frame assets. Other imports remain unknown.
    var stateSpecification: String? {
        hasVerifiedSkillContract
            ? APCLocalization.text(.librarySpecificationVerifiedStates)
            : nil
    }

    var fpsSpecification: String? {
        hasVerifiedSkillContract
            ? APCLocalization.text(.librarySpecificationVerifiedFps)
            : nil
    }

    func currentStateTitle(activeEvent: AgentEvent?) -> String? {
        guard pet.active else { return nil }
        return activeEvent?.eventType.title ?? APCLocalization.text(.libraryStateIdle)
    }
}
