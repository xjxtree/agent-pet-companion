import AgentPetCompanionCore
import Foundation

enum PetLibraryContentState: Equatable {
    case loading
    case empty
    case searchEmpty
    case results

    static func resolve(
        hasLoadedStateSnapshot: Bool,
        petCount: Int,
        filteredPetCount: Int
    ) -> Self {
        if !hasLoadedStateSnapshot, petCount == 0 {
            return .loading
        }
        if petCount == 0 {
            return .empty
        }
        if filteredPetCount == 0 {
            return .searchEmpty
        }
        return .results
    }
}

struct PetLibraryCapabilities: Equatable {
    let isBundled: Bool
    let canModify: Bool
    let canDelete: Bool
    let canCustomizeAsCopy: Bool

    init(pet: PetSummary) {
        isBundled = pet.isBundled
        canModify = !isBundled
        canDelete = !isBundled
        canCustomizeAsCopy = isBundled
    }
}

struct PetLibraryCopyDraft: Equatable {
    let suggestedID: String
    let brief: String
    let style: StylePreset
    let quality: QualityLevel

    static func make(
        for pet: PetSummary,
        existingPetIDs: Set<String>,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> Self {
        let suggestedID = uniqueCopyID(for: pet, existingPetIDs: existingPetIDs)
        let style = StylePreset.allCases.first(where: { $0.rawValue == pet.style }) ?? .semiRealistic
        let brief = [
            APCLocalization.format(
                .libraryCopyBriefSourceFormat,
                locale: localeIdentifier,
                pet.name,
                pet.id
            ),
            APCLocalization.format(
                .libraryCopyBriefIDFormat,
                locale: localeIdentifier,
                suggestedID
            ),
            APCLocalization.text(.libraryCopyBriefContract, locale: localeIdentifier)
        ].joined(separator: "\n")
        return Self(
            suggestedID: suggestedID,
            brief: brief,
            style: style,
            quality: pet.quality
        )
    }

    private static func uniqueCopyID(
        for pet: PetSummary,
        existingPetIDs: Set<String>
    ) -> String {
        let source = pet.id.lowercased().hasPrefix("pet_")
            ? String(pet.id.lowercased().dropFirst(4))
            : pet.id.lowercased()
        let safeBase = source.unicodeScalars
            .filter { scalar in
                (scalar.value >= 97 && scalar.value <= 122)
                    || (scalar.value >= 48 && scalar.value <= 57)
            }
            .prefix(80)
        let normalizedBase = safeBase.isEmpty ? "companion" : String(String.UnicodeScalarView(safeBase))
        let stem = "pet_\(normalizedBase)copy"
        if !existingPetIDs.contains(stem) {
            return stem
        }
        for ordinal in 2 ... (existingPetIDs.count + 2) {
            let candidate = "\(stem)\(ordinal)"
            if !existingPetIDs.contains(candidate) {
                return candidate
            }
        }
        return "\(stem)new"
    }
}

struct PetLibrarySourceBadgePresentation: Equatable {
    enum Tone: Equatable {
        case bundled
        case verified
        case generated
        case external
    }

    let title: String
    let systemImage: String
    let tone: Tone
}

enum PetLibraryNoticeKind: Equatable {
    case importFailure
}

struct PetLibraryImportFailure: Equatable {
    private let fileName: String?

    static let invalidSelection = Self(fileName: nil)

    static func file(at url: URL) -> Self {
        Self(fileName: url.lastPathComponent)
    }

    func localizedDetail(localeIdentifier: String) -> String {
        guard let fileName, !fileName.isEmpty else {
            return APCLocalization.text(.libraryImportValidPetpack, locale: localeIdentifier)
        }
        return APCLocalization.format(
            .libraryImportFailedFileFormat,
            locale: localeIdentifier,
            fileName
        )
    }
}

struct PetLibraryNotice: Equatable, Identifiable {
    let kind: PetLibraryNoticeKind
    let title: String
    let message: String

    var id: String {
        switch kind {
        case .importFailure:
            "pet-library-import-failure"
        }
    }

    var systemImage: String {
        switch kind {
        case .importFailure:
            "exclamationmark.triangle.fill"
        }
    }

