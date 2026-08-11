import AgentPetCompanionCore
import AppKit
import SwiftUI

/// The AI Pet Maker owns its session browser. ChatGPT/Codex may expose the
/// underlying thread, but that external surface is neither the product UI nor
/// a prerequisite for recovery.
struct MakerSessionWorkspace: View {
    var body: some View {
        VStack(spacing: 0) {
            MakerWorkspaceHeader()

            LayoutPreservingHorizontalSeparatorGap()

            HSplitView {
                MakerSessionSidebar()
                    .makerWorkspacePaneSurface()
                    .padding(.trailing, 7)
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 400)
                    .anchorPreference(
                        key: MakerSplitDividerAnchorKey.self,
                        value: .bounds
                    ) { $0 }
                MakerSessionContent()
                    .makerWorkspacePaneSurface()
                    .padding(.leading, 7)
                    .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlayPreferenceValue(MakerSplitDividerAnchorKey.self) { anchor in
                GeometryReader { geometry in
                    if let anchor {
                        let leftPaneBounds = geometry[anchor]
                        Rectangle()
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .frame(width: 3, height: geometry.size.height)
                            .position(
                                x: leftPaneBounds.maxX + 0.5,
                                y: geometry.size.height / 2
                            )
                            .accessibilityHidden(true)
                    }
                }
                .allowsHitTesting(false)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maker.workspace.split")
    }
}

private struct MakerSplitDividerAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(
        value: inout Anchor<CGRect>?,
        nextValue: () -> Anchor<CGRect>?
    ) {
        value = nextValue() ?? value
    }
}

private struct MakerWorkspaceHeader: View {
    @EnvironmentObject private var store: AppStore
    @State private var portableSkillManagerPresented = false

