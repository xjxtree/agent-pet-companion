import AgentPetCompanionCore
import SwiftUI

struct PetMakerResultView: View {
    @EnvironmentObject private var store: AppStore

    @State private var continuationIsVisible = false
    @State private var continuationText = ""
    @State private var technicalDetailsAreExpanded = false

    private let identity = ProductComponentIdentity(scope: "maker", instance: "result")

    private var resultPet: PetSummary? {
        MakerResultPresentation.resultPet(
            for: store.generationSession,
            in: store.pets
        )
    }

    private var productPresentation: PetMakerProductPresentation {
        PetMakerProductPresentation(
            session: store.generationSession,
            resultPetAvailable: resultPet != nil,
            referenceReselectionCount: store.referenceReselectionCount
        )
    }

    var body: some View {
        PrimaryExperienceCard(
            identity: identity,
            title: resultPet?.name ?? APCLocalization.text(.studioSucceededTitle),
            summary: APCLocalization.text(.studioSuccessGeneric),
            status: ProductStatusPresentation(
                appearance: .normal,
                title: APCLocalization.text(.studioSucceededTitle)
            ),
            primaryAction: ProductActionPresentation(
                action: productPresentation.primaryAction,
                title: APCLocalizedPresentation.primaryActionTitle(
                    productPresentation.primaryAction
                )
                    ?? APCLocalization.text(.libraryEnablePet),
                systemImage: "checkmark.circle.fill",
                isEnabled: productPresentation.primaryAction == .usePet
            ),
            onPrimaryAction: { action in
                guard action == .usePet else { return }
                useResultPet()
            }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                resultPreview
                secondaryActions

                if continuationIsVisible {
                    continuationComposer
                }

                technicalDetails
            }
        }
        .accessibilityIdentifier("maker.result")
    }

    @ViewBuilder
    private var resultPreview: some View {
        PetPreviewStage(
            identity: identity,
            accessibilityLabel: previewAccessibilityLabel,
            minimumHeight: 280
        ) {
            if let resultPet {
                PetLibraryAnimationPreview(
                    pet: resultPet,
                    assetWarning: store.petAssetWarningIndex[resultPet.id]
                )
                    .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 360)
            } else {
                MissingPetCoverPlaceholder(scale: 0.5)
                    .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 360)
            }
        }
    }

    private var secondaryActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                continuationButton
                exportButton
            }

            VStack(alignment: .leading, spacing: 10) {
                continuationButton
                exportButton
            }
        }
    }

    private var continuationButton: some View {
        Button {
            continuationIsVisible.toggle()
        } label: {
            Label(
                APCLocalizedPresentation.primaryActionTitle(
                    PetMakerPrimaryAction.continueEditing
                )
                    ?? APCLocalization.text(.studioReplySucceeded),
                systemImage: "wand.and.stars"
            )
        }
        .buttonStyle(.bordered)
        .disabled(!productPresentation.secondaryActions.contains(.continueEditing))
        .accessibilityIdentifier("maker.result.continue-editing")
    }

    private var exportButton: some View {
        Button {
            guard let resultPet else { return }
            store.exportPet(resultPet)
        } label: {
            Label(
                APCLocalization.text(.libraryExportAction),
                systemImage: "square.and.arrow.up"
            )
        }
        .buttonStyle(.bordered)
        .disabled(resultPet == nil)
        .accessibilityIdentifier("maker.result.export")
    }

    private var continuationComposer: some View {
        HStack(spacing: 8) {
            TextField(
                APCLocalization.text(.studioReplySucceeded),
                text: $continuationText
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit(continueEditing)
            .accessibilityIdentifier("maker.result.edit-instruction")

            Button(action: continueEditing) {
                Image(systemName: "arrow.right")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinueEditing)
            .accessibilityLabel(
                APCLocalizedPresentation.primaryActionTitle(
                    PetMakerPrimaryAction.continueEditing
                )
                    ?? APCLocalization.text(.studioReplySucceeded)
            )
            .accessibilityIdentifier("maker.result.edit-submit")
        }
    }

    private var technicalDetails: some View {
        AdvancedDetailsDisclosure(
            identity: ProductComponentIdentity(
                scope: "maker",
                instance: "result-technical"
            ),
            title: APCLocalization.text(.libraryCurrentInfo),
            summary: APCLocalization.text(.libraryTechnicalInformationSummary),
            isExpanded: $technicalDetailsAreExpanded
        ) {
            VStack(alignment: .leading, spacing: 8) {
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
                if let form = store.generationSession.submittedForm {
                    LabeledContent(
                        APCLocalization.text(.studioTimingNativeFPS),
                        value: MakerMotionPresentation.exactValue(
                            nativeFPS: form.nativeFPS
                        )
                    )
                    LabeledContent(
                        APCLocalization.text(.studioTimingActionDurations),
                        value: PetStudioPresentation.stateDurationSummary(
                            form.stateDurationsMS
                        )
                    )
                }
            }
            .font(.caption)
        }
    }

    private var previewAccessibilityLabel: String {
        guard let resultPet else {
            return APCLocalization.text(.libraryMissingPreview)
        }
        return APCLocalization.format(
            .libraryAnimationAccessibilityFormat,
            resultPet.name
        )
    }

    private var canContinueEditing: Bool {
        resultPet != nil
            && !continuationText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
    }

    private func useResultPet() {
        guard let resultPet else { return }
        if resultPet.active {
            store.selection = .library
        } else {
            store.activatePet(resultPet)
        }
    }

    private func continueEditing() {
        guard let resultPet else { return }
        let instruction = continuationText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        store.startPetEdit(
            resultPet,
            baselineRevisionID: store.generationSession.resultRevisionID,
            instruction: instruction
        )
        continuationText = ""
        continuationIsVisible = false
    }
}
