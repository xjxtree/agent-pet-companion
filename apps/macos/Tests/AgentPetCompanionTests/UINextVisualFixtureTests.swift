import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("UI Next repeatable visual fixtures")
struct UINextVisualFixtureTests {
    @Test
    func fixtureIsolationUsesAnUnreachablePetCoreSocketAndDisablesAllHitTesting() async {
        #expect(UINextVisualFixtureIsolation.allowsHitTesting == false)
        #expect(
            UINextVisualFixtureIsolation.petCoreSocketPath
                == "/dev/null/agent-pet-companion-ui-next-fixture.sock"
        )

        let client = UINextVisualFixtureIsolation.petCoreClient
        #expect(client.socketPath == UINextVisualFixtureIsolation.petCoreSocketPath)
        do {
            _ = try await client.requestData(
                method: "petcore.health",
                timeout: .milliseconds(50)
            )
            Issue.record("The UI Next fixture unexpectedly reached a PetCore socket")
        } catch {
            #expect(error is PetCoreTransportError)
        }
    }

    @Test
    func fixturePetsUseClosedBundledIdentityAndRemainReadOnly() {
        let pets = UINextVisualFixtureData.pets

        #expect(pets.map(\.id) == ["pet_xingwutuanzi", "pet_bytebudcodex"])
        #expect(pets.allSatisfy { $0.isBundled })
        #expect(pets.allSatisfy { $0.origin == .verifiedSkillSource })
        #expect(pets.allSatisfy {
            $0.generator == "agent-pet-companion.release-inventory"
        })
        #expect(pets.allSatisfy { $0.provenance == "apc.bundled-pets.v1" })
        #expect(pets.allSatisfy { pet in
            let permissions = PetLibraryCapabilities(pet: pet)
            return permissions.isBundled
                && !permissions.canModify
                && !permissions.canDelete
                && permissions.canCustomizeAsCopy
        })
    }

    @Test
    func fixtureConnectionsUseExplicitNonDestructiveManagementCapabilities() {
        let connections = UINextVisualFixtureData.connections

        #expect(connections.map(\.source) == AgentSource.allCases)
        #expect(connections.allSatisfy { $0.capabilities.hasReportedCapabilities })
        let managementCapabilitiesAreExplicit = connections.allSatisfy { status in
            status.capabilities.repairableConnectorIssue == false
                && status.capabilities.managedPathConflict == false
                && status.capabilities.canUninstallManagedConnector == false
        }
        #expect(managementCapabilitiesAreExplicit)
        #expect(connections.allSatisfy { !$0.hasRepairableConnectorIssue })
        #expect(connections.allSatisfy { !$0.hasManagedPathConflict })
        #expect(connections.allSatisfy { !$0.canUninstallManagedConnector })
    }

    @Test
    func connectionProfilesUseTypedChecksOperationsAndDirectoryRecovery() throws {
        let connectionScenarios = UINextVisualFixtureCatalog.regressionScenarios.filter {
            $0.rootSection == .connections
        }

        #expect(Set(connectionScenarios.map(\.connectionProfile))
            == Set(UINextConnectionFixtureProfile.allCases))
        #expect(connectionScenarios.contains { $0.width == 760 })
        #expect(connectionScenarios.contains { $0.width == 880 })
        #expect(connectionScenarios.contains { $0.width == 1_440 })
        #expect(connectionScenarios.filter { $0.connectionProfile != .full }.allSatisfy {
            $0.width == 760 || $0.width == 880
        })

        for scenario in connectionScenarios {
            let profile = scenario.connectionProfile
            let connections = UINextVisualFixtureData.connections(
                for: profile,
                selectedSource: scenario.agentSource
            )
            let selected = try #require(connections.first {
                $0.source == scenario.agentSource
            })

            #expect(selected.checkMode == profile.checkMode)
            #expect(selected.items.map(\.status) == [profile.expectedCheckStatus])

            switch profile {
            case .full, .busy, .failure:
                #expect(selected.items.map(\.code) == [.eventDelivery])
            case .light, .missing:
                #expect(selected.items.map(\.code) == [.agentCLI])
            case .needsFix:
                #expect(selected.items.map(\.code) == [.managedConnector])
                #expect(selected.items.map(\.recoveryAction) == [.confirmManagedRepair])
                #expect(selected.hasRepairableConnectorIssue)
            case .unverified:
                #expect(selected.items.map(\.code) == [.hostVerification])
                #expect(selected.items.map(\.recoveryAction) == [.testChannel])
                #expect(selected.verification.status == .unverified)
            case .unsupported:
                #expect(selected.items.map(\.code) == [.hostRuntime])
            case .invalidDirectory:
                #expect(selected.items.map(\.code) == [.projectDirectory])
                #expect(selected.items.map(\.recoveryAction) == [.chooseProjectDirectory])
                #expect(selected.verification.checkedCWD
                    == UINextVisualFixtureData.invalidProjectDirectoryPath)
                #expect(UINextVisualFixtureData.connectionCheckCWD(for: profile)
                    == UINextVisualFixtureData.invalidProjectDirectoryPath)
            }

            let operationState = UINextVisualFixtureData.connectionOperationState(
                for: profile,
                selectedSource: scenario.agentSource
            )
            switch (profile.operationPresentation, operationState) {
            case (.idle, .idle):
                break
            case let (.busy, .running(operation)):
                #expect(operation.kind == .check)
                #expect(operation.sources == [scenario.agentSource])
            case let (.failure, .failed(failure)):
                #expect(failure.operation.kind == .repair)
                #expect(failure.operation.sources == [scenario.agentSource])
                #expect(failure.reason == .partialFailure)
            default:
                Issue.record("Connection fixture operation state does not match its typed profile")
            }
        }
    }

    @Test
    func baselineCatalogCoversEveryRequiredSurfaceExactlyOnce() {
        let fixtures = UINextVisualFixtureCatalog.baselineScenarios

        #expect(Set(fixtures.map(\.id)).count == fixtures.count)
        #expect(fixtures.count == NavigationSection.allCases.count + 2 + 7)
        #expect(fixtures.compactMap(\.rootSection) == NavigationSection.allCases)
        #expect(fixtures.filter { $0.surface == .about }.count == 1)
        #expect(fixtures.filter { $0.surface == .menuBarExtra }.count == 1)
        #expect(
            fixtures.compactMap(\.overlayState) == UINextOverlayFixtureState.allCases
        )
        #expect(UINextOverlayFixtureState.allCases.map(\.eventKind) == [
            nil,
            .start,
            .tool,
            .waiting,
            .review,
            .done,
            .failed,
        ])
    }

    @MainActor
    @Test
    func minimumWindowAcceptanceCatalogCoversEveryRootWithPairwiseDisplayAxes() {
        let scenarios = UINextVisualFixtureCatalog.minimumWindowAcceptanceScenarios

        #expect(scenarios.map(\.id) == [
            "acceptance.minimum-window.library",
            "acceptance.minimum-window.maker",
            "acceptance.minimum-window.configuration",
            "acceptance.minimum-window.connections",
            "acceptance.minimum-window.diagnostics",
        ])
        #expect(scenarios.compactMap(\.rootSection) == NavigationSection.allCases)
        #expect(scenarios.allSatisfy { $0.width == 760 && $0.height == 520 })
        #expect(Set(scenarios.map(\.localeIdentifier)) == ["en", "zh-Hans"])
        #expect(Set(scenarios.map(\.displayScale)) == [1, 2])
        #expect(Set(scenarios.map(\.theme)) == [.light, .dark])

        let binaryAxisPairs = scenarios.map {
            "\($0.localeIdentifier)|\(Int($0.displayScale))|\($0.theme)"
        }
        #expect(binaryAxisPairs.contains("en|1|light"))
        #expect(binaryAxisPairs.contains("en|2|dark"))
        #expect(binaryAxisPairs.contains("zh-Hans|1|dark"))
        #expect(binaryAxisPairs.contains("zh-Hans|2|light"))

        for scenario in scenarios {
            _ = UINextVisualFixtureView(scenario: scenario)
        }
    }

    @Test
    func regressionCatalogKeepsEveryRequiredMatrixAxisTypedAndBounded() {
        #expect(UINextVisualFixtureCatalog.windowWidths == [760, 880, 1_120, 1_440])
        #expect(UINextVisualFixtureCatalog.themes == AppearanceTheme.allCases)
        #expect(UINextVisualFixtureCatalog.localeIdentifiers == ["en", "zh-Hans"])
        #expect(UINextVisualFixtureCatalog.displayScales == [1, 2])
        #expect(UINextVisualFixtureCatalog.accessibilityModes == [
            .standard,
            .reduceTransparency,
            .increasedContrast,
            .reduceMotion,
        ])
        #expect(UINextVisualFixtureCatalog.serviceStates == [
            .checking,
            .recovering,
            .online,
            .offline,
            .runtimeMismatch,
            .error,
        ])
        #expect(UINextVisualFixtureCatalog.agentSources == AgentSource.allCases)
        #expect(UINextVisualFixtureCatalog.activeSessionCounts == [0, 1, 8])
        #expect(UINextVisualFixtureCatalog.configurationSections == BehaviorSettingsSection.allCases)
        #expect(UINextVisualFixtureCatalog.connectionProfiles
            == UINextConnectionFixtureProfile.allCases)

        #expect(UINextVisualFixtureCatalog.windowWidths.allSatisfy { $0 >= 760 })
        #expect(UINextVisualFixtureCatalog.displayScales.allSatisfy { $0 == 1 || $0 == 2 })
        #expect(UINextVisualFixtureCatalog.activeSessionCounts.allSatisfy { (0 ... 8).contains($0) })
    }

    @Test
    func rootFixturesResolvePersistedSubpagesAndSourcesDeterministically() {
        let configurationScenarios = (
            UINextVisualFixtureCatalog.baselineScenarios
                + UINextVisualFixtureCatalog.regressionScenarios
        ).filter { $0.rootSection == .configuration }

        #expect(BehaviorSettingsSection.allCases.allSatisfy { section in
            configurationScenarios.contains { $0.configurationSection == section }
        })

        let connectionScenario = UINextVisualFixtureCatalog.regressionScenarios.first {
            $0.rootSection == .connections
        }
        #expect(connectionScenario?.agentSource == .opencode)
        #expect(connectionScenario?.fixtureSelections.connectionSource == .opencode)
    }

    @MainActor
    @Test
    func regressionScenariosConsumeEveryDeclaredAxisInRenderableFixtures() {
        let scenarios = UINextVisualFixtureCatalog.regressionScenarios

        #expect(!scenarios.isEmpty)
        #expect(Set(scenarios.map(\.id)).count == scenarios.count)
        #expect(scenarios.allSatisfy {
            (320 ... 1_440).contains($0.width)
                && (240 ... 900).contains($0.height)
                && (0 ... 8).contains($0.activeSessionCount)
        })

        #expect(UINextVisualFixtureCatalog.windowWidths.allSatisfy { width in
            scenarios.contains { $0.width == width && $0.rootSection != nil }
        })
        #expect(UINextVisualFixtureCatalog.themes.allSatisfy { theme in
            scenarios.contains { $0.theme == theme }
        })
        #expect(UINextVisualFixtureCatalog.localeIdentifiers.allSatisfy { locale in
            scenarios.contains { $0.localeIdentifier == locale }
        })
        #expect(UINextVisualFixtureCatalog.displayScales.allSatisfy { scale in
            scenarios.contains { $0.displayScale == scale }
        })
        #expect(UINextVisualFixtureCatalog.accessibilityModes.allSatisfy { mode in
            scenarios.contains { $0.accessibilityMode == mode }
        })
        #expect(UINextVisualFixtureCatalog.serviceStates.allSatisfy { state in
            scenarios.contains { $0.serviceState == state && $0.overlayState == nil }
        })
        #expect(UINextVisualFixtureCatalog.agentSources.allSatisfy { source in
            scenarios.contains { $0.agentSource == source && $0.overlayState != nil }
        })
        #expect(UINextVisualFixtureCatalog.activeSessionCounts.allSatisfy { count in
            scenarios.contains { $0.activeSessionCount == count && $0.overlayState != nil }
        })
        #expect(UINextVisualFixtureCatalog.connectionProfiles.allSatisfy { profile in
            scenarios.contains {
                $0.rootSection == .connections && $0.connectionProfile == profile
            }
        })

        // Construct every view to ensure the catalog only contains surfaces
        // that the DEBUG fixture renderer can actually consume.
        for scenario in scenarios {
            _ = UINextVisualFixtureView(scenario: scenario)
        }
    }

    @MainActor
    @Test
    func editSheetAndRunningModificationRegressionsKeepTypedContracts() throws {
        let editScenario = try #require(
            UINextVisualFixtureCatalog.regressionScenarios.first {
                $0.id == "regression.library.edit-sheet"
            }
        )
        #expect(editScenario.surface == .libraryEditSheet)

        let pet = UINextVisualFixtureData.editableBytebud
        let permissions = PetLibraryCapabilities(pet: pet)
        #expect(!pet.isBundled)
        #expect(pet.origin == .generatedByPetcoreJob)
        #expect(permissions.canModify)
        #expect(permissions.canDelete)
        #expect(!permissions.canCustomizeAsCopy)

        let history = UINextVisualFixtureData.editableBytebudHistory
        #expect(history.petID == pet.id)
        #expect(history.currentRevisionID == pet.revisionID)
        #expect(history.revisions.count == 2)
        #expect(history.revisions.filter(\.current).map(\.revisionID)
            == ["rev_fixture_bytebud_current"])
        let completedModification = try #require(history.jobs.first)
        #expect(completedModification.status == .completed)
        #expect(completedModification.operation == .modify)
        #expect(completedModification.baselineRevisionID == "rev_fixture_bytebud_previous")
        #expect(completedModification.revisionID == history.currentRevisionID)

        let makerScenario = try #require(
            UINextVisualFixtureCatalog.regressionScenarios.first {
                $0.id == "regression.maker.modification-running"
            }
        )
        #expect(makerScenario.surface == .root(.maker))
        #expect(makerScenario.makerSession == .modifyingRunning)

        let restore = try #require(
            UINextVisualFixtureData.generationRestore(for: makerScenario.makerSession)
        )
        #expect(restore.state == .running)
        #expect(restore.operation == .modify)
        #expect(restore.resultPetID == pet.id)
        #expect(restore.baselineRevisionID == history.currentRevisionID)
        #expect(restore.resultRevisionID == nil)
        #expect(restore.submittedForm != nil)
        #expect(restore.messages.count == 2)
        #expect(restore.progress > 0 && restore.progress < 1)

        let reselectionScenario = try #require(
            UINextVisualFixtureCatalog.regressionScenarios.first {
                $0.id == "regression.maker.failed-reference-reselection"
            }
        )
        let reselectionRestore = try #require(
            UINextVisualFixtureData.generationRestore(for: reselectionScenario.makerSession)
        )
        #expect(reselectionRestore.state == .failed)
        #expect(reselectionRestore.referenceReselectionCount == 2)
        #expect(reselectionRestore.submittedForm?.referenceImages.isEmpty == true)

        let reselectionStore = UINextVisualFixtureView.makeStore(for: reselectionScenario)
        #expect(reselectionStore.generationSession.canRetry)
        #expect(reselectionStore.referenceReselectionCount == 2)
        #expect(!reselectionStore.canRetryGeneration)
        #expect(reselectionStore.referenceImageIssue == .reselectionRequired(2))

        // Direct construction is the contract that these typed scenarios are
        // consumable by the production-root fixture surface.
        _ = UINextVisualFixtureView(scenario: editScenario)
        _ = UINextVisualFixtureView(scenario: makerScenario)
        _ = UINextVisualFixtureView(scenario: reselectionScenario)
    }

    @Test
    func overlayAcceptanceCatalogNamesMultiSessionAndPointerStatesExplicitly() {
        let scenarios = UINextVisualFixtureCatalog.overlayAcceptanceScenarios

        #expect(scenarios.map(\.id) == [
            "acceptance.overlay.multisession-stacked",
            "acceptance.overlay.multisession-expanded",
            "acceptance.overlay.multi-agent-mixed",
            "acceptance.overlay.hover-controls",
            "acceptance.overlay.resize-active",
        ])
        #expect(scenarios.map(\.overlayGroupPresentation) == [
            .stacked,
            .expanded,
            .automatic,
            .stacked,
            .stacked,
        ])
        #expect(scenarios.map(\.overlayControlPresentation) == [
            .resting,
            .resting,
            .resting,
            .hovered,
            .resizing,
        ])
        #expect(scenarios.map(\.overlayContentProfile) == [
            .singleAgent,
            .singleAgent,
            .mixedAgents,
            .singleAgent,
            .singleAgent,
        ])
        #expect(scenarios.allSatisfy { $0.overlayState == .tool })
        #expect(scenarios.prefix(2).allSatisfy { $0.activeSessionCount == 8 })
        #expect(scenarios.suffix(2).allSatisfy { $0.activeSessionCount == 2 })
    }

    @Test
    func mixedAgentFixtureUsesProductionGroupingAttentionAndOmittedSemantics() throws {
        let contents = UINextVisualFixtureData.mixedAgentBubbleContents

        #expect(contents.map(\.source) == [.codex, .claudeCode, .pi, nil])
        #expect(contents.dropLast().flatMap(\.sessions).count == 8)

        let codex = try #require(contents.first)
        #expect(codex.sessions.count == 3)
        #expect(codex.sessions.allSatisfy { $0.eventType == .tool })
        #expect(codex.isStacked)
        #expect(!codex.isExpanded)
        #expect(codex.visibleSessions.count == 1)

        let claude = try #require(contents.dropFirst().first)
        #expect(claude.sessions.count == 3)
        #expect(claude.sessions.allSatisfy { $0.eventType == .waiting })
        #expect(claude.isExpanded)
        #expect(!claude.isStacked)
        #expect(claude.visibleSessions.count == 3)

        let pi = try #require(contents.dropFirst(2).first)
        #expect(pi.sessions.count == 2)
        #expect(pi.sessions.allSatisfy { $0.eventType == .failed })
        #expect(!pi.isExpanded)
        #expect(pi.isStacked)
        #expect(pi.visibleSessions.count == 2)

        let omitted = try #require(contents.last)
        #expect(omitted.isOmittedSummary)
        #expect(omitted.omittedSessionCount == 3)
        #expect(omitted.representedSessionCount == 3)
        #expect(!omitted.canDismiss)

        let measurementSize = CGSize(width: 376, height: 680)
        let stackSize = OverlayGeometry.resolvedBubbleStackSize(
            in: measurementSize,
            contents: contents
        )
        let rects = OverlayGeometry.bubbleRects(
            inPanelSize: stackSize,
            visibleFrameSize: measurementSize,
            contents: contents,
            alignLeft: true
        )
        let stackBounds = CGRect(origin: .zero, size: stackSize)
        #expect(stackSize.width <= measurementSize.width)
        #expect(stackSize.height <= 672)
        #expect(rects.count == contents.count)
        #expect(rects.allSatisfy { stackBounds.contains($0) })
    }

    @Test
    func nonAttentionMultiSessionFixtureUsesProductionStackAndExpansionSemantics() throws {
        let stacked = OverlayCoreFixtureModel(
            state: .tool,
            source: .codex,
            requestedActiveSessionCount: 8,
            groupPresentation: .stacked
        )
        let expanded = OverlayCoreFixtureModel(
            state: .tool,
            source: .codex,
            requestedActiveSessionCount: 8,
            groupPresentation: .expanded
        )
        let stackedContent = try #require(stacked.bubbleContent)
        let expandedContent = try #require(expanded.bubbleContent)

        #expect(stackedContent.sessions.allSatisfy { $0.eventType == .tool })
        #expect(stackedContent.sessionCount == 8)
        #expect(stackedContent.visibleSessions.count == 1)
        #expect(stackedContent.isStacked)
        #expect(stackedContent.stackDecorationDepth == OverlayGeometry.bubbleCollapsedStackDepth)
        #expect(expandedContent.sessionCount == 8)
        #expect(expandedContent.visibleSessions.count == 8)
        #expect(!expandedContent.isStacked)
        #expect(expandedContent.stackDecorationDepth == 0)

        #expect(UINextOverlayControlFixturePresentation.resting.controlsVisible == false)
        #expect(UINextOverlayControlFixturePresentation.hovered.controlsVisible)
        #expect(UINextOverlayControlFixturePresentation.resizing.controlsVisible)
        #expect(!UINextOverlayControlFixturePresentation.hovered.showsScaleValue)
        #expect(UINextOverlayControlFixturePresentation.resizing.showsScaleValue)
        #expect(OverlayGeometry.menuVisualSize == CGSize(width: 24, height: 24))
        #expect(OverlayGeometry.menuHitSize == CGSize(width: 38, height: 38))
        #expect(OverlayGeometry.resizeVisualSize == CGSize(width: 24, height: 24))
        #expect(OverlayGeometry.resizeHitSize == CGSize(width: 38, height: 38))
    }
}