    static func importFailure(
        importedCount: Int,
        failures: [PetLibraryImportFailure],
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> Self {
        let failedCount = failures.count
        let title = APCLocalization.text(
            importedCount > 0 ? .libraryImportPartialTitle : .libraryImportFailureTitle,
            locale: localeIdentifier
        )
        let countSummary = importedCount > 0
            ? APCLocalization.format(
                .libraryImportPartialCountFormat,
                locale: localeIdentifier,
                importedCount,
                failedCount
            )
            : APCLocalization.text(.libraryImportNone, locale: localeIdentifier)
        let detail = failures.first?.localizedDetail(localeIdentifier: localeIdentifier)
            ?? APCLocalization.text(.libraryImportValidPetpack, locale: localeIdentifier)
        return Self(
            kind: .importFailure,
            title: title,
            message: "\(countSummary)\n\(detail)"
        )
    }
}

enum PetLibrarySelectionPolicy {
    static func reconciledSelection(
        currentID: String?,
        pets: [PetSummary],
        preferredID: String?,
        allowsDefaultSelection: Bool
    ) -> String? {
        let ids = Set(pets.map(\.id))
        if let currentID, ids.contains(currentID) {
            return currentID
        }
        guard currentID != nil || allowsDefaultSelection else { return nil }
        if let preferredID, ids.contains(preferredID) {
            return preferredID
        }
        return pets.first?.id
    }
}

enum PetHistoryBaselineState: Equatable {
    case loading
    case lookupFailed
    case legacyPackage
    case selectionRequired
    case validatedRevision

    static func resolve(
        history: PetHistorySnapshot?,
        loadFailed: Bool,
        selectedRevision: PetRevisionHistoryRecord?
    ) -> Self {
        if loadFailed {
            return .lookupFailed
        }
        guard let history else {
            return .loading
        }
        if history.revisions.isEmpty {
            // A successfully loaded legacy/external package has no owned
            // revision record. PetCore will revalidate its current package
            // when generation.edit starts.
            return .legacyPackage
        }
        return selectedRevision?.validated == true
            ? .validatedRevision
            : .selectionRequired
    }

    var canStartEdit: Bool {
        self == .legacyPackage || self == .validatedRevision
    }

    var canRetry: Bool {
        self == .lookupFailed
    }
}

enum PetEditHistoryState: Equatable {
    case checking
    case available(operation: GenerationOperation?, status: String?)
    case unavailable
    case lookupFailed
}

struct PetEditHistoryPresentation: Equatable {
    let state: PetEditHistoryState
    let localeIdentifier: String

    init(
        state: PetEditHistoryState,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) {
        self.state = state
        self.localeIdentifier = localeIdentifier
    }

    var title: String {
        switch state {
        case .checking:
            APCLocalization.text(.libraryHistoryCheckingTitle, locale: localeIdentifier)
        case .available:
            APCLocalization.text(.libraryHistoryAvailableTitle, locale: localeIdentifier)
        case .unavailable:
            APCLocalization.text(.libraryHistoryUnavailableTitle, locale: localeIdentifier)
        case .lookupFailed:
            APCLocalization.text(.libraryHistoryFailedTitle, locale: localeIdentifier)
        }
    }

    var detail: String {
        switch state {
        case .checking:
            APCLocalization.text(.libraryHistoryCheckingDetail, locale: localeIdentifier)
        case let .available(operation, status):
            APCLocalization.format(
                .libraryHistoryAvailableDetailFormat,
                locale: localeIdentifier,
                recordSummary(operation: operation, status: status)
            )
        case .unavailable:
            APCLocalization.text(.libraryHistoryUnavailableDetail, locale: localeIdentifier)
        case .lookupFailed:
            APCLocalization.text(.libraryHistoryFailedDetail, locale: localeIdentifier)
        }
    }

    var systemImage: String {
        switch state {
        case .checking:
            "clock.arrow.circlepath"
        case .available:
            "text.bubble.fill"
        case .unavailable:
            "square.and.arrow.down"
        case .lookupFailed:
            "exclamationmark.triangle"
        }
    }

    private func recordSummary(operation: GenerationOperation?, status: String?) -> String {
        let operationTitle = switch operation {
        case .some(.create): APCLocalization.text(.libraryHistoryOperationCreate, locale: localeIdentifier)
        case .some(.modify): APCLocalization.text(.libraryHistoryOperationModify, locale: localeIdentifier)
        case nil: APCLocalization.text(.libraryHistoryOperationUnknown, locale: localeIdentifier)
        }
        let statusTitle = switch status {
        case "pending": APCLocalization.text(.libraryHistoryStatusPending, locale: localeIdentifier)
        case "running": APCLocalization.text(.libraryHistoryStatusRunning, locale: localeIdentifier)
        case "waiting_for_user": APCLocalization.text(.libraryHistoryStatusWaiting, locale: localeIdentifier)
        case "completed": APCLocalization.text(.libraryHistoryStatusCompleted, locale: localeIdentifier)
        case "failed": APCLocalization.text(.libraryHistoryStatusFailed, locale: localeIdentifier)
        case "canceled", "cancelled": APCLocalization.text(.libraryHistoryStatusCancelled, locale: localeIdentifier)
        default: APCLocalization.text(.libraryHistoryStatusUnknown, locale: localeIdentifier)
        }
        return APCLocalization.format(
            .libraryHistorySummaryFormat,
            locale: localeIdentifier,
            operationTitle,
            statusTitle
        )
    }
}

enum PetLibraryHistoryPresentation {
    static func localizedTimestamp(
        _ value: String,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier,
        timeZone: TimeZone = .current
    ) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: value) ?? {
            parser.formatOptions = [.withInternetDateTime]
            return parser.date(from: value)
        }()
        guard let date else { return "—" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localeIdentifier)
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

extension PetSummary {
    var libraryCapabilities: PetLibraryCapabilities {
        PetLibraryCapabilities(pet: self)
    }
}

struct PetLibrarySourcePresentation: Equatable {
    let pet: PetSummary
    let localeIdentifier: String

