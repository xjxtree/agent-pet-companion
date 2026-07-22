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
    @State private var inspectorWasDismissed = false
    @State private var transientInspectorPresented = false

    private var selectedPet: PetSummary? {
        guard let selectedPetID else { return nil }
        return store.pets.first(where: { $0.id == selectedPetID })
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

    private var inspectorIsPresented: Binding<Bool> {
        Binding(
            get: {
                selectedPet != nil
                    && (shellMode.keepsInspectorPresented || transientInspectorPresented)
            },
            set: { isPresented in
                if !isPresented {
                    transientInspectorPresented = false
                    if shellMode.keepsInspectorPresented {
                        selectedPetID = nil
                        inspectorWasDismissed = true
                    }
                }
            }
        )
    }

    var body: some View {
        PageScroll {
            PageActionHeader(
                title: APCLocalization.text(.navigationLibrary),
                subtitle: APCLocalization.text(.libraryPageSubtitle)
            ) {
                libraryActions
            }

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
        .toolbar {
            if !shellMode.keepsInspectorPresented {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        transientInspectorPresented.toggle()
                    } label: {
                        Label(
                            APCLocalization.text(.libraryInspectorTitle),
                            systemImage: "sidebar.right"
                        )
                    }
                    .disabled(selectedPet == nil)
                    .accessibilityIdentifier("pet-library.inspector-toggle")
                }
            }
        }
        .inspector(isPresented: inspectorIsPresented) {
            if let selectedPet {
                PetLibraryInspector(
                    pet: selectedPet,
                    onRequestEdit: requestEdit,
                    onRequestHistory: requestHistory,
                    onRequestDelete: { pendingDeletePet = $0 }
                )
                .inspectorColumnWidth(min: 286, ideal: 330, max: 390)
            }
        }
        .onAppear {
            selectDefaultPetIfNeeded()
        }
        .onChange(of: store.pets.map(\.id)) { oldIDs, newIDs in
            reconcileSelection(oldIDs: oldIDs, newIDs: newIDs)
        }
        .onChange(of: shellMode) { _, _ in
            transientInspectorPresented = false
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
            Button(APCLocalization.format(.libraryDeleteActionFormat, pet.name), role: .destructive) {
                store.deletePet(pet)
                pendingDeletePet = nil
            }
            Button(APCLocalization.text(.commonCancel), role: .cancel) {
                pendingDeletePet = nil
            }
        } message: { pet in
            Text(APCLocalization.format(.libraryDeleteMessageFormat, pet.name, pet.id))
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

    private var libraryActions: some View {
        HStack(spacing: 8) {
            TextField(APCLocalization.text(.librarySearchPlaceholder), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 190, idealWidth: 240, maxWidth: 280)
                .accessibilityIdentifier("pet-library.search")

            Button {
                store.importPetpacks()
            } label: {
                Label(
                    APCLocalization.text(
                        store.isImportingPetpack ? .libraryImportInProgress : .libraryImportAction
                    ),
                    systemImage: "square.and.arrow.down"
                )
            }
            .buttonStyle(.bordered)
            .disabled(store.isImportingPetpack)
            .accessibilityIdentifier("pet-library.import")

            Button {
                store.selection = .maker
            } label: {
                Label(APCLocalization.text(.libraryMakeAction), systemImage: "wand.and.stars")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("pet-library.make")
        }
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
            ContentUnavailableView {
                Label {
                    Text(APCLocalization.text(.libraryEmptyTitle))
                } icon: {
                    APCBrandMark(size: 24)
                        .accessibilityHidden(true)
                }
            } description: {
                Text(APCLocalization.text(.libraryEmptyDetail))
            } actions: {
                Button(APCLocalization.text(.libraryEmptyAction)) {
                    store.selection = .maker
                }
                .accessibilityIdentifier("pet-library.empty.make")
            }
            .frame(maxWidth: .infinity, minHeight: 320)
            .accessibilityIdentifier("pet-library.empty")

        case .searchEmpty:
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, minHeight: 320)
                .accessibilityIdentifier("pet-library.search-empty")

        case .results:
            VStack(alignment: .leading, spacing: 12) {
                Text(APCLocalization.format(.libraryAllCountFormat, filteredPets.count))
                    .font(.headline)
                    .foregroundStyle(.secondary)

                petGrid
                    .accessibilityIdentifier("pet-library.grid")
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
                    selected: selectedPetID == pet.id,
                    activeEvent: store.activeOverlayEvent,
                    onSelect: { select(pet) },
                    onActivate: { store.activatePet(pet) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func select(_ pet: PetSummary) {
        selectedPetID = pet.id
        inspectorWasDismissed = false
    }

    private func selectDefaultPetIfNeeded() {
        guard selectedPetID == nil, !inspectorWasDismissed else { return }
        selectedPetID = PetLibrarySelectionPolicy.reconciledSelection(
            currentID: selectedPetID,
            pets: store.pets,
            preferredID: store.activePet?.id,
            allowsDefaultSelection: true
        )
    }

    private func reconcileSelection(oldIDs: [String], newIDs: [String]) {
        let hadMissingSelection = selectedPetID.map { !newIDs.contains($0) } ?? false
        let allowsDefault = hadMissingSelection
            || (!inspectorWasDismissed && oldIDs.isEmpty && !newIDs.isEmpty)
        selectedPetID = PetLibrarySelectionPolicy.reconciledSelection(
            currentID: selectedPetID,
            pets: store.pets,
            preferredID: store.activePet?.id,
            allowsDefaultSelection: allowsDefault
        )
        if hadMissingSelection { inspectorWasDismissed = false }
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
        return history?.revisions.first(where: { $0.revisionID == selectedRevisionID })
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

            if history?.truncated == true {
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
                    RevisionCoverImage(pet: pet, revision: selectedRevision)
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
        if let history, history.revisions.isEmpty {
            ContentUnavailableView(
                APCLocalization.text(.libraryHistoryNoOwnedRevisions),
                systemImage: "shippingbox"
            )
        } else if let history {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(history.revisions) { revision in
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
        if let history, history.jobs.isEmpty {
            ContentUnavailableView(
                APCLocalization.text(.libraryHistoryNoRecords),
                systemImage: "clock"
            )
            .accessibilityIdentifier("pet-library.history.empty")
        } else if let history {
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(history.jobs) { job in
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
            let loaded = try await store.fetchPetHistory(for: pet)
            guard !Task.isCancelled else { return }
            history = loaded
            selectedRevisionID = loaded.revisions.first(where: {
                $0.current && $0.validated
            })?.revisionID ?? loaded.revisions.first(where: \.validated)?.revisionID
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

#if DEBUG
/// Production sheet content hosted directly by the deterministic UI Next
/// renderer. The fixture store supplies the same typed history snapshot that
/// the live sheet receives from PetCore, so visual evidence never duplicates
/// or approximates this workflow.
struct UINextPetHistorySheetFixture: View {
    let pet: PetSummary

    var body: some View {
        PetHistorySheet(
            pet: pet,
            initialMode: .edit,
            maximumInstructionCharacters: GenerationPromptPolicy.maximumScalarCount,
            onCancel: {},
            onStart: { _, _ in }
        )
    }
}
#endif

private struct RevisionCoverImage: View {
    let pet: PetSummary
    let revision: PetRevisionHistoryRecord?

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
            PetCoverImage(pet: pet, fallbackScale: 0.36)
        }
    }

    private var image: NSImage? {
        guard let path = revision?.coverPath else { return nil }
        return NSImage(contentsOfFile: path)
    }
}

struct PetCard: View {
    let pet: PetSummary
    let selected: Bool
    let activeEvent: AgentEvent?
    let onSelect: () -> Void
    let onActivate: () -> Void

    private var presentation: PetLibraryPresentation {
        PetLibraryPresentation(pet: pet, assetWarning: nil)
    }

    private var accessibilityPresentation: PetCardAccessibilityPresentation {
        PetCardAccessibilityPresentation(
            name: pet.name,
            sourceTitle: presentation.sourceTitle,
            stableID: pet.id,
            isActive: pet.active
        )
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    PetCoverImage(pet: pet, fallbackScale: 0.34)
                        .frame(maxWidth: .infinity)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .padding(8)
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: 104)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .underPageBackgroundColor))
                }

                Text(pet.name)
                    .font(.headline)
                    .lineLimit(1)

                PetLibrarySourceBadge(petID: pet.id, badge: presentation.sourceBadge)

                HStack(spacing: 5) {
                    Image(systemName: pet.active ? "bolt.fill" : "circle")
                        .accessibilityHidden(true)
                    Text(presentation.currentStateSummary(activeEvent: activeEvent))
                        .lineLimit(1)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(pet.active ? Color.accentColor : Color.secondary)
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
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onSelect()
                onActivate()
            }
        )
        .onKeyPress(.return) {
            guard selected else { return .ignored }
            onActivate()
            return .handled
        }
        .accessibilityLabel(accessibilityPresentation.label)
        .accessibilityValue(UIControlSemantics.selectionValue(isSelected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .modifier(PetCardAccessibilityActions(
            activateActionName: accessibilityPresentation.activateActionName,
            onActivate: onActivate
        ))
        .accessibilityIdentifier("pet-library.card.\(pet.id)")
    }
}

struct PetCardAccessibilityPresentation: Equatable {
    let label: String
    let activateActionName: String?

    init(
        name: String,
        sourceTitle: String,
        stableID: String,
        isActive: Bool,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) {
        label = APCLocalization.format(
            .libraryCardAccessibilityFormat,
            locale: localeIdentifier,
            name,
            sourceTitle,
            stableID
        )
        activateActionName = isActive
            ? nil
            : APCLocalization.text(.libraryActivateAccessibility, locale: localeIdentifier)
    }
}

private struct PetCardAccessibilityActions: ViewModifier {
    let activateActionName: String?
    let onActivate: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let activateActionName {
            content.accessibilityAction(named: activateActionName) {
                onActivate()
            }
        } else {
            content
        }
    }
}

private struct PetLibrarySourceBadge: View {
    let petID: String
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
            .accessibilityIdentifier("pet-library.card.source.\(petID)")
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

private struct PetLibraryInspector: View {
    @EnvironmentObject private var store: AppStore
    let pet: PetSummary
    let onRequestEdit: (PetSummary) -> Void
    let onRequestHistory: (PetSummary) -> Void
    let onRequestDelete: (PetSummary) -> Void

    @State private var historyRecordCount: Int?
    @State private var historyLookupFailed = false

    private var presentation: PetLibraryPresentation {
        PetLibraryPresentation(
            pet: pet,
            assetWarning: store.petAssetWarningIndex[pet.id]
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(APCLocalization.text(.libraryInspectorTitle))
                    .font(.title3.weight(.semibold))

                PetLibraryAnimationPreview(pet: pet)
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 190)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(pet.name)
                        .font(.title3.weight(.semibold))
                    Text(pet.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Button {
                    store.activatePet(pet)
                } label: {
                    Label(
                        APCLocalization.text(pet.active ? .libraryPetActive : .libraryEnablePet),
                        systemImage: "checkmark.circle"
                    )
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pet.active || isBusy)
                .accessibilityIdentifier("pet-library.inspector.activate")

                GroupBox(APCLocalization.text(.libraryCurrentInfo)) {
                    VStack(spacing: 0) {
                        InfoRow(title: APCLocalization.text(.libraryFieldCurrentState), value: presentation.currentStateSummary(activeEvent: store.activeOverlayEvent))
                        InfoRow(title: APCLocalization.text(.libraryFieldSource), value: presentation.sourceTitle)
                        InfoRow(title: APCLocalization.text(.libraryFieldPackageVersion), value: presentation.packageVersionSummary)
                        InfoRow(title: APCLocalization.text(.libraryFieldQuality), value: "\(pet.renderSize.width)×\(pet.renderSize.height)")
                        InfoRow(title: APCLocalization.text(.libraryFieldStates), value: presentation.stateSummary)
                        InfoRow(title: APCLocalization.text(.libraryFieldFPS), value: presentation.fpsSummary)
                        InfoRow(title: APCLocalization.text(.libraryFieldRevisionID), value: presentation.revisionIDSummary)
                        InfoRow(title: APCLocalization.text(.libraryFieldImmutableRevisions), value: presentation.revisionCountSummary)
                        InfoRow(title: APCLocalization.text(.libraryFieldRevisionPolicy), value: presentation.revisionPolicySummary)
                        InfoRow(title: APCLocalization.text(.libraryFieldValidation), value: presentation.validationTitle)
                    }
                }

                Text(presentation.validationDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(APCLocalization.format(
                        .libraryValidationDetailAccessibilityFormat,
                        presentation.validationDetail
                    ))

                if presentation.canModify {
                    GroupBox(APCLocalization.text(.libraryHistoryAction)) {
                        Label {
                            Text(historySummary)
                                .font(.callout.weight(.medium))
                        } icon: {
                            Image(systemName: historyRecordCount == 0 ? "clock" : "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("pet-library.inspector.history-summary")
                }

                if presentation.isBundled {
                    Label(
                        APCLocalization.text(.libraryBundledNote),
                        systemImage: "shippingbox.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pet-library.inspector.bundled-note")
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text(APCLocalization.text(.libraryObjectActions))
                        .font(.headline)

                    if presentation.canCustomizeAsCopy {
                        Button(APCLocalization.text(.libraryCustomizeCopy), systemImage: "doc.on.doc") {
                            store.preparePetCustomizationCopy(pet)
                        }
                        .disabled(isBusy || store.generationSession.isActive)
                        .accessibilityIdentifier("pet-library.inspector.customize-copy")
                    }

                    if presentation.canModify {
                        Button(APCLocalization.text(.libraryModifyAction), systemImage: "wand.and.stars") {
                            onRequestEdit(pet)
                        }
                        .disabled(isBusy || store.generationSession.isActive)
                        .accessibilityIdentifier("pet-library.inspector.modify")

                        Button(APCLocalization.text(.libraryHistoryAction), systemImage: "text.bubble") {
                            onRequestHistory(pet)
                        }
                        .disabled(isBusy || store.generationSession.isActive)
                        .accessibilityIdentifier("pet-library.inspector.history")
                    }

                    Button(APCLocalization.text(.libraryExportAction), systemImage: "square.and.arrow.up") {
                        store.exportPet(pet)
                    }
                    .disabled(isBusy)
                    .accessibilityIdentifier("pet-library.inspector.export")

                    if presentation.canDelete {
                        Menu {
                            Button(
                                APCLocalization.text(.libraryDeleteAction),
                                systemImage: "trash",
                                role: .destructive
                            ) {
                                onRequestDelete(pet)
                            }
                            .accessibilityIdentifier("pet-library.inspector.delete")
                        } label: {
                            Label(
                                APCLocalization.text(.appActionMore),
                                systemImage: "ellipsis.circle"
                            )
                        }
                        .disabled(isBusy)
                        .accessibilityIdentifier("pet-library.inspector.more")
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
        }
        .accessibilityIdentifier("pet-library.inspector")
        .task(id: pet.id) {
            guard presentation.canModify else { return }
            historyRecordCount = nil
            historyLookupFailed = false
            do {
                let history = try await store.fetchPetHistory(for: pet, limit: 1)
                guard !Task.isCancelled else { return }
                historyRecordCount = history.jobs.count
            } catch {
                guard !Task.isCancelled else { return }
                historyLookupFailed = true
            }
        }
    }

    private var historySummary: String {
        if historyLookupFailed {
            return APCLocalization.text(.libraryHistoryFailedTitle)
        }
        guard let historyRecordCount else {
            return APCLocalization.text(.libraryHistoryCheckingTitle)
        }
        if historyRecordCount == 0 {
            return APCLocalization.text(.libraryHistoryNoRecords)
        }
        return APCLocalization.text(.libraryHistoryAvailableTitle)
    }

    private var isBusy: Bool {
        store.petOperationIDs.contains(pet.id)
    }
}

struct PetCoverImage: View {
    var pet: PetSummary
    var fallbackScale: CGFloat

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
        return NSImage(contentsOf: url)
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
    static let minimumSideBySideWidth: CGFloat = 300
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
        let titleSize = subviews[0].sizeThatFits(.unspecified)
        let valueWidth = max(
            InfoRowLayoutPolicy.minimumSideBySideValueWidth,
            width - titleSize.width - horizontalSpacing
        )
        let valueSize = subviews[1].sizeThatFits(ProposedViewSize(width: valueWidth, height: nil))
        return CGSize(width: width, height: max(titleSize.height, valueSize.height))
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

struct InfoRow: View {
    var title: String
    var value: String

    var body: some View {
        InfoRowResponsiveLayout {
            Text(title)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
