import AgentPetCompanionCore
import MetalKit
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedPetID: String?
    @State private var demoSequence = OnboardingDemoSequence()
    @State private var demoRunID = 0
    @State private var pendingRepairSource: AgentSource?

    private var progress: OnboardingProgress {
        store.onboarding?.progress ?? OnboardingProgress()
    }

    private var connectionPresentations: [AgentConnectionProductPresentation] {
        AgentConnectionsCatalog.sources.map { source in
            AgentConnectionProductPresentation(
                source: source,
                status: store.connections.first { $0.source == source },
                operationState: store.connectionOperationState
            )
        }
    }

    private var connectionState: OnboardingConnectionSceneState {
        let visible = connectionPresentations.compactMap { presentation in
            OnboardingAgentPresentation(
                source: presentation.source,
                health: presentation.health,
                primaryAction: presentation.primaryAction
            )
        }
        if visible.isEmpty {
            return .checking
        }
        if visible.allSatisfy({ $0.health == .unavailable }) {
            return .noAgents
        }
        return .agents(visible)
    }

    private var flowPresentation: OnboardingFlowPresentation {
        OnboardingFlowPresentation(
            progress: progress,
            availability: store.onboardingAvailability,
            pets: store.onboardingCompanionCandidates,
            selectedPetID: selectedPetID,
            unavailablePetIDs: Set(
                store.onboardingCompanionCandidates.compactMap { pet in
                    store.petAssetWarningIndex[pet.id] == nil ? nil : pet.id
                }
            ),
            connectionState: connectionState,
            demoSequence: demoSequence
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: SharedProductComponentLayout.pageSpacing
                ) {
                    if store.onboardingAvailability == .serviceUnavailable {
                        serviceUnavailableBanner
                    }
                    if let failure = store.onboardingOperationFailure {
                        operationFailureBanner(failure)
                    }
                    scene
                }
                .frame(maxWidth: 920, alignment: .topLeading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .top)
            }

            Divider()
            bottomBar
        }
        .frame(
            minWidth: ControlCenterShellPolicy.supportedMinimumWindowWidth,
            minHeight: ControlCenterShellPolicy.supportedMinimumWindowHeight
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("onboarding.root")
        .onAppear(perform: synchronizePetSelection)
        .onChange(of: store.onboardingCompanionCandidates.map(\.id)) {
            synchronizePetSelection()
        }
        .onChange(of: flowPresentation.unavailablePetIDs) {
            synchronizePetSelection()
        }
        .onChange(of: progress.stage) {
            if progress.stage == .demo {
                demoRunID &+= 1
            } else {
                demoSequence.reset()
            }
        }
        .task(id: sceneTaskIdentity) {
            await prepareCurrentScene()
        }
        .confirmationDialog(
            repairConfirmationTitle,
            isPresented: repairConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(APCLocalization.text(.connectionsWriteRepair)) {
                confirmPendingRepair()
            }
            Button(APCLocalization.text(.commonCancel), role: .cancel) {
                pendingRepairSource = nil
            }
        } message: {
            Text(APCLocalization.text(.onboardingRepairConfirmationDetail))
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(APCLocalization.text(.onboardingTitle))
                    .font(.title2.weight(.semibold))
                Text(APCLocalization.format(
                    .onboardingProgressFormat,
                    currentSceneNumber
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                store.dismissOnboardingForCurrentLaunch()
            } label: {
                Label(
                    APCLocalization.text(.onboardingClose),
                    systemImage: "xmark"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(APCLocalization.text(.onboardingClose))
            .accessibilityLabel(APCLocalization.text(.onboardingClose))
            .accessibilityIdentifier("onboarding.close")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var scene: some View {
        switch progress.stage {
        case .choosePet:
            choosePetScene
        case .connectAgents:
            connectAgentsScene
        case .demo:
            demoScene
        case .completed, .skipped:
            EmptyView()
        }
    }

    private var choosePetScene: some View {
        VStack(alignment: .leading, spacing: 18) {
            ProductPageHeader(
                identity: ProductComponentIdentity(scope: "onboarding", instance: "choose-pet"),
                title: APCLocalization.text(.onboardingChooseTitle),
                summary: APCLocalization.text(.onboardingChooseDetail)
            )

            if flowPresentation.pets.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        APCLocalization.text(.onboardingPetsUnavailableTitle),
                        systemImage: "shippingbox"
                    )
                    .font(.headline)
                    Text(APCLocalization.text(.onboardingPetsUnavailableDetail))
                        .foregroundStyle(.secondary)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            restoreIncludedCompanionsButton
                            onboardingDiagnosticsButton
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            restoreIncludedCompanionsButton
                            onboardingDiagnosticsButton
                        }
                    }

                    if store.includedCompanionRestoreState == .failed {
                        Text(APCLocalization.text(.onboardingPetsRestoreFailed))
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    APCDesign.panel,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 16),
                    ],
                    spacing: 16
                ) {
                    ForEach(flowPresentation.pets) { pet in
                        bundledPetCard(pet)
                    }
                }
            }
        }
        .accessibilityIdentifier("onboarding.scene.choose-pet")
    }

    private var restoreIncludedCompanionsButton: some View {
        Button {
            store.restoreIncludedCompanions()
        } label: {
            Label(
                APCLocalization.text(
                    store.includedCompanionRestoreState == .restoring
                        ? .onboardingPetsRestoring
                        : .onboardingPetsRestore
                ),
                systemImage: "arrow.clockwise"
            )
        }
        .buttonStyle(.borderedProminent)
        .disabled(
            store.includedCompanionRestoreState == .restoring
                || store.onboardingAvailability != .ready
        )
        .accessibilityIdentifier("onboarding.pets.restore")
    }

    private var onboardingDiagnosticsButton: some View {
        Button {
            openDiagnosticsFromOnboarding()
        } label: {
            Label(
                APCLocalization.text(.assetRecoveryDiagnostics),
                systemImage: "stethoscope"
            )
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("onboarding.pets.diagnostics")
    }

    @ViewBuilder
    private func bundledPetCard(_ pet: PetSummary) -> some View {
        let selected = pet.id == flowPresentation.selectedPetID
        if store.petAssetWarningIndex[pet.id] != nil {
            VStack(alignment: .leading, spacing: 12) {
                PetAssetRecoveryCard(
                    pet: pet,
                    state: store.petAssetRepairState(for: pet.id),
                    onRepair: { store.repairPetAssets(pet) },
                    onOpenDiagnostics: openDiagnosticsFromOnboarding
                )
                petIdentity(pet, selected: false)
            }
            .padding(14)
            .background(
                APCDesign.panel,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(APCDesign.stroke, lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("onboarding.pet.\(pet.id)")
        } else {
            Button {
                selectedPetID = pet.id
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    PetPreviewStage(
                        identity: ProductComponentIdentity(
                            scope: "onboarding-pet",
                            instance: pet.id
                        ),
                        accessibilityLabel: pet.name,
                        minimumHeight: 250
                    ) {
                        PetLibraryAnimationPreview(pet: pet)
                    }

                    petIdentity(pet, selected: selected)
                }
                .padding(14)
                .background(
                    APCDesign.panel,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            selected ? APCDesign.accent : APCDesign.stroke,
                            lineWidth: selected ? 2 : 1
                        )
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pet.name)
            .accessibilityValue(
                selected
                    ? APCLocalization.text(.controlSelected)
                    : APCLocalization.text(.controlUnselected)
            )
            .accessibilityIdentifier("onboarding.pet.\(pet.id)")
        }
    }

    private func petIdentity(
        _ pet: PetSummary,
        selected: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pet.name)
                    .font(.headline)
                Text(pet.style)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(APCDesign.accent)
                    .accessibilityHidden(true)
            }
        }
    }

    private var connectAgentsScene: some View {
        VStack(alignment: .leading, spacing: 18) {
            ProductPageHeader(
                identity: ProductComponentIdentity(
                    scope: "onboarding",
                    instance: "connect-agents"
                ),
                title: APCLocalization.text(.onboardingConnectTitle),
                summary: APCLocalization.text(.onboardingConnectDetail)
            )

            if connectionState == .checking {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(APCLocalization.text(.onboardingConnectChecking))
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if connectionPresentations
                    .filter({ $0.health != .checking })
                    .allSatisfy({ $0.health == .unavailable }) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(APCLocalization.text(.onboardingNoAgentsTitle))
                            .font(.headline)
                        Text(APCLocalization.text(.onboardingNoAgentsDetail))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 12) {
                    ForEach(
                        connectionPresentations.filter { $0.health != .checking },
                        id: \.source
                    ) { presentation in
                        onboardingAgentRow(presentation)
                    }
                }
            }
        }
        .accessibilityIdentifier("onboarding.scene.connect-agents")
    }

    private func onboardingAgentRow(
        _ presentation: AgentConnectionProductPresentation
    ) -> some View {
        AgentHealthRow(
            identity: ProductComponentIdentity(
                scope: "onboarding-agent",
                instance: presentation.source.rawValue
            ),
            agentTitle: presentation.source.title,
            agentSummary: AgentConnectionsPresentation.healthSummary(
                for: presentation,
                operationState: store.connectionOperationState
            ),
            health: presentation.health,
            healthTitle: APCLocalizedPresentation.connectionHealthTitle(
                presentation.health
            ),
            taskVerification: presentation.taskVerification,
            taskVerificationTitle:
                AgentConnectionsPresentation.taskVerificationTitle(
                    presentation.taskVerification
                ),
            taskVerificationDetail:
                AgentConnectionsPresentation.taskVerificationDetail(
                    presentation.taskVerification
                ),
            primaryAction: AgentConnectionsPresentation.primaryActionPresentation(
                for: presentation,
                busy: !store.canStartConnectionOperation
                    || store.onboardingMutationInFlight
            )
        ) { action in
            performConnectionAction(action, for: presentation)
        }
    }

    private var demoScene: some View {
        VStack(alignment: .leading, spacing: 18) {
            ProductPageHeader(
                identity: ProductComponentIdentity(scope: "onboarding", instance: "demo"),
                title: APCLocalization.text(.onboardingDemoTitle),
                summary: APCLocalization.text(.onboardingDemoDetail)
            )

            Label(
                APCLocalization.text(.onboardingDemoLocalLabel),
                systemImage: "play.square.stack"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(APCDesign.accent)
            .accessibilityIdentifier("onboarding.demo.local")

            PetPreviewStage(
                identity: ProductComponentIdentity(scope: "onboarding", instance: "demo"),
                accessibilityLabel: demoPhaseTitle,
                minimumHeight: 300
            ) {
                ZStack(alignment: .bottom) {
                    if let pet = store.activePet ?? flowPresentation.pets.first {
                        OnboardingPetAnimationPreview(
                            pet: pet,
                            assetWarning: store.petAssetWarningIndex[pet.id],
                            lifecycle: demoSequence.phase.lifecycleState
                        )
                    }

                    VStack(spacing: 5) {
                        Text(demoPhaseTitle)
                            .font(.title3.weight(.semibold))
                        Text(demoPhaseDetail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .padding(18)
                }
                .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 360)
            }
            .accessibilityIdentifier("onboarding.demo.phase")

            HStack {
                Button {
                    demoRunID &+= 1
                } label: {
                    Label(
                        APCLocalization.text(.onboardingDemoReplay),
                        systemImage: "arrow.counterclockwise"
                    )
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("onboarding.demo.restart")

                Spacer()

                if demoSequence.isComplete {
                    Text(APCLocalization.text(.onboardingDemoInvitation))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .accessibilityIdentifier("onboarding.scene.demo")
    }

    private var serviceUnavailableBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "network.slash")
                .foregroundStyle(APCDesign.destructive)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(APCLocalization.text(.onboardingServiceUnavailableTitle))
                    .font(.headline)
                Text(APCLocalization.text(.onboardingServiceUnavailableDetail))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(APCLocalization.text(.commonRetry)) {
                store.retryOnboardingService()
            }
            .accessibilityIdentifier("onboarding.service.retry")
        }
        .padding(16)
        .background(
            APCDesign.destructive.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func operationFailureBanner(
        _ failure: OnboardingOperationFailure
    ) -> some View {
        Label(onboardingFailureText(failure), systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(APCDesign.destructive)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                APCDesign.destructive.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .accessibilityIdentifier("onboarding.operation.failure")
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if flowPresentation.allowsSkip {
                Button(APCLocalization.text(.onboardingSkip)) {
                    Task {
                        _ = await store.advanceOnboarding(to: .skipped)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(store.onboardingMutationInFlight)
                .accessibilityIdentifier("onboarding.skip")
            }

            Spacer()

            if let primary = flowPresentation.primaryAction {
                Button {
                    performPrimaryAction(primary)
                } label: {
                    if store.onboardingMutationInFlight {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(primaryActionTitle(primary))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.onboardingMutationInFlight)
                .accessibilityLabel(primaryActionTitle(primary))
                .accessibilityIdentifier(
                    "onboarding.primary.\(progress.stage.rawValue)"
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var currentSceneNumber: Int {
        switch progress.stage {
        case .choosePet: 1
        case .connectAgents: 2
        case .demo, .completed, .skipped: 3
        }
    }

    private var sceneTaskIdentity: String {
        "\(progress.stage.rawValue):\(demoRunID)"
    }

    private func prepareCurrentScene() async {
        switch progress.stage {
        case .choosePet:
            return
        case .connectAgents:
            guard store.onboardingAvailability == .ready,
                  store.connections.isEmpty,
                  store.canStartConnectionOperation
            else { return }
            store.checkAllConnections()
        case .demo:
            await runLocalDemo()
        case .completed, .skipped:
            return
        }
    }

    private func runLocalDemo() async {
        demoSequence.reset()
        for _ in 0..<3 {
            do {
                try await Task.sleep(
                    for: reduceMotion ? .milliseconds(700) : .milliseconds(1_250)
                )
            } catch {
                return
            }
            guard !Task.isCancelled, progress.stage == .demo else { return }
            if reduceMotion {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                _ = withTransaction(transaction) {
                    demoSequence.advance()
                }
            } else {
                _ = withAnimation(.easeInOut(duration: 0.25)) {
                    demoSequence.advance()
                }
            }
        }
    }

    private func synchronizePetSelection() {
        let candidates = store.onboardingCompanionCandidates.filter {
            store.petAssetWarningIndex[$0.id] == nil
        }
        if let selectedPetID,
           candidates.contains(where: { $0.id == selectedPetID }) {
            return
        }
        selectedPetID = candidates.first(where: \.active)?.id
            ?? candidates.first?.id
    }

    private func openDiagnosticsFromOnboarding() {
        store.dismissOnboardingForCurrentLaunch()
        store.selection = .diagnostics
    }

    private func performPrimaryAction(_ action: OnboardingPrimaryAction) {
        switch action {
        case .confirmPet:
            guard let selectedPetID,
                  let pet = flowPresentation.pets.first(where: {
                      $0.id == selectedPetID
                  })
            else { return }
            Task {
                _ = await store.confirmOnboardingPet(pet)
            }
        case .continueToDemo:
            Task {
                _ = await store.advanceOnboarding(to: .demo)
            }
        case .finish:
            Task {
                _ = await store.advanceOnboarding(to: .completed)
            }
        }
    }

    private func performConnectionAction(
        _ action: AgentConnectionPrimaryAction,
        for presentation: AgentConnectionProductPresentation
    ) {
        switch action {
        case .connect, .repair:
            guard presentation.canRepairManagedConnector,
                  presentation.primaryAction == action
            else { return }
            pendingRepairSource = presentation.source
        case .verify:
            guard store.canStartConnectionOperation else { return }
            store.checkConnection(presentation.source)
        case .retry:
            store.retryConnectionOperation()
        case .unavailable:
            break
        }
    }

    private func confirmPendingRepair() {
        guard let source = pendingRepairSource else { return }
        defer { pendingRepairSource = nil }
        let current = AgentConnectionProductPresentation(
            source: source,
            status: store.connections.first { $0.source == source },
            operationState: store.connectionOperationState
        )
        guard current.canRepairManagedConnector,
              current.primaryAction == .connect || current.primaryAction == .repair
        else { return }
        store.repairConnection(source)
    }

    private var repairConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingRepairSource != nil },
            set: { presented in
                if !presented {
                    pendingRepairSource = nil
                }
            }
        )
    }

    private var repairConfirmationTitle: String {
        guard let source = pendingRepairSource else { return "" }
        return APCLocalization.format(
            .connectionsConfirmRepairFormat,
            source.title
        )
    }

    private func primaryActionTitle(_ action: OnboardingPrimaryAction) -> String {
        switch action {
        case .confirmPet:
            APCLocalization.text(.onboardingChooseConfirm)
        case .continueToDemo:
            APCLocalization.text(.onboardingConnectContinue)
        case .finish:
            APCLocalization.text(.onboardingFinish)
        }
    }

    private var demoPhaseTitle: String {
        switch demoSequence.phase {
        case .thinking:
            APCLocalization.text(.onboardingDemoThinking)
        case .working:
            APCLocalization.text(.onboardingDemoWorking)
        case .needsAttention:
            APCLocalization.text(.onboardingDemoNeedsAttention)
        case .done:
            APCLocalization.text(.onboardingDemoDone)
        }
    }

    private var demoPhaseDetail: String {
        switch demoSequence.phase {
        case .thinking:
            APCLocalization.text(.onboardingDemoThinkingDetail)
        case .working:
            APCLocalization.text(.onboardingDemoWorkingDetail)
        case .needsAttention:
            APCLocalization.text(.onboardingDemoNeedsAttentionDetail)
        case .done:
            APCLocalization.text(.onboardingDemoDoneDetail)
        }
    }

    private func onboardingFailureText(
        _ failure: OnboardingOperationFailure
    ) -> String {
        let key: APCLocalizationKey = switch failure {
        case .serviceUnavailable:
            .onboardingFailureService
        case .petActivation:
            .onboardingFailurePetActivation
        case .revisionConflict:
            .onboardingFailureRevisionConflict
        case .requestRejected:
            .onboardingFailureRequest
        }
        return APCLocalization.text(key)
    }
}

/// The demo renderer is intentionally scoped to this view. It consumes only
/// the selected pet and local phase reducer and has no store or transport
/// reference.
private struct OnboardingPetAnimationPreview: View {
    let pet: PetSummary
    let assetWarning: PetAssetWarning?
    let lifecycle: ProductLifecycleState

    @State private var rendererHasContent = false

    var body: some View {
        ZStack {
            PetCoverImage(
                pet: pet,
                assetWarning: assetWarning,
                fallbackScale: 0.44
            )
                .opacity(rendererHasContent ? 0 : 1)
            if PetLibraryPreviewPolicy.canRender(
                assetWarning: assetWarning
            ) {
                OnboardingPetMetalView(
                    pet: pet,
                    stateName: lifecycle.rawValue
                ) { hasContent in
                    rendererHasContent = hasContent
                }
                .id("\(pet.id):\(lifecycle.rawValue)")
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .onChange(of: lifecycle) {
            rendererHasContent = false
        }
        .onChange(of: assetWarning?.fingerprint) {
            rendererHasContent = false
        }
    }
}

private struct OnboardingPetMetalView: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let pet: PetSummary
    let stateName: String
    let onRendererContentChanged: @MainActor (Bool) -> Void

    func makeCoordinator() -> PetMetalFrameRenderer {
        PetMetalFrameRenderer()
    }

    @MainActor
    func makeNSView(context: Context) -> MTKView {
        context.coordinator.makeView()
    }

    @MainActor
    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.configure(
            view: view,
            pet: pet,
            stateName: stateName,
            stateEntryID: "onboarding-local-demo:\(pet.id):\(stateName)",
            fpsProfile: PetLibraryPreviewPolicy.playbackProfile(for: pet),
            active: true,
            reduceMotion: reduceMotion,
            onVisualEnvelopeChanged: { envelope in
                onRendererContentChanged(envelope != nil)
            }
        )
    }

    @MainActor
    static func dismantleNSView(
        _ view: MTKView,
        coordinator: PetMetalFrameRenderer
    ) {
        coordinator.suspendPipeline()
        view.isPaused = true
        view.delegate = nil
    }
}
