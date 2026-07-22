import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("UI Next non-interactive contract")
struct UINextContractTests {
    @Test
    func navigationAndMainWindowKeepTheFixedProductShell() throws {
        #expect(NavigationSection.allCases == [
            .library,
            .maker,
            .configuration,
            .connections,
            .diagnostics,
        ])

        let app = try source("AgentPetCompanion/App/AgentPetCompanionApp.swift")
        #expect(app.contains("Window(\"Agent Pet Companion\", id: \"main\")"))
        #expect(!app.contains("WindowGroup("))
        #expect(app.contains(".defaultSize(width: 1120, height: 720)"))
        #expect(app.contains(".frame(minWidth: 760, minHeight: 520)"))
        #expect(app.contains(".windowResizability(.contentMinSize)"))
        #expect(app.contains(".windowToolbarStyle(.unified)"))

        let content = try source("AgentPetCompanion/Views/ContentView.swift")
        #expect(containsInOrder([
            "case .library:",
            "case .maker:",
            "case .configuration:",
            "case .connections:",
            "case .diagnostics:",
        ], in: content))

        #expect(ControlCenterShellPolicy(windowWidth: 1_120).mode == .allColumns)
        #expect(ControlCenterShellPolicy(windowWidth: 1_119).mode == .sidebarAndContent)
        #expect(ControlCenterShellPolicy(windowWidth: 880).mode == .sidebarAndContent)
        #expect(ControlCenterShellPolicy(windowWidth: 879).mode == .singleContent)
        #expect(ControlCenterShellPolicy(windowWidth: 760).mode == .singleContent)
        #expect(ControlCenterShellMode.allColumns.keepsInspectorPresented)
        #expect(!ControlCenterShellMode.sidebarAndContent.keepsInspectorPresented)
        #expect(!ControlCenterShellMode.singleContent.keepsInspectorPresented)
        #expect(PetLibraryGridPolicy.candidateColumnCounts(for: .allColumns) == [4, 3, 2])
        #expect(PetLibraryGridPolicy.candidateColumnCounts(for: .sidebarAndContent) == [4, 3, 2])
        #expect(PetLibraryGridPolicy.candidateColumnCounts(for: .singleContent) == [1])
        #expect(PetLibraryGridPolicy.columns(count: 5).count == 4)
        #expect(PetLibraryGridPolicy.columns(count: 0).count == 1)
        #expect(AgentConnectionsNextLayout.mode(
            for: ControlCenterShellPolicy(windowWidth: 1_120).mode
        ) == .full)
        #expect(AgentConnectionsNextLayout.mode(
            for: ControlCenterShellPolicy(windowWidth: 1_119).mode
        ) == .listDetail)
        #expect(AgentConnectionsNextLayout.mode(
            for: ControlCenterShellPolicy(windowWidth: 879).mode
        ) == .compact)
        #expect(BehaviorSettingsNextLayout.usesWideLayout(
            contentWidth: 900,
            shellMode: ControlCenterShellPolicy(windowWidth: 1_120).mode
        ))
        #expect(!BehaviorSettingsNextLayout.usesWideLayout(
            contentWidth: 900,
            shellMode: ControlCenterShellPolicy(windowWidth: 1_119).mode
        ))
        #expect(
            ControlCenterShellPolicy(windowWidth: 1_120).preferredColumnVisibility == .all
        )
        #expect(
            ControlCenterShellPolicy(windowWidth: 880).preferredColumnVisibility == .all
        )
        #expect(
            ControlCenterShellPolicy(windowWidth: 760).preferredColumnVisibility == .detailOnly
        )

        let shell = try source("AgentPetCompanion/Views/ControlCenterShell.swift")
        #expect(shell.contains("window?.title = title"))
        #expect(content.contains("ControlCenterWindowTitleUpdater"))
        #expect(content.contains("store.selection != .diagnostics"))
        #expect(!content.contains(".navigationTitle("))
    }

    @Test
    func pagesOwnOnePrimaryTitleWithoutAContainerNavigationTitle() throws {
        let content = try source("AgentPetCompanion/Views/ContentView.swift")
        #expect(!content.contains(".navigationTitle("))

        let library = try source("AgentPetCompanion/Views/PetLibraryView.swift")
        let maker = try source("AgentPetCompanion/Views/PetStudioView.swift")
        #expect(occurrences(of: "PageActionHeader(", in: library) == 1)
        #expect(occurrences(of: "PageActionHeader(", in: maker) == 1)

        let configuration = try source("AgentPetCompanion/Views/BehaviorSettingsView.swift")
        let configurationHeader = try section(
            in: configuration,
            from: "private func pageHeader(for section:",
            to: "private var previewPane"
        )
        #expect(occurrences(of: ".font(.title2", in: configurationHeader) == 1)

        let connections = try source("AgentPetCompanion/Views/AgentConnectionsView.swift")
        let connectionHeader = try section(
            in: connections,
            from: "private var pageActionHeader:",
            to: "private var globalActions"
        )
        #expect(occurrences(of: "PageActionHeader(", in: connectionHeader) == 1)
        #expect(connectionHeader.contains("globalActions"))
        #expect(!connectionHeader.contains("HStack("))

        let diagnostics = try source("AgentPetCompanion/Views/ServiceDiagnosticsView.swift")
        let diagnosticsBody = try section(
            in: diagnostics,
            from: "var body: some View",
            to: "private var serviceStatusRegion"
        )
        #expect(occurrences(of: ".font(.title2", in: diagnosticsBody) == 1)
    }

    @Test
    func makerUsesTheTwoStageWorkspaceAtTheDefaultWideWindow() throws {
        let maker = try source("AgentPetCompanion/Views/PetStudioView.swift")
        let store = try source("AgentPetCompanion/App/AppStore.swift")

        #expect(maker.contains("@Environment(\\.controlCenterShellMode)"))
        #expect(maker.contains("if shellMode == .allColumns"))
        #expect(maker.contains("maker.layout.two-stage"))
        #expect(maker.contains("maker.layout.stacked"))

        let wide = try #require(maker.range(of: "if shellMode == .allColumns"))
        let stacked = try #require(maker.range(of: "maker.layout.stacked"))
        #expect(wide.lowerBound < stacked.lowerBound)
        #expect(store.contains("await restoreLatestGenerationSessionIfNeeded()"))
        #expect(store.contains("method: \"generation.latest\""))
        #expect(store.contains("generationDraftIsPristineForAutomaticRestore"))
        #expect(maker.contains("else if store.generationSession.canRetry"))
        #expect(maker.contains(".disabled(!store.canRetryGeneration)"))
        #expect(maker.contains(".accessibilityHint(retryAvailabilityHint)"))
    }

    @Test
    func ordinaryViewsDoNotUseLiquidGlass() throws {
        let viewsURL = macOSRootURL
            .appendingPathComponent("Sources/AgentPetCompanion/Views", isDirectory: true)
        let urls = try FileManager.default.contentsOfDirectory(
            at: viewsURL,
            includingPropertiesForKeys: nil
        )
        var offenders: [String] = []

        for url in urls where url.pathExtension == "swift"
            && url.lastPathComponent != "DesignSystem.swift"
        {
            let contents = try String(contentsOf: url, encoding: .utf8)
            if contents.contains("apcFloatingControlGlass") {
                offenders.append(url.lastPathComponent)
            }
        }

        #expect(offenders.isEmpty)
    }

    @Test
    func overlayMotionCoversHoverGlobalVisibilityAndReducedMotionLayout() throws {
        #expect(OverlayControlVisibility.transitionDelay(showing: true, forced: false) == .zero)
        #expect(OverlayControlVisibility.transitionDelay(showing: false, forced: false)
            == .milliseconds(300))
        #expect((0.12 ... 0.16).contains(OverlayMotion.controlFadeDuration))
        #expect((0.18 ... 0.22).contains(OverlayMotion.bubbleLayoutDuration))

        let store = try source("AgentPetCompanion/App/AppStore.swift")
        let overlayActions = try section(
            in: store,
            from: "func toggleOverlayBubble()",
            to: "func setOverlayPointerNearPet("
        )
        #expect(overlayActions.contains(
            "animateBubble: overlayBubbleDismissed != wasDismissed"
        ))
        #expect(occurrences(of: "animateBubble: true", in: overlayActions) == 5)

        let root = try source("AgentPetCompanion/Overlay/OverlayRootView.swift")
        #expect(!root.contains(".onChange(of: store.overlayBubbleDismissed)"))
        #expect(root.contains("OverlayMotion.controlFadeDuration"))
        #expect(root.contains("OverlayMotion.reducedMotionCrossfadeDuration"))

        let controller = try source("AgentPetCompanion/Overlay/PetOverlayController.swift")
        #expect(controller.contains("crossfadeBubblePanel"))
        #expect(controller.contains("bubblePanel.animator().alphaValue = 0"))
        #expect(controller.contains("bubblePanel.animator().alphaValue = 1"))
        #expect(controller.contains("OverlayMotion.reducedMotionCrossfadeHalfDelay"))
    }

    @Test
    func semanticGlassUsesNativeRegularAndASystemMaterialFallback() throws {
        let design = try source("AgentPetCompanion/Views/DesignSystem.swift")

        #expect(design.contains("if #available(macOS 26.0, *)"))
        #expect(design.contains("interactive ? .regular.interactive() : .regular"))
        #expect(design.contains("content.background(.regularMaterial, in: shape)"))
        #expect(design.contains("accessibilityReduceTransparency"))
        #expect(design.contains("colorSchemeContrast"))
        #expect(design.contains("glassView.style = .regular"))
        #expect(!design.contains("glassView.style = .clear"))
        #expect(design.contains("func apcFloatingControlGlass"))
        #expect(!design.contains("func apcLiquidGlass"))
    }

    @Test
    func libraryKeepsSelectionCardsAndOneProminentInspectorActivation() throws {
        let source = try source("AgentPetCompanion/Views/PetLibraryView.swift")
        let card = try section(
            in: source,
            from: "struct PetCard: View",
            to: "private struct PetLibraryInspector"
        )
        #expect(card.contains("Button(action: onSelect)"))
        #expect(card.contains("TapGesture(count: 2)"))
        #expect(card.contains(".onKeyPress(.return)"))
        #expect(card.contains("onActivate()"))
        #expect(!card.contains(".buttonStyle(.borderedProminent)"))
        #expect(card.contains("pet-library.card."))

        let inspector = try section(
            in: source,
            from: "private struct PetLibraryInspector",
            to: "struct PetCoverImage"
        )
        #expect(source.contains(".inspector(isPresented:"))
        #expect(source.contains("@Environment(\\.controlCenterShellMode)"))
        #expect(source.contains("pet-library.inspector-toggle"))
        #expect(source.contains("shellMode.keepsInspectorPresented"))
        #expect(occurrences(of: ".buttonStyle(.borderedProminent)", in: inspector) == 1)
        #expect(inspector.contains("store.activatePet(pet)"))
        #expect(inspector.contains("pet-library.inspector.activate"))
    }

    @Test
    func makerKeepsSixStylesFourQualitiesAndStageOnlyProgress() throws {
        #expect(StylePreset.allCases == [
            .realistic,
            .semiRealistic,
            .modern,
            .pixel,
            .anime,
            .unspecified,
        ])
        #expect(QualityLevel.allCases == [.standard, .high, .ultra, .original])

        let source = try source("AgentPetCompanion/Views/PetStudioView.swift")
        #expect(source.contains("ForEach(StylePreset.allCases)"))
        #expect(source.contains("ForEach(QualityLevel.allCases)"))

        let progress = try section(
            in: source,
            from: "struct GenerationProgressView",
            to: "struct SubmittedFormSummary"
        )
        #expect(progress.contains("PetStudioPresentation.stageState"))
        #expect(!progress.contains("%"))
        #expect(!progress.contains("ProgressView(value:"))
    }

    @Test
    func configurationKeepsTwoSubpagesWithoutSizeOrDiagnosticsControls() throws {
        #expect(BehaviorSettingsSection.allCases == [.appearance, .messages])

        let source = try source("AgentPetCompanion/Views/BehaviorSettingsView.swift")
        #expect(source.contains("configuration.layout.wide"))
        #expect(source.contains("configuration.layout.compact"))
        #expect(source.contains("configuration.page.appearance"))
        #expect(source.contains("configuration.page.messages"))

        let transparency = try section(
            in: source,
            from: "private var bubbleTransparencySetting:",
            to: "private var sessionTimeoutSetting"
        )
        #expect(occurrences(of: "Slider(", in: source) == 1)
        #expect(transparency.contains("Slider("))
        #expect(transparency.contains("bubbleTransparency"))
        #expect(!source.contains("overlayScale"))
        #expect(source.contains("if shellMode == .singleContent"))
        #expect(source.contains("columns: eventGridColumns"))
        #expect(!source.contains("configuration.appearance.size-guidance"))
        #expect(!source.contains("exportDiagnostics"))
        #expect(!source.contains("ServiceDiagnosticsView"))
    }

    @Test
    func connectionsUseFullListDetailAndCompactModesWithoutDiagnosticsActions() throws {
        let source = try source("AgentPetCompanion/Views/AgentConnectionsView.swift")
        let body = try section(
            in: source,
            from: "var body: some View",
            to: "private var fullLayout"
        )
        #expect(body.contains("AgentConnectionsNextLayout.mode(for: shellMode)"))
        #expect(body.contains("fullLayout"))
        #expect(body.contains("listDetailLayout"))
        #expect(body.contains("compactLayout"))
        #expect(body.contains(".sheet(isPresented: $showingEnvironmentInspector)"))
        #expect(body.contains("connections.inspector-toggle"))

        let full = try section(
            in: source,
            from: "private var fullLayout:",
            to: "private var listDetailLayout"
        )
        #expect(full.contains("AgentConnectionList("))
        #expect(full.contains("connectionDetail"))
        #expect(full.contains("connectionInspector"))
        #expect(occurrences(of: "Divider()", in: full) == 2)
        #expect(full.contains("connections.layout.wide"))

        let listDetail = try section(
            in: source,
            from: "private var listDetailLayout:",
            to: "private var compactLayout"
        )
        #expect(listDetail.contains("AgentConnectionList("))
        #expect(listDetail.contains("connectionDetail(showsEnvironmentAction: false)"))
        #expect(!listDetail.contains("connectionInspector"))
        #expect(listDetail.contains("connections.layout.list-detail"))

        let compact = try section(
            in: source,
            from: "private var compactLayout:",
            to: "private var sourcePicker"
        )
        #expect(compact.contains("ViewThatFits(in: .horizontal)"))
        #expect(compact.contains("connectionDetail"))
        #expect(!compact.contains("connectionInspector"))
        #expect(compact.contains("connections.layout.compact"))

        #expect(source.contains("connections.operation-failure"))
        #expect(source.contains("store.sendConnectionTestEvent(source)"))
        #expect(source.contains("store.retryConnectionOperation()"))
        let listRow = try section(
            in: source,
            from: "private struct AgentConnectionListRow:",
            to: "struct ConnectionCheckDetail:"
        )
        #expect(listRow.contains(".lineLimit(2)"))
        #expect(listRow.contains(".lineLimit(3)"))
        #expect(!listRow.contains(".lineLimit(1)"))
        let globalActions = try section(
            in: source,
            from: "private var globalActions:",
            to: "private var globalActionItems"
        )
        #expect(globalActions.contains("ViewThatFits(in: .horizontal)"))
        #expect(globalActions.contains("HStack(spacing: 8)"))
        #expect(globalActions.contains("VStack(alignment: .leading, spacing: 8)"))
        #expect(!source.contains("store.exportDiagnostics()"))
        #expect(!source.contains("ServiceDiagnosticsView("))
        #expect(!source.contains("diagnostics.service-status"))
        #expect(!source.contains("diagnostics.log-package"))
    }

    @Test
    func diagnosticsAndOverlayHonorCompactAndContextualInteractionContracts() throws {
        let diagnostics = try source("AgentPetCompanion/Views/ServiceDiagnosticsView.swift")
        #expect(diagnostics.contains("@Environment(\\.controlCenterShellMode)"))
        #expect(diagnostics.contains("if shellMode == .singleContent"))
        #expect(diagnostics.contains("diagnostics.layout.single-column"))

        let overlay = try source("AgentPetCompanion/Overlay/OverlayRootView.swift")
        #expect(OverlayPetMenuPolicy.showsBubbleToggle(hasAvailableBubbleContent: true))
        #expect(!OverlayPetMenuPolicy.showsBubbleToggle(hasAvailableBubbleContent: false))
        #expect(overlay.contains("bubbleToggleAvailable: store.hasAvailableOverlayBubbleContent"))
        #expect(overlay.contains("hasAvailableBubbleContent: bubbleToggleAvailable"))
        #expect(overlay.contains(".accessibilityHidden(true)\n            .opacity(controlsVisible ? 1 : 0)"))

        let sidebar = try source("AgentPetCompanion/Views/SidebarView.swift")
        #expect(sidebar.contains("Text(UIControlSemantics.toggleValue(isOn: store.behavior.enabled))"))
        #expect(sidebar.contains(".accessibilityValue(UIControlSemantics.toggleValue(isOn: store.behavior.enabled))"))
    }

    @Test
    func connectionActionsShareOneTypedCoordinatorAndToolbarOnlyNavigates() throws {
        let store = try source("AgentPetCompanion/App/AppStore.swift")
        let content = try source("AgentPetCompanion/Views/ContentView.swift")
        let app = try source("AgentPetCompanion/App/AgentPetCompanionApp.swift")

        let operations = try section(
            in: store,
            from: "func repairConnection(",
            to: "func toggleOverlay()"
        )
        for kind in [".check", ".test", ".repair", ".uninstall"] {
            #expect(operations.contains("kind: \(kind)"))
        }
        #expect(operations.contains("connectionOperationGate.begin(operation)"))
        #expect(operations.contains("connectionOperationState = .failed"))
        #expect(operations.contains("func retryConnectionOperation()"))

        let toolbar = try section(
            in: content,
            from: ".toolbar {",
            to: ".onAppear {"
        )
        #expect(toolbar.contains("store.selection = .connections"))
        #expect(!toolbar.contains("store.checkAllConnections()"))

        #expect(occurrences(of: "store.checkAllConnections()", in: app) == 2)
        #expect(occurrences(
            of: ".disabled(store.connectionOperationState.isRunning)",
            in: app
        ) == 2)
    }

    @Test
    func diagnosticsContainsOnlyServiceAndLogPackageRegions() throws {
        let serviceSource = try source("AgentPetCompanion/Views/ServiceDiagnosticsView.swift")
        let operationalState = try source("AgentPetCompanion/App/PetCoreOperationalState.swift")
        let exportState = try source("AgentPetCompanion/App/DiagnosticsExportState.swift")
        let body = try section(
            in: serviceSource,
            from: "var body: some View",
            to: "private var serviceStatusRegion"
        )
        #expect(body.contains("serviceStatusRegion"))
        #expect(body.contains("diagnosticPackageRegion"))
        #expect(occurrences(of: "private var serviceStatusRegion", in: serviceSource) == 1)
        #expect(occurrences(of: "private var diagnosticPackageRegion", in: serviceSource) == 1)
        #expect(serviceSource.contains("diagnostics.service-status"))
        #expect(serviceSource.contains("diagnostics.log-package"))
        #expect(!serviceSource.contains("AgentConnectionsView("))
        #expect(!serviceSource.contains("BehaviorSettingsView("))
        #expect(serviceSource.contains("operationalState: PetCoreOperationalState"))
        #expect(serviceSource.contains("serviceStatusText _: String"))
        #expect(!serviceSource.contains("serviceStatusText.contains"))
        #expect(!serviceSource.contains("serviceStatusText.hasPrefix"))
        #expect(operationalState.contains("case runtimeMismatch"))
        #expect(exportState.contains("enum DiagnosticsExportState"))
        #expect(!serviceSource.contains("enum DiagnosticsExportState"))
    }

    @Test
    func aboutUsesOneWindowAndTheStandardApplicationCommand() throws {
        let app = try source("AgentPetCompanion/App/AgentPetCompanionApp.swift")
        #expect(
            occurrences(
                of: "Window(APCLocalization.text(.appActionAbout), id: \"about\")",
                in: app
            ) == 1
        )
        #expect(app.contains("CommandGroup(replacing: .appInfo)"))
        #expect(app.contains("openWindow(id: \"about\")"))

        let about = try source("AgentPetCompanion/Views/AboutView.swift")
        #expect(about.contains("about.window"))
    }

    @Test
    func persistedAppearanceGatesMainAndAboutWindowChromeBeforeReveal() throws {
        let app = try source("AgentPetCompanion/App/AgentPetCompanionApp.swift")
        let gate = try source("AgentPetCompanion/App/InitialAppearanceWindowGate.swift")

        #expect(occurrences(of: "InitialAppearanceWindowGateView(", in: app) == 2)
        #expect(gate.contains("window.alphaValue = 0"))
        #expect(gate.contains("window.ignoresMouseEvents = true"))
        #expect(gate.contains("window.appearance = appearanceName"))
        #expect(gate.contains("window.contentView?.layoutSubtreeIfNeeded()"))
        #expect(gate.contains("context.duration = 0"))
        #expect(gate.contains("hasRevealed ? .noChange : .conceal"))
    }

    @Test
    func menuBarKeepsSummaryActionsAndPrimaryShortcuts() throws {
        let app = try source("AgentPetCompanion/App/AgentPetCompanionApp.swift")
        let menuBar = try section(
            in: app,
            from: "MenuBarExtra {",
            to: "private struct AboutWindowCommands"
        )

        for identifier in [
            "menubar.summary.pet",
            "menubar.summary.agent",
            "menubar.summary.petcore",
            "menubar.open-control-center",
            "menubar.toggle-pet",
            "menubar.focus-pet-sessions",
            "menubar.focus-pet-resize",
            "menubar.check-connections",
            "menubar.quit",
        ] {
            #expect(menuBar.contains(identifier))
        }
        #expect(menuBar.contains(".keyboardShortcut(\"0\", modifiers: [.command])"))
        #expect(menuBar.contains(
            ".keyboardShortcut(\"p\", modifiers: [.command, .shift])"
        ))
        #expect(menuBar.contains(
            ".keyboardShortcut(\"b\", modifiers: [.command, .shift])"
        ))
        #expect(menuBar.contains(
            ".keyboardShortcut(\"r\", modifiers: [.command, .shift])"
        ))
        #expect(menuBar.contains("store.focusOverlayBubbleForKeyboardNavigation()"))
        #expect(menuBar.contains(".disabled(!store.canFocusOverlayBubbleForKeyboardNavigation)"))
        #expect(menuBar.contains("store.focusOverlayResizeForKeyboardNavigation()"))
        #expect(menuBar.contains(".disabled(!store.canFocusOverlayResizeForKeyboardNavigation)"))

        let commands = try section(
            in: app,
            from: "private struct ControlCenterCommands",
            to: "private enum MenuBarSummary"
        )
        #expect(commands.contains(".appActionOpenControlCenter"))
        #expect(commands.contains(".appActionTogglePet"))
        #expect(commands.contains(".appActionFocusPetSessions"))
        #expect(commands.contains(".appActionFocusPetResize"))
        #expect(commands.contains(".navigationDiagnostics"))
        #expect(commands.contains(".appActionCheckConnections"))
        #expect(commands.contains(
            ".keyboardShortcut(\"b\", modifiers: [.command, .shift])"
        ))
        #expect(commands.contains(
            ".keyboardShortcut(\"r\", modifiers: [.command, .shift])"
        ))
        #expect(commands.contains("store.focusOverlayBubbleForKeyboardNavigation()"))
        #expect(commands.contains(".disabled(!store.canFocusOverlayBubbleForKeyboardNavigation)"))
        #expect(commands.contains("store.focusOverlayResizeForKeyboardNavigation()"))
        #expect(commands.contains(".disabled(!store.canFocusOverlayResizeForKeyboardNavigation)"))
    }

    @Test
    func criticalAccessibilityIdentifiersRemainStable() throws {
        let files = [
            "AgentPetCompanion/App/AgentPetCompanionApp.swift",
            "AgentPetCompanion/Views/AboutView.swift",
            "AgentPetCompanion/Views/ContentView.swift",
            "AgentPetCompanion/Views/ControlCenterShell.swift",
            "AgentPetCompanion/Views/SidebarView.swift",
            "AgentPetCompanion/Views/PetLibraryView.swift",
            "AgentPetCompanion/Views/PetStudioView.swift",
            "AgentPetCompanion/Views/BehaviorSettingsView.swift",
            "AgentPetCompanion/Views/AgentConnectionsView.swift",
            "AgentPetCompanion/Views/ServiceDiagnosticsView.swift",
        ]
        let combined = try files.map(source).joined(separator: "\n")

        for identifier in [
            "sidebar.navigation.",
            "toolbar.toggle-pet",
            "toolbar.service-status",
            "toolbar.more",
            "pet-library.page",
            "pet-library.search",
            "pet-library.grid",
            "pet-library.inspector",
            "pet-library.inspector.activate",
            "pet-library.inspector-toggle",
            "maker.page",
            "maker.brief.description",
            "maker.brief.style",
            "maker.brief.quality",
            "maker.session",
            "maker.session.progress",
            "configuration.root",
            "configuration.layout.wide",
            "configuration.layout.compact",
            "configuration.page.appearance",
            "configuration.page.messages",
            "connections.root",
            "connections.layout.wide",
            "connections.layout.compact",
            "connections.detail",
            "connections.inspector",
            "diagnostics.page",
            "diagnostics.service-status",
            "diagnostics.log-package",
            "diagnostics.export",
            "about.window",
            "menubar.summary.pet",
            "menubar.summary.agent",
            "menubar.summary.petcore",
            "menubar.open-control-center",
            "menubar.toggle-pet",
            "menubar.focus-pet-sessions",
            "menubar.focus-pet-resize",
            "menubar.check-connections",
            "menubar.quit",
        ] {
            #expect(combined.contains(identifier))
        }
    }

    private var macOSRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: macOSRootURL
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func section(
        in source: String,
        from start: String,
        to end: String
    ) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(
            of: end,
            range: startRange.upperBound ..< source.endIndex
        ))
        return String(source[startRange.lowerBound ..< endRange.lowerBound])
    }

    private func occurrences(of needle: String, in source: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return source.components(separatedBy: needle).count - 1
    }

    private func containsInOrder(_ needles: [String], in source: String) -> Bool {
        var searchStart = source.startIndex
        for needle in needles {
            guard let range = source.range(
                of: needle,
                range: searchStart ..< source.endIndex
            ) else {
                return false
            }
            searchStart = range.upperBound
        }
        return true
    }
}
