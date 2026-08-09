import AgentPetCompanionCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AIPetMakerView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        MakerSessionWorkspace()
            .task {
                await store.refreshPetStudioCodexAvailability()
                await store.prepareMakerWorkspace()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("maker.page")
    }
}

struct MakerBriefView: View {
    @EnvironmentObject private var store: AppStore

    private var fieldsAreLocked: Bool {
        store.generationSession.isActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            codexAvailabilityNotice
            if !store.petStudioCodexAvailability.permitsGeneration {
                Divider()
            }
            descriptionField
            Divider()
            stylePicker
            Divider()
            qualityPicker
            Divider()
            referenceImages
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maker.brief")
    }

    @ViewBuilder
    private var codexAvailabilityNotice: some View {
        switch store.petStudioCodexAvailability {
        case .available:
            EmptyView()
        case .checking:
            InlineSessionNotice(
                title: APCLocalization.text(.studioCodexCheckingTitle),
                detail: APCLocalization.text(.studioCodexCheckingDetail),
                systemImage: "hourglass",
                color: .secondary
            )
            .accessibilityIdentifier("maker.codex.checking")
        case .missing:
            InlineSessionNotice(
                title: APCLocalization.text(.studioCodexMissingTitle),
                detail: APCLocalization.text(.studioCodexMissingDetail),
                systemImage: "exclamationmark.triangle.fill",
                color: APCDesign.warning
            )
            .accessibilityIdentifier("maker.codex.missing")
        case .unavailable:
            InlineSessionNotice(
                title: APCLocalization.text(.studioCodexUnavailableTitle),
                detail: APCLocalization.text(.studioCodexUnavailableDetail),
                systemImage: "exclamationmark.triangle.fill",
                color: APCDesign.warning
            )
            .accessibilityIdentifier("maker.codex.unavailable")
        }
    }

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(APCLocalization.text(.studioDescriptionHeading))
                .font(.headline)

            Text(APCLocalization.text(.studioDescriptionTemplatesTitle))
                .font(.caption)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 7) {
                ForEach(MakerBriefTemplate.allCases) { template in
                    Button {
                        append(template)
                    } label: {
                        Label(template.title, systemImage: template.systemImage)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(fieldsAreLocked)
                    .accessibilityIdentifier("maker.brief.template.\(template.rawValue)")
                }
            }
            .accessibilityIdentifier("maker.brief.templates")

            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(
                    get: { store.descriptionText },
                    set: { store.updateGenerationDescription($0) }
                ))
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 112)
                .disabled(fieldsAreLocked)
                .accessibilityLabel(APCLocalization.text(.studioDescriptionLabel))
                .accessibilityValue(descriptionCountAccessibilityValue)
                .accessibilityIdentifier("maker.brief.description")

                if store.descriptionText.isEmpty {
                    Text(APCLocalization.text(.studioDescriptionExample))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(APCDesign.stroke, lineWidth: 1)
                    .allowsHitTesting(false)
            }

            if MakerBriefPresentation.showsDescriptionCount(
                scalarCount: descriptionCount,
                maximum: AIPetMakerDefaults.maximumDescriptionCharacters
            ) {
                Text(MakerBriefPresentation.descriptionCount(
                    scalarCount: descriptionCount
                ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(APCLocalization.text(.studioStyleHeading))
                .font(.headline)
            FlowLayout(spacing: 8) {
                ForEach(StylePreset.allCases) { style in
                    PillButton(
                        title: APCLocalizedPresentation.styleTitle(style),
                        selected: style == store.selectedStyle,
                        semanticLabel: UIControlSemantics.styleLabel(style)
                    ) {
                        store.selectGenerationStyle(style)
                    }
                    .disabled(fieldsAreLocked)
                }
            }
            .accessibilityIdentifier("maker.brief.style")
        }
    }

    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(APCLocalization.text(.studioQualityHeading))
                .font(.headline)

            Picker(APCLocalization.text(.studioQualityHeading), selection: Binding(
                get: { store.selectedQuality },
                set: { store.selectGenerationQuality($0) }
            )) {
                ForEach(QualityLevel.studioCases) { quality in
                    Text(APCLocalizedPresentation.qualityTitle(quality)).tag(quality)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(fieldsAreLocked)
            .help(qualityGuidance)
            .accessibilityHint(qualityGuidance)
            .accessibilityIdentifier("maker.brief.quality")

            Text(qualityGuidance)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var qualityGuidance: String {
        MakerBriefPresentation.qualityGuidance(store.selectedQuality)
    }

    private var referenceImages: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(APCLocalization.text(.studioReferencesHeading))
                .font(.headline)
            ReferenceImageDropZone()
        }
    }

    private var descriptionCount: Int {
        GenerationPromptPolicy.scalarCount(store.descriptionText)
    }

    private var descriptionCountAccessibilityValue: String {
        APCLocalization.format(
            .commonValueOfTotalFormat,
            APCLocalization.text(.studioDescriptionLabel),
            descriptionCount,
            AIPetMakerDefaults.maximumDescriptionCharacters
        )
    }

    private func append(_ template: MakerBriefTemplate) {
        guard !fieldsAreLocked else { return }
        let existing = store.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = existing.isEmpty ? "" : "\n"
        store.updateGenerationDescription(existing + separator + template.insertionText)
    }
}