    init(
        pet: PetSummary,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) {
        self.pet = pet
        self.localeIdentifier = localeIdentifier
    }

    var title: String {
        if pet.isBundled {
            return APCLocalization.text(.librarySourceBundledTitle, locale: localeIdentifier)
        }
        return switch pet.origin {
        case .verifiedSkillSource:
            APCLocalization.text(.librarySourceVerifiedTitle, locale: localeIdentifier)
        case .generatedByPetcoreJob:
            APCLocalization.text(
                pet.provenance == "skill-full-source"
                    ? .librarySourceGeneratedTitle
                    : .librarySourcePreviewTitle,
                locale: localeIdentifier
            )
        case .externalImport:
            APCLocalization.text(.librarySourceExternalTitle, locale: localeIdentifier)
        }
    }

    var detail: String {
        if pet.isBundled {
            return APCLocalization.text(.librarySourceBundledDetail, locale: localeIdentifier)
        }
        let claimed = [pet.generator, pet.provenance].compactMap { $0 }.joined(separator: " · ")
        switch pet.origin {
        case .verifiedSkillSource:
            return claimed.isEmpty
                ? APCLocalization.text(.librarySourceVerifiedDetail, locale: localeIdentifier)
                : APCLocalization.format(
                    .librarySourceVerifiedClaimedFormat,
                    locale: localeIdentifier,
                    claimed
                )
        case .generatedByPetcoreJob:
            if pet.provenance == "deterministic_preview" || pet.provenance == "local_form" {
                return claimed.isEmpty
                    ? APCLocalization.text(.librarySourcePreviewDetail, locale: localeIdentifier)
                    : APCLocalization.format(
                        .librarySourcePreviewClaimedFormat,
                        locale: localeIdentifier,
                        claimed
                    )
            }
            if pet.provenance == "codex_app_server_brief" {
                return claimed.isEmpty
                    ? APCLocalization.text(.librarySourceBriefDetail, locale: localeIdentifier)
                    : APCLocalization.format(
                        .librarySourceBriefClaimedFormat,
                        locale: localeIdentifier,
                        claimed
                    )
            }
            return claimed.isEmpty
                ? APCLocalization.text(.librarySourceJobDetail, locale: localeIdentifier)
                : APCLocalization.format(
                    .librarySourceJobClaimedFormat,
                    locale: localeIdentifier,
                    claimed
                )
        case .externalImport:
            return claimed.isEmpty
                ? APCLocalization.text(.librarySourceExternalDetail, locale: localeIdentifier)
                : APCLocalization.format(
                    .librarySourceExternalClaimedFormat,
                    locale: localeIdentifier,
                    claimed
                )
        }
    }
}

struct PetLibraryPresentation: Equatable {
    enum ValidationStatus: Equatable {
        case verified
        case invalid
        case notFullyReported
    }

    let pet: PetSummary
    let assetWarning: PetAssetWarning?
    let localeIdentifier: String

    init(
        pet: PetSummary,
        assetWarning: PetAssetWarning?,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) {
        self.pet = pet
        self.assetWarning = assetWarning
        self.localeIdentifier = localeIdentifier
    }

    var isBundled: Bool { pet.libraryCapabilities.isBundled }
    var canModify: Bool { pet.libraryCapabilities.canModify }
    var canDelete: Bool { pet.libraryCapabilities.canDelete }
    var canCustomizeAsCopy: Bool { pet.libraryCapabilities.canCustomizeAsCopy }
    var sourceTitle: String {
        PetLibrarySourcePresentation(pet: pet, localeIdentifier: localeIdentifier).title
    }
    var sourceDetail: String {
        PetLibrarySourcePresentation(pet: pet, localeIdentifier: localeIdentifier).detail
    }

