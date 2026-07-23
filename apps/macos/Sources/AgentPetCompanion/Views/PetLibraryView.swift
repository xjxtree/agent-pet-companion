import AgentPetCompanionCore
import AppKit
import SwiftUI

enum PetLibraryGridPolicy {
    static let minimumCardWidth: CGFloat = 176
    static let maximumCardWidth: CGFloat = 248
    static let spacing: CGFloat = 14

    static func candidateColumnCounts(for shellMode: ControlCenterShellMode) -> [Int] {
        shellMode == .singleContent ? [1] : [4, 3, 2]
    }

    static func minimumWidth(for columnCount: Int) -> CGFloat {
        let boundedCount = max(1, min(4, columnCount))
        return CGFloat(boundedCount) * minimumCardWidth
            + CGFloat(boundedCount - 1) * spacing
    }

    static func columns(count: Int) -> [GridItem] {
        let boundedCount = max(1, min(4, count))
        let size: GridItem.Size = boundedCount == 1
            ? .flexible(minimum: 0, maximum: .infinity)
            : .flexible(minimum: minimumCardWidth, maximum: maximumCardWidth)
        return Array(
            repeating: GridItem(size, spacing: spacing, alignment: .top),
            count: boundedCount
        )
    }
}

struct PetLibraryView: View {
    private static let maximumEditInstructionCharacters = GenerationPromptPolicy.maximumScalarCount

    @EnvironmentObject private var store: AppStore
    @Environment(\.controlCenterShellMode) private var shellMode
    @State private var pendingDeletePet: PetSummary?
    @State private var pendingPetSheet: PetLibrarySheetRequest?
    @State private var searchText = ""
    @State private var selectedPetID: String?

    private var selectedPet: PetSummary? {
        guard let selectedPetID else { return nil }
        return store.pets.first(where: { $0.id == selectedPetID })
    }

    private var featuredPet: PetSummary? {
        selectedPet ?? store.activePet ?? store.pets.first
    }

    private var filteredPets: [PetSummary] {
        PetLibraryPresentation.filtered(
            store.pets,
            query: searchText,
            warnings: store.petAssetWarningIndex
        )
    }

    private var contentState: PetLibraryContentState {
        PetLibraryContentState.resolve(
            hasLoadedStateSnapshot: store.hasLoadedStateSnapshot,
            petCount: store.pets.count,
            filteredPetCount: filteredPets.count
        )
    }

    private var showsSearch: Bool {
        PetLibraryDensityPolicy.showsSearch(petCount: store.pets.count)
    }

    private var productPresentation: PetLibraryProductPresentation {
        let pet = featuredPet
        return PetLibraryProductPresentation(
            pets: store.pets,
            selectedPet: pet,
            selectedPetCanBeUsed: pet.map {
                store.petAssetWarningIndex[$0.id] == nil
                    && !store.petOperationIDs.contains($0.id)
            } ?? false
        )
    }

