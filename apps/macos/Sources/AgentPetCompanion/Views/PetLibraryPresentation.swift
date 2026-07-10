import AgentPetCompanionCore
import Foundation

struct PetLibraryPresentation {
    enum ValidationStatus: Equatable {
        case invalid
        case notFullyReported
    }

    let pet: PetSummary
    let assetWarning: PetAssetWarning?

    var validationStatus: ValidationStatus {
        assetWarning == nil ? .notFullyReported : .invalid
    }

    var validationTitle: String {
        APCLocalization.text(
            assetWarning == nil ? .libraryValidationUnverifiedTitle : .libraryValidationInvalid
        )
    }

    var validationDetail: String {
        assetWarning?.message ?? APCLocalization.text(.libraryValidationUnverified)
    }

    // The current daemon snapshot does not expose an authoritative state count
    // or frame-rate specification. Keep these absent instead of inferring them.
    var stateSpecification: String? { nil }
    var fpsSpecification: String? { nil }

    func currentStateTitle(activeEvent: AgentEvent?) -> String? {
        guard pet.active else { return nil }
        return activeEvent?.eventType.title ?? APCLocalization.text(.libraryStateIdle)
    }
}