    var sourceBadge: PetLibrarySourceBadgePresentation {
        if isBundled {
            return PetLibrarySourceBadgePresentation(
                title: sourceTitle,
                systemImage: "shippingbox.fill",
                tone: .bundled
            )
        }
        return switch pet.origin {
        case .verifiedSkillSource:
            PetLibrarySourceBadgePresentation(
                title: sourceTitle,
                systemImage: "checkmark.seal.fill",
                tone: .verified
            )
        case .generatedByPetcoreJob:
            PetLibrarySourceBadgePresentation(
                title: sourceTitle,
                systemImage: "sparkles",
                tone: .generated
            )
        case .externalImport:
            PetLibrarySourceBadgePresentation(
                title: sourceTitle,
                systemImage: "square.and.arrow.down",
                tone: .external
            )
        }
    }

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
            APCLocalization.text(.libraryValidationVerifiedTitle, locale: localeIdentifier)
        case .invalid:
            APCLocalization.text(.libraryValidationInvalid, locale: localeIdentifier)
        case .notFullyReported:
            APCLocalization.text(.libraryValidationUnverifiedTitle, locale: localeIdentifier)
        }
    }

    var validationDetail: String {
        if let assetWarning { return assetWarning.message }
        return APCLocalization.text(.libraryValidationVerified, locale: localeIdentifier)
    }

    var validationSummary: String {
        "\(validationTitle) · \(validationDetail)"
    }

    var revisionSummary: String {
        "\(revisionIDSummary) · \(revisionCountSummary) · \(revisionPolicySummary)"
    }

    /// PetCore only admits packages that satisfy the currently supported V1
    /// package contract. Keeping the package format separate from the
    /// immutable revision ID prevents the Inspector from conflating the two.
    var packageVersionSummary: String {
        "apc.petpack.v1"
    }

    var revisionIDSummary: String {
        pet.revisionID
            ?? APCLocalization.text(.libraryRevisionUnavailable, locale: localeIdentifier)
    }

    var revisionCountSummary: String {
        if pet.revisionID == nil {
            return APCLocalization.text(.libraryRevisionZeroExternal, locale: localeIdentifier)
        }
        guard pet.revisionCount > 0 else {
            return APCLocalization.text(.libraryRevisionCountIncomplete, locale: localeIdentifier)
        }
        return APCLocalization.format(
            .libraryRevisionCountFormat,
            locale: localeIdentifier,
            pet.revisionCount
        )
    }

    var revisionPolicySummary: String {
        isBundled
            ? APCLocalization.text(.libraryRevisionBundledPolicy, locale: localeIdentifier)
            : APCLocalization.text(.libraryRevisionNewPolicy, locale: localeIdentifier)
    }

    var stateSpecification: String? {
        validationStatus == .verified
            ? APCLocalization.text(.librarySpecificationVerifiedStates, locale: localeIdentifier)
            : nil
    }

    var fpsSpecification: String? {
        validationStatus == .verified
            ? fpsSummary
            : nil
    }

    var fpsSummary: String {
        APCLocalization.text(
            pet.nativeFPS == FpsProfile.smooth.fps
                ? .libraryFPSSummary
                : .libraryFPSStandardSummary,
            locale: localeIdentifier
        )
    }

    var durationSummary: String {
        [1_000, 2_000].compactMap { durationMS in
            let states = Self.stateNames.filter { pet.durationMS(for: $0) == durationMS }
            guard !states.isEmpty else { return nil }
            return APCLocalization.format(
                .libraryDurationGroupFormat,
                locale: localeIdentifier,
                durationMS / 1_000,
                states.joined(separator: " · ")
            )
        }.joined(separator: "   ")
    }

    var stateSummary: String {
        Self.stateNames.joined(separator: " · ")
    }

    private static let stateNames = [
        "idle", "start", "tool", "waiting", "review", "done", "failed",
    ]

    func currentStateTitle(activeEvent: AgentEvent?) -> String? {
        guard pet.active else { return nil }
        return activeEvent.map {
            APCLocalizedPresentation.eventTitle($0.eventType, locale: localeIdentifier)
        } ?? APCLocalization.text(.libraryStateIdle, locale: localeIdentifier)
    }

    func currentStateSummary(activeEvent: AgentEvent?) -> String {
        currentStateTitle(activeEvent: activeEvent)
            ?? APCLocalization.text(.libraryStateNotActive, locale: localeIdentifier)
    }

    func matchesSearch(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        return [
            pet.name,
            pet.id,
            sourceTitle,
            sourceDetail
        ].contains { value in
            value.localizedCaseInsensitiveContains(normalized)
        }
    }

    static func filtered(
        _ pets: [PetSummary],
        query: String,
        warnings: PetAssetWarningIndex = PetAssetWarningIndex(),
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> [PetSummary] {
        pets.filter { pet in
            Self(
                pet: pet,
                assetWarning: warnings[pet.id],
                localeIdentifier: localeIdentifier
            ).matchesSearch(query)
        }
    }
}
