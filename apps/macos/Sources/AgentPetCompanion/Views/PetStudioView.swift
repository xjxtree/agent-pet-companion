import AgentPetCompanionCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AIPetMakerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.controlCenterShellMode) private var shellMode

    var body: some View {
        PageScroll {
            if PetStudioPresentation.showsModificationWorkspace(for: store.generationSession) {
                modificationWorkspace
            } else {
                creationWorkspace
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                toolbarActions
            }
        }
        .accessibilityIdentifier("maker.page")
    }

    @ViewBuilder
    private var creationWorkspace: some View {
        if shellMode == .allColumns {
            HStack(alignment: .top, spacing: 0) {
                MakerBriefView()
                    .frame(minWidth: 300, idealWidth: 320, maxWidth: 340)
                    .padding(.trailing, 20)
                Divider()
                GenerationSessionView()
                    .frame(minWidth: 380, maxWidth: .infinity)
                    .padding(.leading, 20)
            }
            .accessibilityIdentifier("maker.layout.two-stage")
        } else {
            VStack(alignment: .leading, spacing: 20) {
                MakerBriefView()
                Divider()
                GenerationSessionView()
            }
            .accessibilityIdentifier("maker.layout.stacked")
        }
    }

    @ViewBuilder
    private var modificationWorkspace: some View {
        if shellMode == .allColumns {
            HStack(alignment: .top, spacing: 0) {
                GenerationSessionView()
                    .frame(minWidth: 420, maxWidth: .infinity)
                    .padding(.trailing, 20)
                Divider()
                ValidatedBaselineInspector()
                    .frame(width: 284)
                    .padding(.leading, 20)
            }
            .accessibilityIdentifier("maker.layout.modification-wide")
        } else {
            VStack(alignment: .leading, spacing: 20) {
                ValidatedBaselineInspector()
                Divider()
                GenerationSessionView()
            }
            .accessibilityIdentifier("maker.layout.modification-stacked")
        }
    }

    @ViewBuilder
    private var toolbarActions: some View {
        if store.generationSession.isActive {
            Button {
                store.cancelGeneration()
            } label: {
                Label(
                    APCLocalization.text(
                        store.generationSession.state == .cancelling
                            ? .studioActionCancelling
                            : .studioActionCancelTask
                    ),
                    systemImage: "xmark.circle"
                )
                .labelStyle(.iconOnly)
            }
            .help(APCLocalization.text(
                store.generationSession.state == .cancelling
                    ? .studioActionCancelling
                    : .studioActionCancelTask
            ))
            .disabled(!store.generationSession.canCancel)
            .accessibilityIdentifier("maker.action.cancel")
        } else if let recoveryAction = PetStudioPresentation.failureRecoveryAction(
            sessionCanRetry: store.generationSession.canRetry,
            referenceReselectionCount: store.referenceReselectionCount
        ) {
            switch recoveryAction {
            case .retry:
                Button {
                    store.retryGeneration()
                } label: {
                    Label(APCLocalization.text(.commonRetry), systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .help(APCLocalization.text(.commonRetry))
                .disabled(!store.canRetryGeneration)
                .accessibilityIdentifier("maker.action.retry")
            case .reselectReferences:
                Button {
                    store.chooseReferenceImages()
                } label: {
                    Label(
                        APCLocalization.text(.studioReferencesPanelTitle),
                        systemImage: "photo.badge.plus"
                    )
                    .labelStyle(.iconOnly)
                }
                .help(APCLocalization.text(.studioReferencesPanelTitle))
                .accessibilityIdentifier("maker.action.reselect-references")
            }
        } else if store.generationSession.state == .idle {
            Button {
                store.clearStudioForm()
            } label: {
                Label(APCLocalization.text(.commonClear), systemImage: "eraser")
                    .labelStyle(.iconOnly)
            }
            .help(APCLocalization.text(.commonClear))
            .disabled(store.descriptionText.isEmpty && store.referenceImages.isEmpty)
            .accessibilityIdentifier("maker.action.clear")

            Button {
                store.startGeneration()
            } label: {
                Label(APCLocalization.text(.studioActionStart), systemImage: "sparkles")
                    .labelStyle(.iconOnly)
            }
            .help(APCLocalization.text(.studioActionStart))
            .disabled(!store.canStartGeneration)
            .accessibilityIdentifier("maker.action.start")
        } else {
            Button {
                store.showNewPetDraft()
            } label: {
                Label(APCLocalization.text(.studioActionNew), systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .help(APCLocalization.text(.studioActionNew))
            .accessibilityIdentifier("maker.action.new")
        }
    }
}

struct MakerBriefView: View {
    @EnvironmentObject private var store: AppStore

    private var fieldsAreLocked: Bool {
        store.generationSession.isActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(APCLocalization.text(.studioNewPet))
                    .font(.title3.weight(.semibold))
                Spacer()
                if fieldsAreLocked {
                    Label(APCLocalization.text(.studioSubmitted), systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        .accessibilityIdentifier("maker.brief")
    }

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(APCLocalization.text(.studioDescriptionHeading))
                .font(.headline)

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

            Text("\(GenerationPromptPolicy.scalarCount(store.descriptionText))/\(AIPetMakerDefaults.maximumDescriptionCharacters)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel(APCLocalization.format(
                    .commonValueOfTotalFormat,
                    APCLocalization.text(.studioDescriptionLabel),
                    GenerationPromptPolicy.scalarCount(store.descriptionText),
                    AIPetMakerDefaults.maximumDescriptionCharacters
                ))
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
                ForEach(QualityLevel.allCases) { quality in
                    Text(APCLocalizedPresentation.qualityTitle(quality)).tag(quality)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(fieldsAreLocked)
            .help(qualityGuidance)
            .accessibilityHint(qualityGuidance)
            .accessibilityIdentifier("maker.brief.quality")
        }
    }

    private var qualityGuidance: String {
        APCLocalization.format(
            .studioQualityContractFormat,
            APCLocalizedPresentation.qualityDetail(store.selectedQuality)
        )
    }

    private var referenceImages: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(APCLocalization.text(.studioReferencesHeading))
                .font(.headline)
            ReferenceImageDropZone()
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                    title: APCLocalizedPresentation.generationStateTitle(
                        store.generationSession.state,
                        operation: store.generationSession.operation
                    ),
                    tone: PetStudioPresentation.statusTone(for: store.generationSession.state)
                )
            }

            if store.generationSession.state != .idle {
                GenerationProgressView()
            }

            if store.generationSession.state == .failed {
                terminalAction
            }

            Group {
                if store.generationSession.state == .idle {
                    welcomeState
                } else {
                    timeline
                }
            }
            .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(APCDesign.stroke, lineWidth: 1)
                    .allowsHitTesting(false)
            }

            if store.generationSession.state != .idle {
                if store.generationSession.state != .failed {
                    terminalAction
                }
                if !store.generationSession.state.isTerminal {
                    replyComposer
                }
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
        .accessibilityIdentifier("maker.session")
    }

    private var welcomeState: some View {
        Label(APCLocalization.text(.studioWelcomeDetail), systemImage: "sparkles")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 290, alignment: .center)
    }

    private var timeline: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 12) {
                if store.generationSession.operation == .modify,
                   let form = store.generationSession.submittedForm {
                    SubmittedFormSummary(form: form)
                    Divider()
                }

                ForEach(PetStudioPresentation.timelineMessages(
                    store.generationSession.messages
                )) { message in
                    GenerationTimelineRow(message: message)
                }

                if store.generationSession.messages.isEmpty {
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
            InlineSessionNotice(
                title: APCLocalization.text(.studioFailedTitle),
                detail: failureNoticeDetail,
                systemImage: "exclamationmark.triangle",
                color: APCDesign.destructive
            )
        case .cancelled:
            InlineSessionNotice(
                title: APCLocalization.text(.studioCancelledTitle),
                detail: APCLocalization.text(.studioCancelledDetail),
                systemImage: "xmark.circle",
                color: .secondary
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
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    InlineSessionNotice(
                        title: APCLocalization.text(.studioSucceededTitle),
                        detail: APCLocalization.text(.studioSuccessGeneric),
                        systemImage: "checkmark.seal.fill",
                        color: APCDesign.success
                    )

                    if let petID = store.generationSession.resultPetID {
                        LabeledContent(APCLocalization.text(.studioSuccessPetID)) {
                            Text(petID)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    if let revisionID = store.generationSession.resultRevisionID {
                        LabeledContent(APCLocalization.text(.studioSuccessRevision)) {
                            Text(revisionID)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    if let validation = store.generationSession.validationSummary {
                        LabeledContent(
                            APCLocalization.text(.studioSuccessValidation),
                            value: APCLocalization.format(
                                .studioSuccessValidationFormat,
                                validation.stateCount,
                                validation.frameCount,
                                validation.warningCount
                            )
                        )
                    }

                    HStack {
                        Spacer()
                        Button(APCLocalization.text(.studioViewLibrary)) {
                            store.selection = .library
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("maker.action.view-library")
                    }
                }
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
            .buttonStyle(.borderedProminent)
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
        case .cancelled: APCLocalization.text(.studioReplyCancelled)
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
            progress: store.generationSession.progress
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
                sessionState: store.generationSession.state
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

struct SubmittedFormSummary: View {
    var form: GenerationForm?

    var body: some View {
        if let form {
            VStack(alignment: .leading, spacing: 8) {
                Text(APCLocalization.text(.studioSubmittedBrief))
                    .font(.headline)
                LabeledContent(APCLocalization.text(.studioFieldDescription), value: form.description)
                LabeledContent(
                    APCLocalization.text(.studioFieldStyle),
                    value: localizedStyle(form.style)
                )
                LabeledContent(
                    APCLocalization.text(.studioFieldQuality),
                    value: "\(APCLocalizedPresentation.qualityTitle(form.quality)) · \(form.quality.renderSize.width)×\(form.quality.renderSize.height)"
                )
                LabeledContent(
                    APCLocalization.text(.studioFieldReferences),
                    value: APCLocalization.format(.commonImagesFormat, form.referenceImages.count)
                )
            }
            .font(.caption)
        } else {
            Label(APCLocalization.text(.studioSubmittedPending), systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func localizedStyle(_ storedValue: String) -> String {
        guard let style = StylePreset(rawValue: storedValue) else { return storedValue }
        return APCLocalizedPresentation.styleTitle(style)
    }
}

struct GenerationTimelineRow: View {
    var message: GenerationMessage

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        if PetStudioPresentation.isProgressMessage(message) {
            Label(message.content, systemImage: "gearshape.2")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(isUser ? APCLocalization.text(.studioMessageYou) : "AI")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(message.content)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isUser ? APCDesign.accentSoft : Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isUser ? APCDesign.accent.opacity(0.35) : APCDesign.stroke, lineWidth: 1)
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }
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
                value: APCLocalization.text(.studioBaselineAnimationValue)
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
    enum FailureRecoveryAction: Equatable {
        case retry
        case reselectReferences(count: Int)
    }

    static func failureRecoveryAction(
        sessionCanRetry: Bool,
        referenceReselectionCount: Int
    ) -> FailureRecoveryAction? {
        guard sessionCanRetry else { return nil }
        let boundedCount = max(0, referenceReselectionCount)
        return boundedCount > 0 ? .reselectReferences(count: boundedCount) : .retry
    }

    enum StageState: Equatable {
        case complete
        case current
        case upcoming
        case failed

        var systemImage: String {
            switch self {
            case .complete: "checkmark.circle.fill"
            case .current: "circle.fill"
            case .upcoming: "circle"
            case .failed: "exclamationmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .complete: APCDesign.success
            case .current: APCDesign.accent
            case .upcoming: .secondary
            case .failed: APCDesign.destructive
            }
        }

        var accessibilityTitle: String {
            switch self {
            case .complete: APCLocalization.text(.studioStageComplete)
            case .current: APCLocalization.text(.studioStageCurrent)
            case .upcoming: APCLocalization.text(.studioStageUpcoming)
            case .failed: APCLocalization.text(.studioStageFailed)
            }
        }
    }

    static func showsModificationWorkspace(for session: GenerationSession) -> Bool {
        session.operation == .modify && session.state != .idle
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

    static func isProgressMessage(_ message: GenerationMessage) -> Bool {
        message.kind == "generation_progress" || message.kind == "generation_started"
    }

    static func failureDetail(
        for messages: [GenerationMessage],
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        maximumSummaryScalars: Int = 240
    ) -> String {
        let recovery = APCLocalization.text(.studioFailedDetail)
        guard maximumSummaryScalars > 0,
              let failure = messages.last(where: { $0.kind == "generation_failed" })
        else { return recovery }

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
        case .failed: .warning
        case .starting, .running, .waitingForInput, .cancelling: .accent
        case .idle, .cancelled: .neutral
        }
    }

    static func shouldFocusComposer(onAppearFor state: GenerationSessionState) -> Bool {
        state == .waitingForInput
    }

    static func stageState(
        at index: Int,
        activeIndex: Int,
        sessionState: GenerationSessionState
    ) -> StageState {
        if sessionState == .failed, index == activeIndex { return .failed }
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