    var body: some View {
        searchConfiguredSurface
            .toolbar {
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button {
                        store.importPetpacks()
                    } label: {
                        Label(
                            APCLocalization.text(
                                store.isImportingPetpack
                                    ? .libraryImportInProgress
                                    : .libraryImportAction
                            ),
                            systemImage: "square.and.arrow.down"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .help(APCLocalization.text(.libraryImportAction))
                    .disabled(store.isImportingPetpack)
                    .accessibilityIdentifier("pet-library.import")

                    Button {
                        store.selection = .maker
                    } label: {
                        Label(
                            APCLocalization.text(.libraryMakeAction),
                            systemImage: "wand.and.stars"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .help(APCLocalization.text(.libraryMakeAction))
                    .accessibilityIdentifier("pet-library.make")
                }
            }
            .onAppear {
                selectDefaultPetIfNeeded()
            }
            .onChange(of: store.pets.map(\.id)) { oldIDs, newIDs in
                reconcileSelection(oldIDs: oldIDs, newIDs: newIDs)
            }
            .onChange(of: showsSearch) { _, searchIsVisible in
                if !searchIsVisible {
                    searchText = ""
                }
            }
            .confirmationDialog(
                pendingDeletePet.map {
                    APCLocalization.text(
                        $0.active ? .libraryDeleteCurrentTitle : .libraryDeleteTitle
                    )
                } ?? APCLocalization.text(.libraryDeleteTitle),
                isPresented: Binding(
                    get: { pendingDeletePet != nil },
                    set: { isPresented in
                        if !isPresented { pendingDeletePet = nil }
                    }
                ),
                titleVisibility: .visible,
                presenting: pendingDeletePet
            ) { pet in
                Button(
                    APCLocalization.format(.libraryDeleteActionFormat, pet.name),
                    role: .destructive
                ) {
                    store.deletePet(pet)
                    pendingDeletePet = nil
                }
                Button(APCLocalization.text(.commonCancel), role: .cancel) {
                    pendingDeletePet = nil
                }
            } message: { pet in
                Text(APCLocalization.format(.libraryDeleteMessageFormat, pet.name))
            }
            .sheet(item: $pendingPetSheet) { request in
                PetHistorySheet(
                    pet: request.pet,
                    initialMode: request.mode,
                    maximumInstructionCharacters: Self.maximumEditInstructionCharacters,
                    onCancel: {
                        pendingPetSheet = nil
                    },
                    onStart: { baselineRevisionID, instruction in
                        pendingPetSheet = nil
                        store.startPetEdit(
                            request.pet,
                            baselineRevisionID: baselineRevisionID,
                            instruction: instruction
                        )
                    }
                )
            }
    }

    @ViewBuilder
    private var searchConfiguredSurface: some View {
        if showsSearch {
            libraryPage
                .searchable(
                    text: $searchText,
                    placement: .toolbar,
                    prompt: Text(APCLocalization.text(.librarySearchPlaceholder))
                )
        } else {
            libraryPage
        }
    }

    private var libraryPage: some View {
        PageScroll {
            ProductPageHeader(
                identity: ProductComponentIdentity(scope: "pet-library"),
                title: APCLocalization.text(.navigationLibrary),
                summary: APCLocalization.text(.libraryPageSubtitle)
            )

            if let notice = store.petLibraryNotice {
                PetLibraryNoticeBanner(
                    notice: notice,
                    retrying: store.isImportingPetpack,
                    onRetry: { store.importPetpacks() },
                    onDismiss: { store.dismissPetLibraryNotice() }
                )
            }

            libraryContent
        }
        .accessibilityIdentifier("pet-library.page")
    }

    @ViewBuilder
    private var libraryContent: some View {
        switch contentState {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text(APCLocalization.text(.libraryLoadingTitle))
                    .font(.headline)
                Text(APCLocalization.text(.libraryLoadingDetail))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pet-library.loading")

        case .empty:
            EmptyStateAction(
                identity: ProductComponentIdentity(scope: "pet-library", instance: "empty"),
                status: ProductStatusPresentation(
                    appearance: .normal,
                    title: APCLocalization.text(.libraryEmptyTitle)
                ),
                message: APCLocalization.text(.libraryEmptyDetail),
                primaryAction: ProductActionPresentation(
                    action: productPresentation.primaryAction,
                    title: APCLocalizedPresentation.primaryActionTitle(
                        productPresentation.primaryAction
                    ) ?? APCLocalization.text(.libraryEmptyAction),
                    systemImage: "wand.and.stars"
                ),
                onPrimaryAction: { action in
                    if action == .createPet {
                        store.selection = .maker
                    }
                }
            )
            .frame(maxWidth: .infinity, minHeight: 320)
            .accessibilityIdentifier("pet-library.empty")

        case .searchEmpty:
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, minHeight: 320)
                .accessibilityIdentifier("pet-library.search-empty")

        case .results:
            VStack(alignment: .leading, spacing: 22) {
                if let featuredPet {
                    PetLibraryHero(
                        pet: featuredPet,
                        productPresentation: productPresentation,
                        assetWarning: store.petAssetWarningIndex[featuredPet.id],
                        activeEvent: store.activeOverlayEvent,
                        isBusy: store.petOperationIDs.contains(featuredPet.id),
                        generationIsActive: store.generationSession.isActive,
                        onActivate: { store.activatePet(featuredPet) },
                        onCustomizeCopy: { store.preparePetCustomizationCopy(featuredPet) },
                        onRequestEdit: { requestEdit(featuredPet) },
                        onRequestHistory: { requestHistory(featuredPet) },
                        onExport: { store.exportPet(featuredPet) },
                        onRequestDelete: { pendingDeletePet = featuredPet }
                    )
                    .id(featuredPet.id)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(APCLocalization.format(.libraryAllCountFormat, store.pets.count))
                        .font(.headline)
                        .accessibilityIdentifier("pet-library.collection-title")

                    petGrid
                        .accessibilityIdentifier("pet-library.grid")
                }
            }
        }
    }

    @ViewBuilder
    private var petGrid: some View {
        if shellMode == .singleContent {
            petGrid(columnCount: 1)
        } else {
            ViewThatFits(in: .horizontal) {
                petGrid(columnCount: 4)
                    .frame(minWidth: PetLibraryGridPolicy.minimumWidth(for: 4))
                petGrid(columnCount: 3)
                    .frame(minWidth: PetLibraryGridPolicy.minimumWidth(for: 3))
                petGrid(columnCount: 2)
                    .frame(minWidth: PetLibraryGridPolicy.minimumWidth(for: 2))
            }
        }
    }

    private func petGrid(columnCount: Int) -> some View {
        LazyVGrid(
            columns: PetLibraryGridPolicy.columns(count: columnCount),
            alignment: .leading,
            spacing: PetLibraryGridPolicy.spacing
        ) {
            ForEach(filteredPets) { pet in
                PetCard(
                    pet: pet,
                    assetWarning: store.petAssetWarningIndex[pet.id],
                    selected: selectedPetID == pet.id,
                    activeEvent: store.activeOverlayEvent,
                    variantOrdinal: PetLibraryCardIdentityPolicy.variantOrdinal(
                        for: pet,
                        in: store.pets
                    ),
                    onSelect: { select(pet) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func select(_ pet: PetSummary) {
        selectedPetID = pet.id
    }

    private func selectDefaultPetIfNeeded() {
        guard selectedPetID == nil else { return }
        selectedPetID = PetLibrarySelectionPolicy.reconciledSelection(
            currentID: selectedPetID,
            pets: store.pets,
            preferredID: store.activePet?.id,
            allowsDefaultSelection: true
        )
    }

    private func reconcileSelection(oldIDs: [String], newIDs: [String]) {
        let hadMissingSelection = selectedPetID.map { !newIDs.contains($0) } ?? false
        let allowsDefault = hadMissingSelection || (oldIDs.isEmpty && !newIDs.isEmpty)
        selectedPetID = PetLibrarySelectionPolicy.reconciledSelection(
            currentID: selectedPetID,
            pets: store.pets,
            preferredID: store.activePet?.id,
            allowsDefaultSelection: allowsDefault
        )
    }

    private func requestEdit(_ pet: PetSummary) {
        guard PetLibraryCapabilities(pet: pet).canModify else { return }
        pendingPetSheet = PetLibrarySheetRequest(pet: pet, mode: .edit)
    }

    private func requestHistory(_ pet: PetSummary) {
        guard PetLibraryCapabilities(pet: pet).canModify else { return }
        pendingPetSheet = PetLibrarySheetRequest(pet: pet, mode: .history)
    }
}

private struct PetLibrarySheetRequest: Identifiable {
    enum Mode: String {
        case edit
        case history
    }

    let pet: PetSummary
    let mode: Mode
    var id: String { "\(pet.id)-\(mode.rawValue)" }
}

private struct PetLibraryNoticeBanner: View {
    let notice: PetLibraryNotice
    let retrying: Bool
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.systemImage)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Button(
                    APCLocalization.text(.libraryNoticeRetryImport),
                    systemImage: "arrow.clockwise",
                    action: onRetry
                )
                .disabled(retrying)
                .accessibilityIdentifier("pet-library.notice.retry")

                Button(
                    APCLocalization.text(.libraryNoticeDismiss),
                    systemImage: "xmark",
                    action: onDismiss
                )
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("pet-library.notice.dismiss")
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .systemOrange).opacity(0.72), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pet-library.notice.import-failure")
    }
}

private struct PetHistorySheet: View {
    @EnvironmentObject private var store: AppStore
    let pet: PetSummary
    let initialMode: PetLibrarySheetRequest.Mode
    let maximumInstructionCharacters: Int
    let onCancel: () -> Void
    let onStart: (String?, String) -> Void

    @State private var history: PetHistorySnapshot?
    @State private var loadFailed = false
    @State private var selectedRevisionID: String?
    @State private var instruction = ""
    @State private var isEditing: Bool

    init(
        pet: PetSummary,
        initialMode: PetLibrarySheetRequest.Mode,
        maximumInstructionCharacters: Int,
        onCancel: @escaping () -> Void,
        onStart: @escaping (String?, String) -> Void
    ) {
        self.pet = pet
        self.initialMode = initialMode
        self.maximumInstructionCharacters = maximumInstructionCharacters
        self.onCancel = onCancel
        self.onStart = onStart
        _isEditing = State(initialValue: initialMode == .edit)
    }

    private var presentation: PetLibraryPresentation {
        PetLibraryPresentation(pet: pet, assetWarning: store.petAssetWarningIndex[pet.id])
    }

    private var selectedRevision: PetRevisionHistoryRecord? {
        guard let selectedRevisionID else { return nil }
        return displayedRevisions.first(where: { $0.revisionID == selectedRevisionID })
    }

    private var displayedRevisions: [PetRevisionHistoryRecord] {
        history.map(PetLibraryHistoryBounds.revisions(in:)) ?? []
    }

    private var displayedJobs: [GenerationJobHistoryRecord] {
        history.map(PetLibraryHistoryBounds.jobs(in:)) ?? []
    }

    private var baselineState: PetHistoryBaselineState {
        PetHistoryBaselineState.resolve(
            history: history,
            loadFailed: loadFailed,
            selectedRevision: selectedRevision
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(
                    isEditing
                        ? APCLocalization.format(.libraryEditTitleFormat, pet.name)
                        : APCLocalization.format(.libraryHistorySheetTitleFormat, pet.name)
                )
                .font(.title2.weight(.semibold))
                Text(
                    isEditing
                        ? APCLocalization.text(.libraryEditDetail)
                        : APCLocalization.text(.libraryHistoryReadOnlyDetail)
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            ScrollView {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        baselineColumn
                            .frame(width: 235)
                        detailColumn
                            .frame(minWidth: 330)
                    }
                    .accessibilityIdentifier("pet-library.history.layout.wide")

                    VStack(alignment: .leading, spacing: 16) {
                        baselineColumn
                        detailColumn
                    }
                    .accessibilityIdentifier("pet-library.history.layout.compact")
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 300, idealHeight: 470, maxHeight: 540)

            if let history, PetLibraryHistoryBounds.isTruncated(history) {
                Label(APCLocalization.text(.libraryHistoryTruncated), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if store.generationSession.isActive {
                    Text(APCLocalization.text(.libraryEditActiveWarning))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(
                    APCLocalization.text(isEditing ? .commonCancel : .libraryHistoryClose),
                    action: onCancel
                )
                .accessibilityIdentifier("pet-library.history.cancel")

                if isEditing {
                    Button(APCLocalization.text(.libraryHistoryConfirmBaseline)) {
                        onStart(
                            selectedRevision?.validated == true ? selectedRevision?.revisionID : nil,
                            instruction
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
                    .accessibilityIdentifier("pet-library.edit.confirm")
                } else {
                    Button(APCLocalization.text(.libraryHistoryUseBaseline)) {
                        isEditing = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !presentation.canModify
                            || store.generationSession.isActive
                            || !baselineSelectionIsValid
                    )
                    .accessibilityIdentifier("pet-library.history.use-baseline")
                }
            }
        }
        .padding(24)
        .frame(
            minWidth: 520,
            idealWidth: 700,
            maxWidth: 780,
            minHeight: 420,
            idealHeight: 600,
            maxHeight: 700
        )
        .accessibilityIdentifier("pet-library.history.sheet")
        .task(id: pet.id) {
            await loadHistory()
        }
    }

    private var baselineColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(APCLocalization.text(.libraryEditBaseline)) {
                VStack(alignment: .leading, spacing: 10) {
                    RevisionCoverImage(
                        pet: pet,
                        revision: selectedRevision,
                        assetWarning: presentation.assetWarning
                    )
                        .frame(maxWidth: .infinity)
                        .frame(height: 130)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        }
                    Text(selectedRevision?.revisionID ?? presentation.revisionIDSummary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Label(
                        selectedRevision?.current == false
                            ? APCLocalization.text(.libraryHistoryOlderRevision)
                            : APCLocalization.text(.libraryHistoryCurrentRevision),
                        systemImage: selectedRevision?.current == false
                            ? "clock.arrow.circlepath"
                            : "checkmark.seal.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        selectedRevision?.current == false ? Color.secondary : Color.accentColor
                    )
                }
                .padding(.top, 4)
            }
            .accessibilityIdentifier("pet-library.edit.baseline")

            GroupBox(APCLocalization.text(.libraryHistoryRevisionsTitle)) {
                revisionList
                    .frame(height: 160)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(APCLocalization.text(.libraryCurrentInfo)) {
                VStack(spacing: 0) {
                    InfoRow(title: APCLocalization.text(.libraryFieldStableID), value: pet.id)
                    InfoRow(
                        title: APCLocalization.text(.libraryFieldRevisionID),
                        value: selectedRevision?.revisionID ?? presentation.revisionIDSummary
                    )
                    InfoRow(title: APCLocalization.text(.libraryFieldStates), value: presentation.stateSummary)
                    InfoRow(title: APCLocalization.text(.libraryFieldFPS), value: presentation.fpsSummary)
                    InfoRow(
                        title: APCLocalization.text(.libraryFieldDuration),
                        value: presentation.durationSummary
                    )
                    InfoRow(
                        title: APCLocalization.text(.libraryFieldValidation),
                        value: selectedRevision.map {
                            $0.validated
                                ? APCLocalization.text(.libraryHistoryValidated)
                                : APCLocalization.text(.libraryHistoryNotSelectable)
                        } ?? presentation.validationTitle
                    )
                }
            }

            GroupBox(APCLocalization.text(.libraryHistoryJobsTitle)) {
                jobList
                    .frame(height: isEditing ? 120 : 180)
            }

            if isEditing {
                editComposer
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var revisionList: some View {
        if history != nil, displayedRevisions.isEmpty {
            ContentUnavailableView(
                APCLocalization.text(.libraryHistoryNoOwnedRevisions),
                systemImage: "shippingbox"
            )
        } else if history != nil {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(displayedRevisions) { revision in
                        Button {
                            selectedRevisionID = revision.revisionID
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: revision.current ? "checkmark.circle.fill" : "clock")
                                    .foregroundStyle(revision.current ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(revision.current
                                        ? APCLocalization.text(.libraryHistoryCurrentRevision)
                                        : APCLocalization.text(.libraryHistoryOlderRevision))
                                        .font(.caption.weight(.semibold))
                                    Text(revision.revisionID)
                                        .font(.caption2.monospaced())
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: revision.validated ? "checkmark.seal" : "exclamationmark.triangle")
                                    .foregroundStyle(revision.validated ? Color.green : Color.orange)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(
                                        selectedRevisionID == revision.revisionID
                                            ? Color.accentColor.opacity(0.14)
                                            : Color.clear
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!revision.validated)
                        .accessibilityIdentifier("pet-library.history.revision.\(revision.revisionID)")
                    }
                }
            }
        } else if baselineState.canRetry {
            ContentUnavailableView {
                Label(
                    APCLocalization.text(.libraryHistoryFailedTitle),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(APCLocalization.text(.libraryHistoryFailedDetail))
            } actions: {
                Button(APCLocalization.text(.commonRetry)) {
                    Task { await loadHistory() }
                }
                .accessibilityIdentifier("pet-library.history.retry")
            }
        } else {
            ProgressView(APCLocalization.text(.libraryHistoryCheckingTitle))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var jobList: some View {
        if history != nil, displayedJobs.isEmpty {
            ContentUnavailableView(
                APCLocalization.text(.libraryHistoryNoRecords),
                systemImage: "clock"
            )
            .accessibilityIdentifier("pet-library.history.empty")
        } else if history != nil {
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(displayedJobs) { job in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: job.operation == .modify ? "wand.and.stars" : "sparkles")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(operationTitle(job.operation))
                                        .font(.callout.weight(.semibold))
                                    Text(statusTitle(job.status))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let revisionID = job.revisionID {
                                    Text(revisionID)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text(PetLibraryHistoryPresentation.localizedTimestamp(job.updatedAt))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 4)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        }
                    }
                }
            }
        } else if loadFailed {
            Text(APCLocalization.text(.libraryHistoryFailedDetail))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var editComposer: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(APCLocalization.text(.libraryEditInstruction))
                .font(.callout.weight(.semibold))
            TextEditor(text: Binding(
                get: { instruction },
                set: { instruction = GenerationPromptPolicy.truncate($0) }
            ))
                .font(.body)
                .frame(minHeight: 92)
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .accessibilityLabel(APCLocalization.text(.libraryEditInstructionAccessibility))
                .accessibilityIdentifier("pet-library.edit.instruction")
            HStack {
                Text(APCLocalization.text(.libraryHistoryImmutableNotice))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(APCLocalization.format(
                    .commonCharacterCountFormat,
                    GenerationPromptPolicy.scalarCount(instruction),
                    maximumInstructionCharacters
                ))
                .foregroundStyle(
                    GenerationPromptPolicy.scalarCount(instruction) > maximumInstructionCharacters
                        ? Color.red
                        : Color.secondary
                )
            }
            .font(.caption)
        }
    }

    private var canStart: Bool {
        presentation.canModify
            && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && GenerationPromptPolicy.scalarCount(instruction) <= maximumInstructionCharacters
            && !store.generationSession.isActive
            && baselineState.canStartEdit
    }

    private var baselineSelectionIsValid: Bool {
        baselineState.canStartEdit
    }

    @MainActor
    private func loadHistory() async {
        loadFailed = false
        history = nil
        selectedRevisionID = nil
        do {
            let loaded = try await store.fetchPetHistory(
                for: pet,
                limit: PetLibraryHistoryBounds.requestLimit
            )
            guard !Task.isCancelled else { return }
            history = loaded
            let revisions = PetLibraryHistoryBounds.revisions(in: loaded)
            selectedRevisionID = revisions.first(where: {
                $0.current && $0.validated
            })?.revisionID ?? revisions.first(where: \.validated)?.revisionID
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
    }

    private func operationTitle(_ operation: GenerationOperation) -> String {
        APCLocalization.text(
            operation == .modify ? .libraryHistoryOperationModify : .libraryHistoryOperationCreate
        )
    }

    private func statusTitle(_ status: GenerationJobHistoryStatus) -> String {
        switch status {
        case .pending: APCLocalization.text(.libraryHistoryStatusPending)
        case .running: APCLocalization.text(.libraryHistoryStatusRunning)
        case .waitingForUser: APCLocalization.text(.libraryHistoryStatusWaiting)
        case .completed: APCLocalization.text(.libraryHistoryStatusCompleted)
        case .failed: APCLocalization.text(.libraryHistoryStatusFailed)
        case .canceled: APCLocalization.text(.libraryHistoryStatusCancelled)
        }
    }
}

private struct RevisionCoverImage: View {
    let pet: PetSummary
    let revision: PetRevisionHistoryRecord?
    let assetWarning: PetAssetWarning?

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(8)
        } else if revision != nil {
            // Never present the current head's cover as if it belonged to a
            // selected historical baseline. A missing old preview remains an
            // explicit read-only placeholder.
            MissingPetCoverPlaceholder(scale: 0.36)
        } else {
            PetCoverImage(
                pet: pet,
                assetWarning: assetWarning,
                fallbackScale: 0.36
            )
        }
    }

    private var image: NSImage? {
        guard let path = revision?.coverPath else { return nil }
        return NSImage(contentsOfFile: path)
    }
}

private struct PetLibraryHero: View {
    let pet: PetSummary
    let productPresentation: PetLibraryProductPresentation
    let assetWarning: PetAssetWarning?
    let activeEvent: AgentEvent?
    let isBusy: Bool
    let generationIsActive: Bool
    let onActivate: () -> Void
    let onCustomizeCopy: () -> Void
    let onRequestEdit: () -> Void
    let onRequestHistory: () -> Void
    let onExport: () -> Void
    let onRequestDelete: () -> Void

    @State private var technicalInformationIsExpanded = false

    private var presentation: PetLibraryPresentation {
        PetLibraryPresentation(pet: pet, assetWarning: assetWarning)
    }

    private var status: ProductStatusPresentation? {
        guard pet.active else { return nil }
        return ProductStatusPresentation(
            appearance: .normal,
            title: APCLocalization.text(.libraryPetActive),
            detail: presentation.currentStateSummary(activeEvent: activeEvent)
        )
    }

    private var primaryAction: ProductActionPresentation<PetLibraryPrimaryAction> {
        ProductActionPresentation(
            action: productPresentation.primaryAction,
            title: APCLocalizedPresentation.primaryActionTitle(
                productPresentation.primaryAction
            ) ?? APCLocalization.text(.productActionUsePet),
            systemImage: pet.active ? "checkmark.circle.fill" : "checkmark.circle",
            isEnabled: productPresentation.primaryActionIsEnabled
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PrimaryExperienceCard(
                identity: ProductComponentIdentity(scope: "pet-library", instance: "featured"),
                title: pet.name,
                summary: presentation.heroSummary,
                status: status,
                primaryAction: primaryAction,
                onPrimaryAction: { action in
                    if action == .usePet {
                        onActivate()
                    }
                }
            ) {
                PetPreviewStage(
                    identity: ProductComponentIdentity(
                        scope: "pet-library",
                        instance: "featured"
                    ),
                    accessibilityLabel: APCLocalization.format(
                        .libraryAnimationAccessibilityFormat,
                        pet.name
                    ),
                    minimumHeight: 280
                ) {
                    PetLibraryAnimationPreview(
                        pet: pet,
                        assetWarning: assetWarning
                    )
                    .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 360)
                }

                HStack(alignment: .center, spacing: 10) {
                    PetLibrarySourceBadge(
                        accessibilityIdentifier: "pet-library.hero.source",
                        badge: presentation.sourceBadge
                    )
                    Text(presentation.styleTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                secondaryActions
            }

            AdvancedDetailsDisclosure(
                identity: ProductComponentIdentity(scope: "pet-library", instance: "technical"),
                title: APCLocalization.text(.libraryCurrentInfo),
                summary: APCLocalization.text(.libraryTechnicalInformationSummary),
                isExpanded: $technicalInformationIsExpanded
            ) {
                VStack(spacing: 0) {
                    ForEach(presentation.technicalInformation) { item in
                        InfoRow(title: item.title, value: item.value)
                    }
                }
            }
        }
        .accessibilityIdentifier("pet-library.hero")
    }

    private var secondaryActions: some View {
        HStack(spacing: 8) {
            if presentation.canCustomizeAsCopy {
                Button(
                    APCLocalization.text(.libraryCustomizeCopy),
                    systemImage: "doc.on.doc",
                    action: onCustomizeCopy
                )
                .disabled(isBusy || generationIsActive)
                .accessibilityIdentifier("pet-library.hero.customize-copy")
            }

            if presentation.canModify {
                Button(
                    APCLocalization.text(.libraryModifyAction),
                    systemImage: "wand.and.stars",
                    action: onRequestEdit
                )
                .disabled(isBusy || generationIsActive)
                .accessibilityIdentifier("pet-library.hero.modify")
            }

            if presentation.canDelete {
                Menu {
                    Button(
                        APCLocalization.text(.libraryHistoryAction),
                        systemImage: "clock.arrow.circlepath",
                        action: onRequestHistory
                    )
                    .disabled(generationIsActive)
                    .accessibilityIdentifier("pet-library.hero.history")

                    Button(
                        APCLocalization.text(.libraryExportAction),
                        systemImage: "square.and.arrow.up",
                        action: onExport
                    )
                    .accessibilityIdentifier("pet-library.hero.export")

                    Divider()

                    Button(
                        APCLocalization.text(.libraryDeleteAction),
                        systemImage: "trash",
                        role: .destructive,
                        action: onRequestDelete
                    )
                    .accessibilityIdentifier("pet-library.hero.delete")
                } label: {
                    Label(
                        APCLocalization.text(.appActionMore),
                        systemImage: "ellipsis.circle"
                    )
                }
                .disabled(isBusy)
                .accessibilityIdentifier("pet-library.hero.more")
            } else {
                Button(
                    APCLocalization.text(.libraryExportAction),
                    systemImage: "square.and.arrow.up",
                    action: onExport
                )
                .disabled(isBusy)
                .accessibilityIdentifier("pet-library.hero.export")
            }

            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("pet-library.hero.secondary-actions")
    }
}

struct PetCard: View {
    let pet: PetSummary
    let assetWarning: PetAssetWarning?
    let selected: Bool
    let activeEvent: AgentEvent?
    let variantOrdinal: Int?
    let onSelect: () -> Void

    private var presentation: PetLibraryPresentation {
        PetLibraryPresentation(pet: pet, assetWarning: assetWarning)
    }

    private var accessibilityPresentation: PetCardAccessibilityPresentation {
        PetCardAccessibilityPresentation(
            name: pet.name,
            styleTitle: presentation.styleTitle,
            sourceTitle: presentation.sourceTitle,
            variantOrdinal: variantOrdinal
        )
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                PetCoverImage(
                    pet: pet,
                    assetWarning: assetWarning,
                    fallbackScale: 0.34
                )
                    .frame(maxWidth: .infinity)
                    .frame(height: 104)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }

                Text(pet.name)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(presentation.styleTitle)
                    if let variantOrdinal {
                        Text("·")
                            .accessibilityHidden(true)
                        Text(APCLocalization.format(
                            .libraryCardVariantFormat,
                            variantOrdinal
                        ))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                PetLibrarySourceBadge(
                    accessibilityIdentifier: "pet-library.card.source.\(pet.id)",
                    badge: presentation.sourceBadge
                )

                Group {
                    if pet.active {
                        HStack(spacing: 5) {
                            Image(systemName: "bolt.fill")
                                .accessibilityHidden(true)
                            Text(presentation.currentStateSummary(activeEvent: activeEvent))
                                .lineLimit(1)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                    } else {
                        Color.clear
                            .frame(height: 14)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    selected
                        ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.16)
                        : Color(nsColor: .controlBackgroundColor)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    selected ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: selected ? 2 : 1
                )
                .allowsHitTesting(false)
        }
        .accessibilityLabel(accessibilityPresentation.label)
        .accessibilityValue(UIControlSemantics.selectionValue(isSelected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("pet-library.card.\(pet.id)")
    }
}

struct PetCardAccessibilityPresentation: Equatable {
    let label: String

    init(
        name: String,
        styleTitle: String,
        sourceTitle: String,
        variantOrdinal: Int?,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) {
        let baseLabel = APCLocalization.format(
            .libraryCardAccessibilityFormat,
            locale: localeIdentifier,
            name,
            styleTitle,
            sourceTitle
        )
        if let variantOrdinal {
            let variantLabel = APCLocalization.format(
                .libraryCardVariantFormat,
                locale: localeIdentifier,
                variantOrdinal
            )
            label = "\(baseLabel). \(variantLabel)"
        } else {
            label = baseLabel
        }
    }
}

private struct PetLibrarySourceBadge: View {
    let accessibilityIdentifier: String
    let badge: PetLibrarySourceBadgePresentation

    var body: some View {
        Label(badge.title, systemImage: badge.systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(toneColor)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(toneColor.opacity(0.10)))
            .overlay {
                Capsule()
                    .stroke(toneColor.opacity(0.30), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var toneColor: Color {
        switch badge.tone {
        case .bundled:
            Color.accentColor
        case .verified:
            Color.green
        case .generated:
            Color.purple
        case .external:
            Color.secondary
        }
    }
}

struct PetCoverImage: View {
    var pet: PetSummary
    var assetWarning: PetAssetWarning?
    var fallbackScale: CGFloat

    init(
        pet: PetSummary,
        assetWarning: PetAssetWarning? = nil,
        fallbackScale: CGFloat
    ) {
        self.pet = pet
        self.assetWarning = assetWarning
        self.fallbackScale = fallbackScale
    }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(6)
        } else {
            MissingPetCoverPlaceholder(scale: fallbackScale)
        }
    }

    private var image: NSImage? {
        guard let url = PetAssetLocator.coverURL(for: pet) else { return nil }
        return PetLibraryPreviewPolicy.loadIfValidated(
            assetWarning: assetWarning
        ) {
            NSImage(contentsOf: url)
        }
    }
}

struct MissingPetCoverPlaceholder: View {
    var scale: CGFloat

    var body: some View {
        VStack(spacing: 6 * scale) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: max(14, 32 * scale), weight: .semibold))
                .foregroundStyle(.secondary)
            Text(APCLocalization.text(.libraryMissingPreview))
                .font(.system(size: max(9, 16 * scale), weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

enum InfoRowLayoutMode: Equatable {
    case sideBySide
    case stacked
}

enum InfoRowLayoutPolicy {
    static let minimumSideBySideWidth: CGFloat = 260
    static let minimumSideBySideValueWidth: CGFloat = 112

    static func mode(for availableWidth: CGFloat) -> InfoRowLayoutMode {
        availableWidth >= minimumSideBySideWidth ? .sideBySide : .stacked
    }
}

private struct InfoRowResponsiveLayout: Layout {
    private let horizontalSpacing: CGFloat = 12
    private let verticalSpacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 2 else { return .zero }

        let availableWidth = finiteWidth(from: proposal)
        switch availableWidth.map(InfoRowLayoutPolicy.mode(for:)) ?? .stacked {
        case .sideBySide:
            return sideBySideSize(width: availableWidth!, subviews: subviews)
        case .stacked:
            return stackedSize(width: availableWidth, subviews: subviews)
        }
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }

        switch InfoRowLayoutPolicy.mode(for: bounds.width) {
        case .sideBySide:
            placeSideBySide(in: bounds, subviews: subviews)
        case .stacked:
            placeStacked(in: bounds, subviews: subviews)
        }
    }

    private func finiteWidth(from proposal: ProposedViewSize) -> CGFloat? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return max(0, width)
    }

    private func sideBySideSize(width: CGFloat, subviews: Subviews) -> CGSize {
        let titleDimensions = subviews[0].dimensions(in: .unspecified)
        let valueWidth = max(
            InfoRowLayoutPolicy.minimumSideBySideValueWidth,
            width - titleDimensions.width - horizontalSpacing
        )
        let valueProposal = ProposedViewSize(width: valueWidth, height: nil)
        let valueDimensions = subviews[1].dimensions(in: valueProposal)
        let baseline = max(
            titleDimensions[VerticalAlignment.firstTextBaseline],
            valueDimensions[VerticalAlignment.firstTextBaseline]
        )
        let height = max(
            baseline + titleDimensions.height
                - titleDimensions[VerticalAlignment.firstTextBaseline],
            baseline + valueDimensions.height
                - valueDimensions[VerticalAlignment.firstTextBaseline]
        )
        return CGSize(width: width, height: height)
    }

    private func stackedSize(width: CGFloat?, subviews: Subviews) -> CGSize {
        let childProposal = ProposedViewSize(width: width, height: nil)
        let titleSize = subviews[0].sizeThatFits(childProposal)
        let valueSize = subviews[1].sizeThatFits(childProposal)
        return CGSize(
            width: width ?? max(titleSize.width, valueSize.width),
            height: titleSize.height + verticalSpacing + valueSize.height
        )
    }

    private func placeSideBySide(in bounds: CGRect, subviews: Subviews) {
        let titleSize = subviews[0].sizeThatFits(.unspecified)
        let valueWidth = max(
            InfoRowLayoutPolicy.minimumSideBySideValueWidth,
            bounds.width - titleSize.width - horizontalSpacing
        )
        let valueProposal = ProposedViewSize(width: valueWidth, height: nil)
        let valueSize = subviews[1].sizeThatFits(valueProposal)
        let titleDimensions = subviews[0].dimensions(in: .unspecified)
        let valueDimensions = subviews[1].dimensions(in: valueProposal)
        let baseline = max(
            titleDimensions[VerticalAlignment.firstTextBaseline],
            valueDimensions[VerticalAlignment.firstTextBaseline]
        )

        subviews[0].place(
            at: CGPoint(
                x: bounds.minX,
                y: bounds.minY + baseline - titleDimensions[VerticalAlignment.firstTextBaseline]
            ),
            proposal: ProposedViewSize(titleSize)
        )
        subviews[1].place(
            at: CGPoint(
                x: bounds.maxX - valueSize.width,
                y: bounds.minY + baseline - valueDimensions[VerticalAlignment.firstTextBaseline]
            ),
            proposal: valueProposal
        )
    }

    private func placeStacked(in bounds: CGRect, subviews: Subviews) {
        let childProposal = ProposedViewSize(width: bounds.width, height: nil)
        let titleSize = subviews[0].sizeThatFits(childProposal)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            proposal: childProposal
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + titleSize.height + verticalSpacing),
            proposal: childProposal
        )
    }
}

private struct InfoRowWrappingValue: NSViewRepresentable {
    let value: String

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.setAccessibilityRole(.staticText)
        update(textView)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        update(textView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: NSTextView,
        context: Context
    ) -> CGSize? {
        guard let proposedWidth = proposal.width, proposedWidth.isFinite else { return nil }
        let width = max(0, proposedWidth)
        textView.frame.size.width = width
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager
        else {
            return CGSize(width: width, height: ceil(textView.intrinsicContentSize.height))
        }

        textContainer.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return CGSize(width: width, height: ceil(max(usedRect.height, textView.font?.pointSize ?? 0)))
    }

    private func update(_ textView: NSTextView) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        paragraphStyle.alignment = .left
        let attributedValue = NSAttributedString(
            string: value,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle,
            ]
        )
        if !textView.attributedString().isEqual(to: attributedValue) {
            textView.textStorage?.setAttributedString(attributedValue)
        }
        textView.setAccessibilityLabel(value)
    }
}

struct InfoRow: View {
    var title: String
    var value: String

    var body: some View {
        InfoRowResponsiveLayout {
            Text(title)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            InfoRowWrappingValue(value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