    private var unfinishedJob: GenerationStudioHistoryRecord? {
        store.generationHistorySnapshot.jobs.first(where: MakerSessionPolicy.isUnfinished)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            ProductPageHeader(
                identity: ProductComponentIdentity(scope: "maker", instance: "workspace"),
                title: APCLocalization.text(.studioPageTitle),
                summary: APCLocalization.text(.studioWorkspacePageSubtitle)
            )

            Button {
                portableSkillManagerPresented = true
            } label: {
                Label(
                    APCLocalization.text(.studioPortableSkillAction),
                    systemImage: "wand.and.stars"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(APCLocalization.text(.studioPortableSkillSubtitle))
            .accessibilityIdentifier("maker.portable-skill.open")

            Button {
                store.beginMakerDraft()
            } label: {
                Label(APCLocalization.text(.studioActionNew), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(unfinishedJob != nil || store.makerDraftIsActive)
            .help(newTaskHelp)
            .accessibilityIdentifier("maker.session-list.new")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maker.workspace.header")
        .sheet(isPresented: $portableSkillManagerPresented) {
            PortableMakerSkillManagementSheet()
                .environmentObject(store)
        }
    }

    private var newTaskHelp: String {
        if unfinishedJob != nil {
            return APCLocalization.text(.studioWorkspaceActiveTaskBlocksNew)
        }
        return APCLocalization.text(.studioActionNew)
    }
}

private struct MakerSessionSidebar: View {
    @EnvironmentObject private var store: AppStore

    private let draftSelection = "__maker_draft__"

    private var selection: Binding<String?> {
        Binding(
            get: {
                store.makerDraftIsActive
                    ? draftSelection
                    : store.selectedGenerationHistoryJobID
            },
            set: { selection in
                guard let selection else { return }
                if selection == draftSelection {
                    store.beginMakerDraft()
                } else {
                    store.selectGenerationHistoryJob(selection)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(APCLocalization.text(.studioHistoryTitle))
                    .font(.headline)
                Spacer()
                Text(
                    APCLocalization.format(
                        .studioWorkspaceHistoryCountFormat,
                        store.generationHistorySnapshot.jobs.count
                    )
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            if store.generationHistoryIsLoading
                && store.generationHistorySnapshot.jobs.isEmpty
                && !store.makerDraftIsActive {
                ProgressView(APCLocalization.text(.studioHistoryLoading))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selection) {
                    if store.makerDraftIsActive {
                        MakerDraftSidebarRow()
                            .tag(draftSelection)
                            .makerSessionListRowChrome()
                    }

                    Section {
                        ForEach(store.generationHistorySnapshot.jobs) { job in
                            MakerSessionSidebarRow(job: job)
                                .tag(job.jobID)
                                .makerSessionListRowChrome()
                        }
                    } header: {
                        Text(APCLocalization.text(.studioWorkspaceRecent))
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("maker.session-list")
            }
        }
        .background(.bar, ignoresSafeAreaEdges: .all)
    }
}

private struct MakerDraftSidebarRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(APCLocalization.text(.studioNewPet))
                    .font(.callout.weight(.semibold))
                Text(APCLocalization.text(.studioWorkspaceDraftSubtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("maker.session-list.draft")
    }
}

private struct MakerSessionSidebarRow: View {
    let job: GenerationStudioHistoryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                StatusBadge(
                    title: MakerSessionPolicy.statusTitle(job),
                    tone: MakerSessionPolicy.statusTone(job)
                )
            }

            ProgressView(value: (job.progress ?? 0).clamped(to: 0 ... 1))
                .controlSize(.mini)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    Label(
                        MakerSessionClock.duration(
                            startedAt: job.startedAt,
                            endedAt: job.endedAt,
                            now: context.date
                        ),
                        systemImage: "clock"
                    )
                    Spacer(minLength: 4)
                    Text(MakerSessionClock.relative(job.updatedAt, now: context.date))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("maker.session-list.job.\(job.jobID)")
    }

    private var title: String {
        let visible = job.visibleTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return visible.flatMap { $0.isEmpty ? nil : $0 } ?? job.briefPreview
    }
}

private extension View {
    func makerWorkspacePaneSurface() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            }
    }

    func makerSessionListRowChrome() -> some View {
        padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                Divider()
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .listRowSeparator(.hidden)
    }
}

private struct MakerSessionContent: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            if store.makerDraftIsActive {
                MakerDraftContent()
            } else if store.selectedGenerationHistoryJobID != nil {
                MakerConversationContent()
            } else if store.generationHistoryLoadFailed {
                ContentUnavailableView {
                    Label(
                        APCLocalization.text(.studioHistoryLoadFailed),
                        systemImage: "exclamationmark.triangle"
                    )
                } actions: {
                    Button(APCLocalization.text(.commonRetry)) {
                        Task { await store.prepareMakerWorkspace() }
                    }
                }
            } else {
                ContentUnavailableView(
                    APCLocalization.text(.studioHistoryEmpty),
                    systemImage: "sparkles"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MakerDraftContent: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProductPageHeader(
                    identity: ProductComponentIdentity(scope: "maker", instance: "draft"),
                    title: APCLocalization.text(.studioNewPet),
                    summary: store.generationStartPresentationDetail
                )
                MakerBriefView()
                    .frame(maxWidth: 760, alignment: .leading)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                Button(role: .cancel) {
                    store.discardMakerDraft()
                } label: {
                    Label(
                        APCLocalization.text(.studioWorkspaceDiscardDraft),
                        systemImage: "xmark"
                    )
                }
                .accessibilityIdentifier("maker.draft.discard")
                if let detail = store.generationStartBlockingDetail {
                    Label(detail, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.startGeneration()
                } label: {
                    Label(APCLocalization.text(.studioActionStart), systemImage: "sparkles")
                }
                .apcClearGlassButtonStyle(prominent: true)
                .disabled(!store.canStartGeneration)
                .accessibilityIdentifier("maker.draft.submit")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maker.draft")
    }
}

private struct MakerConversationContent: View {
    @EnvironmentObject private var store: AppStore
    @State private var cancelConfirmationPresented = false
    @State private var deleteConfirmationPresented = false

    var body: some View {
        Group {
            if let detail = store.selectedGenerationHistoryDetail {
                MakerMessageTimeline(
                    messages: store.generationHistoryMessages,
                    hasMore: store.generationHistoryMessagesHasMore,
                    isLoading: store.generationHistoryMessagesIsLoading
                )
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Divider()
                        MakerConversationActionBar(
                            detail: detail,
                            copyBrief: {
                                _ = store.copySelectedGenerationHistoryBriefToNewDraft()
                            },
                            cancel: { cancelConfirmationPresented = true },
                            delete: { deleteConfirmationPresented = true }
                        )
                        Divider()
                        MakerSessionStatusPanel(detail: detail)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else if store.generationHistoryDetailIsLoading {
                ProgressView(APCLocalization.text(.studioHistoryLoading))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    APCLocalization.text(.studioHistoryLoadFailed),
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            APCLocalization.text(.studioCancelConfirmTitle),
            isPresented: $cancelConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(APCLocalization.text(.studioCancelConfirmAction), role: .destructive) {
                store.cancelSelectedGenerationHistory()
            }
            Button(APCLocalization.text(.commonCancel), role: .cancel) {}
        } message: {
            Text(APCLocalization.text(.studioCancelConfirmDetail))
        }
        .confirmationDialog(
            APCLocalization.text(.studioHistoryDeleteConfirmTitle),
            isPresented: $deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let jobID = store.selectedGenerationHistoryJobID {
                Button(
                    APCLocalization.text(.studioHistoryDeleteConfirmAction),
                    role: .destructive
                ) {
                    Task { _ = await store.deleteGenerationHistory(jobID: jobID) }
                }
            }
            Button(APCLocalization.text(.commonCancel), role: .cancel) {}
        } message: {
            Text(APCLocalization.text(.studioHistoryDeleteConfirmDetail))
        }
        .accessibilityIdentifier("maker.session-detail")
    }
}

private struct MakerConversationActionBar: View {
    let detail: GenerationStudioHistoryDetail
    let copyBrief: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                sessionMetrics
                Spacer(minLength: 12)
                MakerConversationActions(
                    detail: detail,
                    compact: false,
                    copyBrief: copyBrief,
                    cancel: cancel,
                    delete: delete
                )
            }

            HStack(spacing: 10) {
                sessionMetrics
                Spacer(minLength: 8)
                MakerConversationActions(
                    detail: detail,
                    compact: true,
                    copyBrief: copyBrief,
                    cancel: cancel,
                    delete: delete
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maker.session-action-bar")
    }

    private var sessionMetrics: some View {
        HStack(spacing: 10) {
            if let status = detail.status {
                StatusBadge(
                    title: MakerSessionPolicy.statusTitle(status, detail: detail),
                    tone: MakerSessionPolicy.statusTone(status, detail: detail)
                )
            }

            ProgressView(value: progress)
                .frame(minWidth: 90, idealWidth: 180, maxWidth: 220)

            Text("\(Int(progress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Divider()
                .frame(height: 16)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label(
                    MakerSessionClock.duration(
                        startedAt: detail.startedAt,
                        endedAt: detail.endedAt,
                        now: context.date
                    ),
                    systemImage: "clock"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var progress: Double {
        (detail.progress ?? 0).clamped(to: 0 ... 1)
    }
}

private struct MakerConversationActions: View {
    @EnvironmentObject private var store: AppStore
    let detail: GenerationStudioHistoryDetail
    let compact: Bool
    let copyBrief: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if compact, hasSupplementaryActions {
                Menu {
                    supplementaryActions
                } label: {
                    Label(APCLocalization.text(.appActionMore), systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                supplementaryActions
            }

            if detail.capabilities?.canDelete == true {
                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help(APCLocalization.text(.studioHistoryDeleteConfirmAction))
                .accessibilityLabel(APCLocalization.text(.studioHistoryDeleteConfirmAction))
            }
        }
    }

    @ViewBuilder
    private var supplementaryActions: some View {
        if detail.capabilities?.canOpenResult == true {
            Button {
                Task { _ = await store.showSelectedGenerationHistoryResultPetInLibrary() }
            } label: {
                Label(APCLocalization.text(.studioHistoryViewPet), systemImage: "pawprint")
            }
        }
        if detail.capabilities?.canOpenSession == true {
            Button {
                store.openGenerationHistorySession()
            } label: {
                Label(
                    APCLocalization.text(.studioHistoryOpenChatGPT),
                    systemImage: "arrow.up.right.square"
                )
            }
        }
        if detail.status == .failed,
           detail.recoverable != true,
           store.canCopySelectedGenerationHistoryBrief {
            Button(action: copyBrief) {
                Label(
                    APCLocalization.text(.studioHistoryCopyBrief),
                    systemImage: "doc.on.doc"
                )
            }
        }
        if detail.capabilities?.canCancel == true {
            Button(role: .destructive, action: cancel) {
                Label(
                    APCLocalization.text(.studioActionCancelTask),
                    systemImage: "xmark.circle"
                )
            }
        }
    }

    private var hasSupplementaryActions: Bool {
        detail.capabilities?.canOpenResult == true
            || detail.capabilities?.canOpenSession == true
            || (
                detail.status == .failed
                    && detail.recoverable != true
                    && store.canCopySelectedGenerationHistoryBrief
            )
            || detail.capabilities?.canCancel == true
    }
}

private struct MakerSessionStatusPanel: View {
    @EnvironmentObject private var store: AppStore
    let detail: GenerationStudioHistoryDetail

    private let previewSize = CGSize(width: 72, height: 78)

    private var capabilities: GenerationSessionCapabilities {
        detail.capabilities ?? .init()
    }

    private var pet: PetSummary? {
        store.selectedGenerationHistoryResultPet
    }

    private var summaryKind: MakerSessionSummaryKind {
        MakerSessionPolicy.summaryKind(
            status: detail.status,
            recoverable: detail.recoverable,
            cancellationPending: detail.cancellationPending
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            summaryVisual

            VStack(alignment: .leading, spacing: 6) {
                Text(summaryTitle)
                    .font(.headline)
                    .textSelection(.enabled)

                if summaryKind == .completed {
                    completedContent
                } else {
                    Text(summaryDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if capabilities.canReply || capabilities.canResume {
                    inlineComposer
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            Color(nsColor: .controlBackgroundColor)
                .overlay(toneColor.opacity(0.07))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maker.session-status-panel")
    }

    @ViewBuilder
    private var summaryVisual: some View {
        if summaryKind == .completed, let pet {
            PetCoverImage(
                pet: pet,
                assetWarning: store.petAssetWarningIndex[pet.id],
                fallbackScale: 0.7
            )
            .frame(width: previewSize.width, height: previewSize.height)
            .background(Color(nsColor: .textBackgroundColor), in: previewShape)
            .clipShape(previewShape)
            .overlay { previewShape.stroke(Color.secondary.opacity(0.16), lineWidth: 1) }
        } else {
            Image(systemName: summarySystemImage)
                .font(.title2)
                .foregroundStyle(toneColor)
                .frame(width: previewSize.width, height: previewSize.height)
                .background(toneColor.opacity(0.10), in: previewShape)
                .overlay { previewShape.stroke(toneColor.opacity(0.24), lineWidth: 1) }
        }
    }

    @ViewBuilder
    private var completedContent: some View {
        if pet != nil {
            Text(APCLocalization.text(.studioSuccessGeneric))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let validation = detail.validationSummary {
            Label(
                APCLocalization.format(
                    .studioSuccessValidationFormat,
                    validation.stateCount,
                    validation.frameCount,
                    validation.warningCount
                ),
                systemImage: validation.ok ? "checkmark.seal" : "exclamationmark.triangle"
            )
            .font(.callout)
            .foregroundStyle(validation.ok ? Color.secondary : Color.orange)
        }

        if detail.capabilities?.canOpenResult == true {
            Button {
                Task { _ = await store.showSelectedGenerationHistoryResultPetInLibrary() }
            } label: {
                Label(APCLocalization.text(.studioHistoryViewPet), systemImage: "pawprint")
            }
            .buttonStyle(.borderless)
        }
    }

    private var inlineComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                APCLocalization.text(
                    capabilities.canReply
                        ? .studioWorkspaceReplyPlaceholder
                        : .studioWorkspaceResumePlaceholder
                ),
                text: $store.generationReplyText,
                axis: .vertical
            )
            .lineLimit(1 ... 5)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("maker.session-composer")

            Button {
                if capabilities.canReply {
                    store.sendSelectedGenerationHistoryReply()
                } else {
                    store.resumeSelectedGenerationHistory()
                }
            } label: {
                Label(
                    APCLocalization.text(
                        capabilities.canReply
                            ? .studioWorkspaceSend
                            : .studioWorkspaceContinue
                    ),
                    systemImage: capabilities.canReply ? "arrow.up" : "arrow.clockwise"
                )
            }
            .apcClearGlassButtonStyle(prominent: true)
            .accessibilityIdentifier(
                capabilities.canReply
                    ? "maker.session.send"
                    : "maker.session.continue"
            )
            .disabled(
                capabilities.canReply
                    ? store.generationReplyText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                    : !store.canResumeSelectedGenerationHistory
            )
        }
        .padding(.top, 2)
    }

    private var summaryTitle: String {
        if summaryKind == .completed, let pet {
            return pet.name
        }
        if let status = detail.status {
            return MakerSessionPolicy.statusTitle(status, detail: detail)
        }
        return APCLocalization.text(.studioHistoryLoading)
    }

    private var summaryDetail: String {
        let key: APCLocalizationKey = switch summaryKind {
        case .pending, .running:
            .studioWorkspaceRunningHint
        case .waitingForUser:
            .studioWorkspaceReplyHint
        case .completed:
            .studioSuccessGeneric
        case .recoverableFailure:
            .studioWorkspaceResumeHint
        case .failed:
            .studioWorkspaceNonResumableFailureHint
        case .canceled:
            .studioWorkspaceCanceledHint
        case .cancellationPending:
            .studioWorkspaceCancelCleanup
        case .unknown:
            .studioHistoryLoading
        }
        return APCLocalization.text(key)
    }

    private var summarySystemImage: String {
        switch summaryKind {
        case .pending: "clock.fill"
        case .running: "sparkles"
        case .waitingForUser: "questionmark.bubble.fill"
        case .completed: "checkmark.seal.fill"
        case .recoverableFailure: "arrow.clockwise.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .canceled: "xmark.circle.fill"
        case .cancellationPending: "hourglass"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private var toneColor: Color {
        switch summaryKind {
        case .pending, .running, .waitingForUser:
            APCDesign.accent
        case .completed:
            APCDesign.success
        case .recoverableFailure, .cancellationPending:
            APCDesign.warning
        case .failed:
            APCDesign.destructive
        case .canceled, .unknown:
            APCDesign.textSecondary
        }
    }

    private var previewShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }
}

private struct MakerMessageTimeline: View {
    @EnvironmentObject private var store: AppStore
    let messages: [GenerationMessage]
    let hasMore: Bool
    let isLoading: Bool

    @State private var followsLatest = true
    @State private var hasUnseenMessages = false
    private let bottomID = "maker-message-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if hasMore {
                            Button {
                                Task { await store.loadOlderGenerationHistoryMessages() }
                            } label: {
                                if isLoading {
                                    ProgressView()
                                } else {
                                    Label(
                                        APCLocalization.text(.studioWorkspaceLoadOlder),
                                        systemImage: "arrow.up"
                                    )
                                }
                            }
                            .buttonStyle(.borderless)
                            .frame(maxWidth: .infinity)
                        }

                        ForEach(messages) { message in
                            MakerMessageRow(message: message)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                            .onAppear {
                                followsLatest = true
                                hasUnseenMessages = false
                            }
                            .onDisappear { followsLatest = false }
                    }
                    .padding(20)
                }
                .scrollIndicators(.visible)
                .accessibilityIdentifier("maker.session-timeline-scroll")

                if hasUnseenMessages {
                    Button {
                        withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
                        followsLatest = true
                        hasUnseenMessages = false
                    } label: {
                        Label(
                            APCLocalization.text(.studioWorkspaceNewMessages),
                            systemImage: "arrow.down"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
            }
            .onChange(of: messages.last?.id) { _, _ in
                if followsLatest {
                    withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
                } else {
                    hasUnseenMessages = true
                }
            }
            .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("maker.session-timeline")
    }
}

private struct MakerMessageRow: View {
    @EnvironmentObject private var store: AppStore
    let message: GenerationMessage

    var body: some View {
        if message.payload?.payloadType == .inputRequest {
            inputRequest
        } else if isActivity {
            Label(message.content, systemImage: activityIcon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else {
            HStack {
                if message.role == "user" { Spacer(minLength: 80) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(
                        APCLocalization.text(
                            message.role == "user"
                                ? .studioWorkspaceUserName
                                : .studioWorkspaceAgentName
                        )
                    )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(message.content)
                        .font(.body)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    message.role == "user"
                        ? Color.accentColor.opacity(0.16)
                        : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                if message.role != "user" { Spacer(minLength: 80) }
            }
        }
    }

    private var inputRequest: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                APCLocalization.text(.studioWorkspaceNeedsDecision),
                systemImage: "questionmark.bubble.fill"
            )
                .font(.headline)
                .foregroundStyle(.tint)
            ForEach(message.payload?.questions ?? []) { question in
                Text(question.prompt)
                    .textSelection(.enabled)
                if !question.options.isEmpty {
                    FlowLayout(spacing: 7) {
                        ForEach(question.options, id: \.label) { option in
                            Button(option.label) {
                                store.generationReplyText = option.label
                            }
                            .buttonStyle(.bordered)
                            .help(option.description ?? option.label)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.accentColor.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private var isActivity: Bool {
        guard let kind = message.kind else { return false }
        return kind.contains("activity")
            || kind.contains("checkpoint")
            || kind == "generation_progress"
            || kind == "generation_resumed"
    }

    private var activityIcon: String {
        if message.kind?.contains("validat") == true { return "checkmark.seal" }
        if message.kind?.contains("generating") == true { return "photo.stack" }
        if message.kind?.contains("checkpoint") == true { return "externaldrive.badge.checkmark" }
        return "gearshape.2"
    }
}

enum MakerSessionSummaryKind: Equatable {
    case pending
    case running
    case waitingForUser
    case completed
    case recoverableFailure
    case failed
    case canceled
    case cancellationPending
    case unknown
}

enum MakerSessionPolicy {
    static func summaryKind(
        status: GenerationJobHistoryStatus?,
        recoverable: Bool?,
        cancellationPending: Bool?
    ) -> MakerSessionSummaryKind {
        if cancellationPending == true {
            return .cancellationPending
        }
        return switch status {
        case .pending: .pending
        case .running: .running
        case .waitingForUser: .waitingForUser
        case .completed: .completed
        case .failed where recoverable == true: .recoverableFailure
        case .failed: .failed
        case .canceled: .canceled
        case nil: .unknown
        }
    }

    static func isUnfinished(_ job: GenerationStudioHistoryRecord) -> Bool {
        if job.cancellationPending == true { return true }
        if let capabilities = job.capabilities {
            return capabilities.canCancel || capabilities.canReply || capabilities.canResume
        }
        return job.status == .pending
            || job.status == .running
            || job.status == .waitingForUser
            || (job.status == .failed && job.recoverable == true)
    }

    static func statusTitle(_ job: GenerationStudioHistoryRecord) -> String {
        if job.cancellationPending == true {
            return APCLocalization.text(.studioWorkspaceStatusCancelCleanup)
        }
        if job.status == .failed, job.recoverable == true {
            return APCLocalization.text(.studioWorkspaceStatusRecoverable)
        }
        return PetStudioPresentation.historyStatusTitle(job.status)
    }

    static func statusTone(_ job: GenerationStudioHistoryRecord) -> StatusBadge.Tone {
        if job.cancellationPending == true || (job.status == .failed && job.recoverable == true) {
            return .warning
        }
        return PetStudioPresentation.historyStatusTone(job.status)
    }

    static func statusTitle(
        _ status: GenerationJobHistoryStatus,
        detail: GenerationStudioHistoryDetail
    ) -> String {
        if detail.cancellationPending == true {
            return APCLocalization.text(.studioWorkspaceStatusCancelCleanup)
        }
        if status == .failed, detail.recoverable == true {
            return APCLocalization.text(
                detail.failureCode == "owner_interrupted"
                    ? .studioWorkspaceStatusPaused
                    : .studioWorkspaceStatusFailedRecoverable
            )
        }
        return PetStudioPresentation.historyStatusTitle(status)
    }

    static func statusTone(
        _ status: GenerationJobHistoryStatus,
        detail: GenerationStudioHistoryDetail
    ) -> StatusBadge.Tone {
        if detail.cancellationPending == true || (status == .failed && detail.recoverable == true) {
            return .warning
        }
        return PetStudioPresentation.historyStatusTone(status)
    }
}

enum MakerSessionClock {
    static func duration(startedAt: String?, endedAt: String?, now: Date) -> String {
        guard let startedAt, let start = date(startedAt) else { return "—" }
        let end = endedAt.flatMap(date) ?? now
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(
            format: "%02d:%02d:%02d",
            seconds / 3_600,
            (seconds % 3_600) / 60,
            seconds % 60
        )
    }

    static func relative(_ value: String, now: Date) -> String {
        guard let date = date(value) else { return value }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: APCLocalization.interfaceLocaleIdentifier)
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