struct ReferenceImageDropZone: View {
    @EnvironmentObject private var store: AppStore
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                store.chooseReferenceImages()
            } label: {
                Label(title, systemImage: "photo.badge.plus")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isDropTargeted ? APCDesign.accent : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isDropTargeted ? APCDesign.accent : APCDesign.stroke,
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
                    .allowsHitTesting(false)
            }
            .disabled(store.generationSession.isActive)
            .help(referenceGuidance)
            .accessibilityHint(referenceGuidance)
            .onDrop(
                of: [UTType.fileURL.identifier],
                isTargeted: $isDropTargeted,
                perform: handleDrop(providers:)
            )
            .accessibilityIdentifier("maker.brief.references.dropzone")

            if !store.referenceImages.isEmpty {
                ReferenceImageStrip(paths: store.referenceImages)
                    .disabled(store.generationSession.isActive)
            }

            if let issue = store.referenceImageIssue {
                Label(
                    APCLocalizedPresentation.referenceImageIssue(issue),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(APCDesign.destructive)
                .accessibilityIdentifier("maker.brief.references.error")
            }

        }
    }

    private var referenceGuidance: String {
        [
            APCLocalization.text(.studioReferencesContract),
            APCLocalization.text(.studioReferencesPrivacy),
        ].joined(separator: "\n")
    }

    private var title: String {
        store.referenceImages.isEmpty
            ? APCLocalization.text(.studioReferencesDropEmpty)
            : APCLocalization.format(
                .studioReferencesDropCountFormat,
                store.referenceImages.count
            )
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !store.generationSession.isActive else { return false }
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = ReferenceImageDropItem.fileURL(from: item) else { return }
                Task { @MainActor in
                    store.addReferenceImageURLs([url])
                }
            }
        }
        return accepted
    }
}

struct ReferenceImageStrip: View {
    @EnvironmentObject private var store: AppStore
    var paths: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                    ReferenceImageChip(index: index + 1, path: path) {
                        store.removeReferenceImage(path)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct ReferenceImageChip: View {
    var index: Int
    var path: String
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(APCLocalization.format(.studioReferenceItemFormat, index))
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .leading)

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(APCLocalization.text(.studioReferencesRemove))
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(APCDesign.stroke, lineWidth: 1)
        }
    }
}

enum ReferenceImageDropItem {
    static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let nsURL = item as? NSURL { return nsURL as URL }
        if let data = item as? Data,
           let string = String(data: data, encoding: .utf8),
           let url = URL(string: string) {
            return url
        }
        if let string = item as? String { return URL(string: string) }
        return nil
    }
}

struct GenerationSessionView: View {
    @EnvironmentObject private var store: AppStore
    @FocusState private var replyIsFocused: Bool
    @State private var completedSessionIsExpanded = false
    @State private var cancelConfirmationPresented = false
    @State private var restartConfirmationPresented = false

