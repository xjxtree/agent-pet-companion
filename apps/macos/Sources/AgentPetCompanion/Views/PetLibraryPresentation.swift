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

    var validationStatus: ValidationStatus {
        if assetWarning != nil { return .invalid }
        // Every library entry has crossed PetCore's full package validator at
        // import time. Provenance describes who produced it; it is not the
        // package-validity signal.
        return .verified
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
        return APCLocalization.text(.libraryValidationVerified)
    }

    var stateSpecification: String? {
        validationStatus == .verified
            ? APCLocalization.text(.librarySpecificationVerifiedStates)
            : nil
    }

    var fpsSpecification: String? {
        validationStatus == .verified
            ? APCLocalization.text(.librarySpecificationVerifiedFps)
            : nil
    }

    func currentStateTitle(activeEvent: AgentEvent?) -> String? {
        guard pet.active else { return nil }
        return activeEvent?.eventType.title ?? APCLocalization.text(.libraryStateIdle)
    }
}