    private var experience: MakerExperiencePresentation {
        let resultPet = MakerResultPresentation.resultPet(
            for: store.generationSession,
            in: store.pets
        )
        return MakerExperiencePresentation(
            session: store.generationSession,
            resultPetAvailable: resultPet != nil,
            resultPreviewAvailable: resultPet.map {
                store.petAssetWarningIndex[$0.id] == nil
            } ?? false,
            referenceReselectionCount: store.referenceReselectionCount
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sessionHeader

            if showsCompleteResult {
                PetMakerResultView()
                completedSessionDisclosure
            } else {
                GenerationProgressView()
                GenerationRuntimeStatusView()

                if store.generationSession.state.isTerminal
                    || store.generationSession.state == .cancelling
                {
                    terminalAction
                }

                evidenceWorkspace
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: store.generationSession.state) { _, newState in
            if newState == .waitingForInput {
                replyIsFocused = true
            }
        }
        .onAppear {
            guard PetStudioPresentation.shouldFocusComposer(
                onAppearFor: store.generationSession.state
            ) else { return }
            Task { @MainActor in
                replyIsFocused = true
            }
        }
        .confirmationDialog(
            APCLocalization.text(.studioCancelConfirmTitle),
            isPresented: $cancelConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(
                APCLocalization.text(.studioCancelConfirmAction),
                role: .destructive
            ) {
                store.cancelGeneration()
            }
            Button(APCLocalization.text(.commonCancel), role: .cancel) {}
        } message: {
            Text(APCLocalization.text(.studioCancelConfirmDetail))
        }
        .confirmationDialog(
            APCLocalization.text(.studioRestartConfirmTitle),
            isPresented: $restartConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(APCLocalization.text(.studioRestartConfirmAction)) {
                store.retryGeneration()
            }
            Button(APCLocalization.text(.commonCancel), role: .cancel) {}
        } message: {
            Text(APCLocalization.text(.studioRestartConfirmDetail))
        }
        .accessibilityIdentifier("maker.session")
    }

    private var showsCompleteResult: Bool {
        store.generationSession.state == .succeeded
            && !PetStudioPresentation.completedHistoryIsIncomplete(
                store.generationSession
            )
    }

    private var sessionHeader: some View {
        HStack(spacing: 10) {
            APCBrandMark(size: 24)
                .accessibilityHidden(true)
            Text(APCLocalization.text(
                store.generationSession.operation == .modify
                    ? .studioPageModifySession
                    : .studioSessionCreate
            ))
                .font(.title3.weight(.semibold))
            Spacer()
            StatusBadge(
                title: experience.resultReadiness.needsRecovery
                    ? APCLocalization.text(.studioPreviewRepairTitle)
                    : APCLocalizedPresentation.generationStateTitle(
                        store.generationSession.state,
                        operation: store.generationSession.operation
                    ),
                tone: experience.resultReadiness.needsRecovery
                    ? .warning
                    : PetStudioPresentation.statusTone(
                        for: store.generationSession.state
                    )
            )
            if experience.primaryAction == .cancel
                || experience.secondaryActions.contains(.cancel) {
                Button {
                    cancelConfirmationPresented = true
                } label: {
                    Label(
                        APCLocalization.text(
                            store.generationSession.state == .cancelling
                                ? .studioActionCancelling
                                : .studioActionCancelTask
                        ),
                        systemImage: "xmark.circle.fill"
                    )
                }
                .buttonStyle(.bordered)
                .tint(APCDesign.destructive)
                .disabled(!store.generationSession.canCancel)
                .accessibilityIdentifier("maker.action.cancel")
            }
        }
    }

    private var timelineSurface: some View {
        timeline
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(APCDesign.stroke, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    private var completedSessionDisclosure: some View {
        AdvancedDetailsDisclosure(
            identity: ProductComponentIdentity(
                scope: "maker",
                instance: "completed-session"
            ),
            title: APCLocalization.text(
                store.generationSession.operation == .modify
                    ? .studioPageModifySession
                    : .studioSessionCreate
            ),
            summary: APCLocalization.text(.studioSubmittedBrief),
            isExpanded: $completedSessionIsExpanded
        ) {
            VStack(alignment: .leading, spacing: 16) {
                timelineSurface
                conversationSurface
            }
        }
    }

    private var conversationSurface: some View {
        CodexGenerationConversationView(
            messages: store.generationSession.messages,
            messageRevision: store.generationSession.messageRevision,
            isActive: store.generationSession.isActive
        )
    }

    private var progressItems: [MakerHistoryProgressItem] {
        MakerHistoryProgressPresentation.items(
            PetStudioPresentation.progressMessages(store.generationSession.messages)
        )
    }

    private var evidenceWorkspace: some View {
        AdaptiveTwoColumnLayout(minimumColumnWidth: 360, spacing: 16) {
            timelineSurface
            VStack(alignment: .leading, spacing: 12) {
                if !store.generationSession.state.isTerminal {
                    replyComposer
                }
                conversationSurface
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("maker.session.evidence-workspace")
    }

    private var timeline: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let form = store.generationSession.submittedForm {
                    SubmittedFormSummary(form: form)
                    Divider()
                }

                ForEach(progressItems) { item in
                    GenerationTimelineRow(item: item)
                }

                if progressItems.isEmpty {
                    ProgressView(APCLocalization.text(.studioPreparing))
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .padding(16)
        }
        .scrollIndicators(.visible)
    }

    @ViewBuilder
    private var terminalAction: some View {
        switch store.generationSession.state {
        case .failed:
            failureRecovery(
                status: ProductStatusPresentation(
                    appearance: .error,
                    title: APCLocalization.text(.studioFailedTitle),
                    detail: failureNoticeDetail
                )
            )
        case .cancelled:
            failureRecovery(
                status: ProductStatusPresentation(
                    appearance: .normal,
                    title: APCLocalization.text(.studioCancelledTitle),
                    detail: APCLocalization.text(.studioCancelledDetail)
                )
            )
        case .succeeded:
            if PetStudioPresentation.completedHistoryIsIncomplete(
                store.generationSession
            ) {
                InlineSessionNotice(
                    title: APCLocalization.text(.studioIncompleteHistoryTitle),
                    detail: APCLocalization.text(.studioIncompleteHistoryDetail),
                    systemImage: "exclamationmark.triangle.fill",
                    color: APCDesign.warning
                )
            }
        case .cancelling:
            InlineSessionNotice(
                title: APCLocalization.text(.studioActionCancelling),
                detail: APCLocalization.text(.studioCancellingDetail),
                systemImage: "hourglass",
                color: .secondary
            )
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func failureRecovery(
        status: ProductStatusPresentation
    ) -> some View {
        let resolvedRecoveryAction = recoveryAction
        VStack(alignment: .leading, spacing: 8) {
            InlineRecoveryBanner(
                identity: ProductComponentIdentity(
                    scope: "maker",
                    instance: "session-recovery"
                ),
                status: status,
                primaryAction: resolvedRecoveryAction.map { action in
                    ProductActionPresentation(
                        action: action,
                        title: recoveryActionTitle(action),
                        systemImage: recoveryActionSystemImage(action),
                        isEnabled: recoveryActionIsEnabled(action)
                    )
                },
                onPrimaryAction: performRecoveryAction
            )

            if store.generationSession.canRetry {
                Button {
                    restartConfirmationPresented = true
                } label: {
                    Label(
                        APCLocalization.text(.studioActionRestart),
                        systemImage: "plus.rectangle.on.rectangle"
                    )
                }
                .buttonStyle(.borderless)
                .disabled(!store.canRetryGeneration)
                .help(APCLocalization.text(.studioRestartConfirmDetail))
                .accessibilityIdentifier("maker.action.restart")
            }
        }
    }

    private func recoveryActionTitle(
        _ action: PetMakerPrimaryAction
    ) -> String {
        if action == .retry {
            return APCLocalization.text(.studioActionResume)
        }
        return APCLocalizedPresentation.primaryActionTitle(action)
            ?? APCLocalization.text(.commonRetry)
    }

    private func recoveryActionSystemImage(
        _ action: PetMakerPrimaryAction
    ) -> String {
        switch action {
        case .retry: "arrow.clockwise"
        case .reselectReferences: "photo.badge.plus"
        default: "arrow.clockwise"
        }
    }

    private func recoveryActionIsEnabled(
        _ action: PetMakerPrimaryAction
    ) -> Bool {
        switch action {
        case .retry: store.canResumeGeneration
        case .reselectReferences: true
        default: false
        }
    }

    private func performRecoveryAction(
        _ action: PetMakerPrimaryAction
    ) {
        switch action {
        case .retry:
            store.resumeGeneration()
        case .reselectReferences:
            store.chooseReferenceImages()
        default:
            break
        }
    }

    private var recoveryAction: PetMakerPrimaryAction? {
        if store.generationSession.state == .cancelled {
            return nil
        }
        return switch experience.primaryAction {
        case .retry, .reselectReferences:
            experience.primaryAction
        default:
            nil
        }
    }

    private var failureNoticeDetail: String {
        let failure = PetStudioPresentation.failureDetail(
            for: store.generationSession.messages
        )
        guard store.referenceReselectionCount > 0 else { return failure }
        let recovery = APCLocalizedPresentation.referenceImageIssue(
            .reselectionRequired(store.referenceReselectionCount)
        )
        return "\(failure)\n\(recovery)"
    }

    private var replyComposer: some View {
        HStack(spacing: 8) {
            TextField(replyPlaceholder, text: $store.generationReplyText)
                .textFieldStyle(.roundedBorder)
                .focused($replyIsFocused)
                .onSubmit { store.sendGenerationReply() }
                .disabled(!store.canSendGenerationReply)
                .accessibilityIdentifier("maker.session.reply")

            Button {
                store.sendGenerationReply()
            } label: {
                Image(systemName: "arrow.up")
            }
            .apcClearGlassButtonStyle(prominent: true)
            .disabled(!canSendReply)
            .accessibilityLabel(APCLocalization.text(.studioReplySend))
            .accessibilityIdentifier("maker.session.send")
        }
    }

    private var canSendReply: Bool {
        store.canSendGenerationReply
            && !store.generationReplyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var replyPlaceholder: String {
        switch store.generationSession.state {
        case .waitingForInput: APCLocalization.text(.studioReplyWaiting)
        case .succeeded: APCLocalization.text(.studioReplySucceeded)
        case .starting, .running: APCLocalization.text(.studioReplyRunning)
        case .cancelling: APCLocalization.text(.studioReplyCancelling)
        case .failed: APCLocalization.text(.studioReplyFailed)
        case .paused, .recoverableFailed: APCLocalization.text(.studioReplyFailed)
        case .cancelled: APCLocalization.text(.studioReplyCancelled)
        case .cancelCleanup: APCLocalization.text(.studioReplyCancelling)
        case .idle: APCLocalization.text(.studioReplyIdle)
        }
    }

}

struct GenerationProgressView: View {
    @EnvironmentObject private var store: AppStore

    private var steps: [String] {
        store.generationSession.operation == .modify
            ? [
                APCLocalization.text(.studioStepBaseline),
                APCLocalization.text(.studioStepBrief),
                APCLocalization.text(.studioStepRevision),
                APCLocalization.text(.studioStepValidation)
            ]
            : [
                APCLocalization.text(.studioStepBrief),
                APCLocalization.text(.studioStepGeneration),
                APCLocalization.text(.studioStepValidation),
                APCLocalization.text(.studioStepLibrary)
            ]
    }

    private var activeIndex: Int {
        GenerationConversation.activeStepIndex(
            messages: store.generationSession.messages,
            progress: store.generationSession.progress,
            operation: store.generationSession.operation
        )
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                stepViews(horizontal: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                stepViews(horizontal: false)
            }
        }
        .accessibilityIdentifier("maker.session.progress")
    }

    @ViewBuilder
    private func stepViews(horizontal: Bool) -> some View {
        ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
            let state = PetStudioPresentation.stageState(
                at: index,
                activeIndex: activeIndex,
                sessionState: store.generationSession.state,
                hasRecordedRuntimePhase: GenerationConversation.runtimePhase(
                    store.generationSession.messages
                ) != nil
            )
            HStack(spacing: 6) {
                Image(systemName: state.systemImage)
                    .foregroundStyle(state.color)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption.weight(state == .current ? .semibold : .regular))
                    .foregroundStyle(state == .upcoming ? .secondary : .primary)
            }
            .accessibilityLabel(APCLocalization.format(
                .connectionsMetadataFormat,
                title,
                state.accessibilityTitle
            ))

            if horizontal, index < steps.count - 1 {
                Divider()
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct GenerationRuntimeStatusView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(
                        APCLocalization.text(.studioRuntimeCurrentAction),
                        systemImage: "waveform.path.ecg"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    Text(currentActivity)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        runtimeFacts(at: context.date)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        runtimeFacts(at: context.date)
                    }
                }
                .font(.caption)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(APCDesign.stroke, lineWidth: 1)
            }
        }
        .accessibilityIdentifier("maker.session.runtime-status")
    }

    @ViewBuilder
    private func runtimeFacts(at now: Date) -> some View {
        Label(
            APCLocalization.format(
                .studioRuntimeCheckpointFormat,
                GenerationConversation.checkpointCount(store.generationSession.messages)
            ),
            systemImage: "arrow.clockwise"
        )
        .foregroundStyle(.secondary)

        Label(
            APCLocalization.format(.studioRuntimeElapsedFormat, elapsedText(at: now)),
            systemImage: "clock"
        )
        .foregroundStyle(.secondary)

        let heartbeat = heartbeatPresentation(at: now)
        Label(heartbeat.title, systemImage: heartbeat.systemImage)
            .foregroundStyle(heartbeat.color)
    }

    private var currentActivity: String {
        GenerationConversation.currentActivity(store.generationSession.messages)?.content
            ?? APCLocalization.text(.studioPreparing)
    }

    private func elapsedText(at now: Date) -> String {
        guard let value = GenerationConversation.startedMessage(
            store.generationSession.messages
        )?.createdAt,
        let startedAt = PetStudioTimestamp.date(value)
        else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }

    private func heartbeatPresentation(
        at now: Date
    ) -> (title: String, systemImage: String, color: Color) {
        let value = store.generationSession.heartbeatAt
            ?? GenerationConversation.heartbeatMessage(
                store.generationSession.messages
            )?.createdAt
        guard let value,
        let heartbeatAt = PetStudioTimestamp.date(value)
        else {
            return (
                APCLocalization.text(.studioRuntimeHeartbeatPending),
                "heart",
                .secondary
            )
        }
        let age = max(0, now.timeIntervalSince(heartbeatAt))
        let relative = PetStudioTimestamp.relative(heartbeatAt, to: now)
        if !store.generationSession.isActive {
            return (
                APCLocalization.format(.studioRuntimeLastUpdateFormat, relative),
                "clock.badge.checkmark",
                .secondary
            )
        }
        if age <= 75 {
            return (
                APCLocalization.format(.studioRuntimeHeartbeatHealthyFormat, relative),
                "heart.fill",
                APCDesign.success
            )
        }
        if age <= 150 {
            return (
                APCLocalization.format(.studioRuntimeHeartbeatWaitingFormat, relative),
                "hourglass",
                APCDesign.warning
            )
        }
        return (
            APCLocalization.format(.studioRuntimeHeartbeatStaleFormat, relative),
            "exclamationmark.triangle.fill",
            APCDesign.destructive
        )
    }
}

private enum PetStudioTimestamp {
    static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    static func relative(_ date: Date, to now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: APCLocalization.interfaceLocaleIdentifier)
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

struct SubmittedFormSummary: View {
    var form: GenerationForm?

    var body: some View {
        if let form {
            let presentation = MakerSubmittedBriefPresentation(form: form)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(APCLocalization.text(.studioSubmittedBrief))
                        .font(.headline)
                    Spacer()
                    Label(
                        APCLocalization.text(.studioSubmitted),
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Text(presentation.descriptionSummary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(APCLocalization.format(
                        .connectionsMetadataFormat,
                        APCLocalization.text(.studioFieldDescription),
                        presentation.descriptionSummary
                    ))

                LabeledContent(
                    APCLocalization.text(.studioFieldStyle),
                    value: presentation.styleTitle
                )
                LabeledContent(
                    APCLocalization.text(.studioFieldQuality),
                    value: presentation.qualityTitle
                )
                LabeledContent(
                    APCLocalization.text(.studioFieldReferences),
                    value: APCLocalization.format(
                        .commonImagesFormat,
                        presentation.referenceCount
                    )
                )
            }
            .font(.caption)
            .accessibilityIdentifier("maker.session.submitted-brief")
        } else {
            Label(APCLocalization.text(.studioSubmittedPending), systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct GenerationTimelineRow: View {
    var item: MakerHistoryProgressItem

    var body: some View {
        Label(item.content, systemImage: "gearshape.2")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}

private struct CodexGenerationConversationView: View {
    let messages: [GenerationMessage]
    let messageRevision: String
    let isActive: Bool

    @State private var scrollPosition: String?
    @State private var followsLatest = true

    private let bottomID = "codex-conversation-bottom"

    private var entries: [CodexGenerationConversationEntry] {
        PetStudioPresentation.codexConversationEntries(messages)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(
                    APCLocalization.text(.studioCodexConversationTitle),
                    systemImage: "text.bubble"
                )
                .font(.headline)
                Spacer()
                if !followsLatest, !entries.isEmpty {
                    Button {
                        followsLatest = true
                        scrollPosition = bottomID
                    } label: {
                        Label(
                            APCLocalization.text(.studioCodexConversationLatest),
                            systemImage: "arrow.down"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(APCLocalization.text(.studioCodexConversationLatest))
                    .accessibilityIdentifier("maker.session.codex.latest")
                }
            }

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(entries) { entry in
                        CodexGenerationConversationRow(entry: entry)
                            .id(entry.id)
                    }

                    if entries.isEmpty {
                        if isActive {
                            ProgressView(APCLocalization.text(.studioCodexConversationWaiting))
                        } else {
                            ContentUnavailableView(
                                APCLocalization.text(.studioCodexConversationEmpty),
                                systemImage: "text.bubble"
                            )
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .scrollTargetLayout()
                .padding(16)
            }
            .scrollPosition(id: $scrollPosition, anchor: .bottom)
            .scrollIndicators(.visible)
            .frame(minHeight: 260, idealHeight: 320, maxHeight: 420)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(APCDesign.stroke, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onAppear {
                scrollPosition = bottomID
            }
            .onChange(of: messageRevision) { _, _ in
                guard followsLatest else { return }
                scrollPosition = bottomID
            }
            .onChange(of: scrollPosition) { _, newValue in
                guard let newValue else { return }
                followsLatest = newValue == bottomID
            }
        }
        .accessibilityIdentifier("maker.session.codex.conversation")
    }
}

private struct CodexGenerationConversationRow: View {
    let entry: CodexGenerationConversationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.role == .user
                ? APCLocalization.text(.studioMessageYou)
                : APCLocalization.text(.studioCodexConversationAgent))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(entry.content)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(entry.role == .user
                    ? APCDesign.accentSoft
                    : Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    entry.role == .user ? APCDesign.accent.opacity(0.35) : APCDesign.stroke,
                    lineWidth: 1
                )
        }
    }
}

struct CodexGenerationConversationEntry: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case codex
    }

    let id: String
    let role: Role
    var content: String
    fileprivate let streamsCodexMessage: Bool
}

struct ValidatedBaselineInspector: View {
    @EnvironmentObject private var store: AppStore
    @State private var baselineRevision: PetRevisionHistoryRecord?
    @State private var baselineLoadState = BaselineLoadState.idle

    private var pet: PetSummary? {
        guard let petID = store.generationSession.resultPetID else { return nil }
        return store.pets.first(where: { $0.id == petID })
    }

    private var requestedRevisionID: String? {
        store.generationSession.baselineRevisionID
    }

    private var lookupIdentity: String {
        [
            store.generationSession.resultPetID ?? "missing-pet",
            requestedRevisionID ?? "unversioned-submitted-baseline",
            pet?.petpackPath ?? "pet-not-loaded",
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(APCLocalization.text(.studioBaselineTitle))
                    .font(.headline)
                Spacer()
                baselineStatusBadge
            }

            baselineContent

            Label(
                APCLocalization.text(.studioBaselineSafety),
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("maker.baseline.inspector")
        .task(id: lookupIdentity) {
            await loadSubmittedRevision()
        }
    }

    @ViewBuilder
    private var baselineStatusBadge: some View {
        if baselineRevision != nil {
            StatusBadge(title: APCLocalization.text(.studioBaselineVerified), tone: .good)
        } else if baselineLoadState == .loading || baselineLoadState == .idle {
            if requestedRevisionID == nil {
                StatusBadge(
                    title: APCLocalization.text(.studioBaselineUnavailableTitle),
                    tone: .warning
                )
            } else {
                StatusBadge(title: APCLocalization.text(.studioBaselineRestoring), tone: .neutral)
            }
        } else {
            StatusBadge(title: APCLocalization.text(.studioBaselineUnavailableTitle), tone: .warning)
        }
    }

    @ViewBuilder
    private var baselineContent: some View {
        if let requestedRevisionID {
            if let baselineRevision {
                SubmittedRevisionCoverImage(revision: baselineRevision)
                    .frame(maxWidth: .infinity, minHeight: 190, maxHeight: 240)
                    .background(baselinePreviewBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                baselineDetails(revisionID: baselineRevision.revisionID)
            } else if baselineLoadState == .loading || baselineLoadState == .idle {
                ContentUnavailableView(
                    APCLocalization.text(.studioBaselineRestoring),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(APCLocalization.text(.studioBaselineRestoringDetail))
                )
            } else {
                MissingPetCoverPlaceholder(scale: 0.38)
                    .frame(maxWidth: .infinity, minHeight: 190, maxHeight: 240)
                    .background(baselinePreviewBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(APCLocalization.text(.studioBaselineUnavailableDetail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                baselineDetails(revisionID: requestedRevisionID)
            }
        } else if pet != nil {
            MissingPetCoverPlaceholder(scale: 0.38)
                .frame(maxWidth: .infinity, minHeight: 190, maxHeight: 240)
                .background(baselinePreviewBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(APCLocalization.text(.studioBaselineUnavailableDetail))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            unversionedBaselineDetails
        } else {
            ContentUnavailableView(
                APCLocalization.text(.studioBaselineRestoring),
                systemImage: "clock.arrow.circlepath",
                description: Text(APCLocalization.text(.studioBaselineRestoringDetail))
            )
        }
    }

    @ViewBuilder
    private var unversionedBaselineDetails: some View {
        if let petID = store.generationSession.resultPetID {
            LabeledContent(APCLocalization.text(.studioBaselinePetID), value: petID)
        }
    }

    @ViewBuilder
    private func baselineDetails(revisionID: String?) -> some View {
        if let pet {
            Text(pet.name)
                .font(.title3.weight(.semibold))
            LabeledContent(APCLocalization.text(.studioBaselinePetID), value: pet.id)
        } else if let petID = store.generationSession.resultPetID {
            LabeledContent(APCLocalization.text(.studioBaselinePetID), value: petID)
        }
        if let revisionID {
            LabeledContent(APCLocalization.text(.libraryFieldRevisionID), value: revisionID)
                .textSelection(.enabled)
        }
        if let pet {
            LabeledContent(APCLocalization.text(.studioBaselineTargetState), value: targetState)
            LabeledContent(
                APCLocalization.text(.studioBaselineQuality),
                value: "\(pet.renderSize.width)×\(pet.renderSize.height)"
            )
            LabeledContent(
                APCLocalization.text(.studioBaselineAnimation),
                value: PetStudioPresentation.timingSummary(pet.states)
            )
        }
    }

    private var baselinePreviewBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
    }

    @MainActor
    private func loadSubmittedRevision() async {
        baselineRevision = nil
        guard let requestedRevisionID else {
            baselineLoadState = .idle
            return
        }
        guard let pet else {
            baselineLoadState = .loading
            return
        }
        baselineLoadState = .loading
        do {
            let history = try await store.fetchPetHistory(for: pet, limit: 32)
            guard !Task.isCancelled else { return }
            baselineRevision = PetStudioPresentation.validatedBaselineRevision(
                in: history,
                revisionID: requestedRevisionID
            )
            baselineLoadState = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            baselineLoadState = .failed
        }
    }

    private var targetState: String {
        PetStudioPresentation.baselineTargetState()
    }

    private enum BaselineLoadState {
        case idle
        case loading
        case loaded
        case failed
    }
}

private struct SubmittedRevisionCoverImage: View {
    let revision: PetRevisionHistoryRecord

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(12)
        } else {
            // An explicit historical baseline never borrows the current
            // head's cover when its own preview is unavailable.
            MissingPetCoverPlaceholder(scale: 0.38)
        }
    }

    private var image: NSImage? {
        guard let coverPath = revision.coverPath else { return nil }
        return NSImage(contentsOfFile: coverPath)
    }
}

private struct InlineSessionNotice: View {
    var title: String
    var detail: String
    var systemImage: String
    var color: Color

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum PetStudioPresentation {
    enum StageState: Equatable {
        case complete
        case current
        case upcoming
        case failed
        case cancelled
        case unrecorded

        var systemImage: String {
            switch self {
            case .complete: "checkmark.circle.fill"
            case .current: "circle.fill"
            case .upcoming: "circle"
            case .failed: "exclamationmark.circle.fill"
            case .cancelled: "xmark.circle.fill"
            case .unrecorded: "questionmark.circle"
            }
        }

        var color: Color {
            switch self {
            case .complete: APCDesign.success
            case .current: APCDesign.accent
            case .upcoming: .secondary
            case .failed: APCDesign.destructive
            case .cancelled: .secondary
            case .unrecorded: .secondary
            }
        }

        var accessibilityTitle: String {
            switch self {
            case .complete: APCLocalization.text(.studioStageComplete)
            case .current: APCLocalization.text(.studioStageCurrent)
            case .upcoming: APCLocalization.text(.studioStageUpcoming)
            case .failed: APCLocalization.text(.studioStageFailed)
            case .cancelled: APCLocalization.text(.studioCancelledTitle)
            case .unrecorded: APCLocalization.text(.studioStageUnrecorded)
            }
        }
    }

    static func showsModificationWorkspace(for session: GenerationSession) -> Bool {
        session.operation == .modify && session.state != .idle
    }

    static func historyOperationTitle(_ operation: GenerationOperation) -> String {
        APCLocalization.text(
            operation == .modify
                ? .libraryHistoryOperationModify
                : .libraryHistoryOperationCreate
        )
    }

    static func historyStatusTitle(_ status: GenerationJobHistoryStatus) -> String {
        let key: APCLocalizationKey = switch status {
        case .pending: .libraryHistoryStatusPending
        case .running: .libraryHistoryStatusRunning
        case .waitingForUser: .libraryHistoryStatusWaiting
        case .completed: .libraryHistoryStatusCompleted
        case .failed: .libraryHistoryStatusFailed
        case .canceled: .libraryHistoryStatusCancelled
        }
        return APCLocalization.text(key)
    }

    static func historyStatusTone(_ status: GenerationJobHistoryStatus) -> StatusBadge.Tone {
        switch status {
        case .completed: .good
        case .failed: .destructive
        case .pending, .running, .waitingForUser: .accent
        case .canceled: .neutral
        }
    }

    static func historyStyleTitle(_ style: String?) -> String {
        guard let style = style?.trimmingCharacters(in: .whitespacesAndNewlines),
              !style.isEmpty
        else { return "—" }
        return StylePreset(rawValue: style).map {
            APCLocalizedPresentation.styleTitle($0)
        } ?? style
    }

    static func historySessionDetail(
        _ availability: GenerationStudioSessionAvailability
    ) -> String {
        let key: APCLocalizationKey = switch availability {
        case .available: .studioHistorySessionAvailable
        case .archived: .studioHistorySessionArchived
        case .missing: .studioHistorySessionMissing
        case .unavailable: .studioHistorySessionUnavailable
        case .notCreated: .studioHistorySessionNotCreated
        }
        return APCLocalization.text(key)
    }

    static func historySessionSystemImage(
        _ session: GenerationStudioSessionNavigation
    ) -> String {
        switch session.availability {
        case .available: "arrow.up.forward.app"
        case .archived: "archivebox"
        case .missing: "questionmark.folder"
        case .unavailable: "exclamationmark.triangle"
        case .notCreated: "bubble.left.and.exclamationmark.bubble.right"
        }
    }

    static func timingSummary(
        _ states: [PetStateTiming],
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalization.format(
            .studioAuthoredTimingSummaryFormat,
            locale: localeIdentifier,
            states.reduce(0) { $0 + $1.frameDurationsMS.count },
            states.count
        )
    }

    static func completedHistoryIsIncomplete(_ session: GenerationSession) -> Bool {
        session.state == .succeeded
            && (session.resultPetID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                != false)
    }

    static func validatedBaselineRevision(
        in history: PetHistorySnapshot,
        revisionID: String
    ) -> PetRevisionHistoryRecord? {
        history.revisions.first {
            $0.revisionID == revisionID && $0.validated
        }
    }

    static func timelineMessages(_ messages: [GenerationMessage]) -> [GenerationMessage] {
        let structuralTerminalKinds: Set<String> = [
            "generation_failed",
            "generation_canceled",
            "generation_completed",
        ]
        return messages.filter { message in
            guard let kind = message.kind else { return true }
            return !structuralTerminalKinds.contains(kind)
        }
    }

    static func progressMessages(_ messages: [GenerationMessage]) -> [GenerationMessage] {
        messages.filter(isProgressMessage)
    }

    static func codexConversationEntries(
        _ messages: [GenerationMessage]
    ) -> [CodexGenerationConversationEntry] {
        var entries: [CodexGenerationConversationEntry] = []
        for message in messages {
            if message.role == "user", message.kind == nil {
                entries.append(CodexGenerationConversationEntry(
                    id: message.id,
                    role: .user,
                    content: message.content,
                    streamsCodexMessage: false
                ))
                continue
            }

            let streamsCodexMessage = message.role == "assistant"
                && message.kind == "codex_message"
            let isInputRequest = message.role == "assistant"
                && message.kind == "input_request"
            guard streamsCodexMessage || isInputRequest else { continue }

            if streamsCodexMessage,
               let lastIndex = entries.indices.last,
               entries[lastIndex].streamsCodexMessage {
                entries[lastIndex].content += message.content
            } else {
                entries.append(CodexGenerationConversationEntry(
                    id: message.id,
                    role: .codex,
                    content: message.content,
                    streamsCodexMessage: streamsCodexMessage
                ))
            }
        }
        return entries
    }

    static func isProgressMessage(_ message: GenerationMessage) -> Bool {
        guard let kind = message.kind else { return false }
        return kind == "generation_progress"
            || kind == "generation_started"
            || kind == "generation_resumed"
            || kind == "generation_checkpoint"
            || kind.hasPrefix("generation_activity_")
    }

    static func failureDetail(
        for messages: [GenerationMessage],
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        maximumSummaryScalars: Int = 240,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let recovery = APCLocalization.text(
            .studioFailedDetail,
            locale: localeIdentifier
        )
        guard maximumSummaryScalars > 0,
              let failure = messages.last(where: { $0.kind == "generation_failed" })
        else { return recovery }

        if failure.content.contains("bounded checkpoint turns")
            || failure.content.contains("固定续接次数上限")
        {
            return APCLocalization.text(
                .studioLegacyCheckpointFailure,
                locale: localeIdentifier
            )
        }

        let sanitized = AppDiagnosticRedactor.sanitizeLegacyLog(
            failure.content,
            homeURL: homeURL
        )
        let normalized = sanitized
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return recovery }

        let scalars = normalized.unicodeScalars
        let summary: String
        if scalars.count > maximumSummaryScalars {
            summary = String(String.UnicodeScalarView(scalars.prefix(maximumSummaryScalars))) + "…"
        } else {
            summary = normalized
        }
        return "\(summary)\n\(recovery)"
    }

    static func baselineTargetState(
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalization.text(.studioBaselineKeepContract, locale: localeIdentifier)
    }

    static func statusTone(for state: GenerationSessionState) -> StatusBadge.Tone {
        switch state {
        case .succeeded: .good
        case .failed: .destructive
        case .paused, .recoverableFailed: .warning
        case .starting, .running, .waitingForInput, .cancelling, .cancelCleanup: .accent
        case .idle, .cancelled: .neutral
        }
    }

    static func shouldFocusComposer(onAppearFor state: GenerationSessionState) -> Bool {
        state == .waitingForInput
    }

    static func stageState(
        at index: Int,
        activeIndex: Int,
        sessionState: GenerationSessionState,
        hasRecordedRuntimePhase: Bool = true
    ) -> StageState {
        if !hasRecordedRuntimePhase,
           sessionState == .failed || sessionState == .cancelled {
            return .unrecorded
        }
        if sessionState == .failed, index == activeIndex { return .failed }
        if sessionState == .cancelled, index == activeIndex { return .cancelled }
        if sessionState == .succeeded || index < activeIndex { return .complete }
        if index == activeIndex, sessionState != .idle { return .current }
        return .upcoming
    }
}

struct FlowLayout<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        WrappingFlowLayout(spacing: spacing) { content }
    }
}

private struct WrappingFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let rows = rows(for: subviews, maxWidth: resolvedMaxWidth(from: proposal))
        return CGSize(
            width: rows.map(\.width).max() ?? 0,
            height: rows.reduce(CGFloat.zero) { $0 + $1.height }
                + spacing * CGFloat(max(0, rows.count - 1))
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let rows = rows(for: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [FlowRow] {
        var rows: [FlowRow] = []
        var current = FlowRow()
        let width = maxWidth.isFinite && maxWidth > 0 ? maxWidth : .greatestFiniteMagnitude
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let nextWidth = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty, nextWidth > width {
                rows.append(current)
                current = FlowRow()
            }
            current.append(FlowItem(index: index, size: size), spacing: spacing)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }

    private func resolvedMaxWidth(from proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width, width.isFinite, width > 0 else {
            return .greatestFiniteMagnitude
        }
        return width
    }

    private struct FlowItem {
        var index: Subviews.Index
        var size: CGSize
    }

    private struct FlowRow {
        var items: [FlowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func append(_ item: FlowItem, spacing: CGFloat) {
            if !items.isEmpty { width += spacing }
            items.append(item)
            width += item.size.width
            height = max(height, item.size.height)
        }
    }
}
