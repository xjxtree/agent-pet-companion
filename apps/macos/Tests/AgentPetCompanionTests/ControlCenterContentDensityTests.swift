import Foundation
import Testing

@Suite("Control Center content density")
struct ControlCenterContentDensityTests {
    @Test
    func topLevelPagesUseToolbarActionsWithoutRepeatingNavigationTitles() throws {
        let library = try viewSource("PetLibraryView.swift")
        let maker = try viewSource("PetStudioView.swift")
        let connections = try viewSource("AgentConnectionsView.swift")
        let diagnostics = try viewSource("ServiceDiagnosticsView.swift")
        let designSystem = try viewSource("DesignSystem.swift")

        #expect(library.contains(".searchable("))
        #expect(library.contains("ToolbarItemGroup(placement: .secondaryAction)"))
        #expect(library.contains("ProductPageHeader("))
        #expect(library.contains("summary: APCLocalization.text(.libraryPageSubtitle)"))

        #expect(maker.contains("ToolbarItemGroup(placement: .secondaryAction)"))
        #expect(!maker.contains("studioSubtitleIdle"))
        #expect(!maker.contains("studioWelcomeTitle"))
        #expect(!maker.contains("studioOutputContractTitle"))

        #expect(!connections.contains("ToolbarItemGroup(placement: .secondaryAction)"))
        #expect(connections.contains("ProductPageHeader("))
        #expect(connections.contains("summary: APCLocalization.text(.connectionsPageSubtitle)"))
        #expect(connections.contains("store.checkAllConnections()"))
        #expect(connections.contains("\"connections.primary.check-all\""))
        #expect(occurrences(of: ".buttonStyle(.borderedProminent)", in: connections) == 1)
        #expect(connections.contains("AgentHealthRow("))
        #expect(connections.contains("AdvancedDetailsDisclosure("))
        #expect(!connections.contains("Text(APCLocalization.text(.connectionsListTitle))"))
        #expect(!connections.contains("AgentConnectionsLayout"))
        #expect(!connections.contains("ConnectionActionBar"))
        #expect(!connections.contains("ConnectionEnvironmentInspector"))
        #expect(!connections.contains("connections.inspector"))

        #expect(!diagnostics.contains("ToolbarItem(placement: .secondaryAction)"))
        #expect(!diagnostics.contains("Text(APCLocalization.text(.diagnosticsPageTitle))"))
        #expect(diagnostics.contains("PrimaryExperienceCard("))
        #expect(diagnostics.contains("AdvancedDetailsDisclosure("))
        #expect(diagnostics.contains("recentEventSummary: nil"))
        #expect(!diagnostics.contains("store.recentEvents"))
        #expect(occurrences(
            of: "Text(APCLocalization.text(.diagnosticsLogDownload))",
            in: diagnostics
        ) == 1)

        #expect(!designSystem.contains("struct PageActionHeader"))
    }

    @Test
    func detailAndPreviewPanesDoNotRepeatTheirOwnHeadingOrSummary() throws {
        let library = try viewSource("PetLibraryView.swift")
        let maker = try viewSource("PetStudioView.swift")
        let configuration = try viewSource("BehaviorSettingsView.swift")
        let connections = try viewSource("AgentConnectionsView.swift")
        let diagnostics = try viewSource("ServiceDiagnosticsView.swift")
        let heroStart = try #require(library.range(
            of: "private struct PetLibraryHero"
        ))
        let heroEnd = try #require(library.range(
            of: "struct PetCard",
            range: heroStart.upperBound ..< library.endIndex
        ))
        let libraryHero = String(
            library[heroStart.lowerBound ..< heroEnd.lowerBound]
        )

        #expect(libraryHero.contains("PrimaryExperienceCard("))
        #expect(libraryHero.contains("PetPreviewStage("))
        #expect(libraryHero.contains("AdvancedDetailsDisclosure("))
        #expect(libraryHero.contains("presentation.technicalInformation"))
        #expect(!libraryHero.contains("pet-library.inspector.history-summary"))
        #expect(!libraryHero.contains("libraryFieldCurrentState"))

        #expect(occurrences(of: "SubmittedFormSummary(form: form)", in: maker) == 1)
        #expect(!maker.contains("Text(APCLocalization.text(.studioDescriptionRequired))"))
        #expect(!maker.contains("Text(APCLocalization.text(.studioOutputContractDetail))"))
        #expect(!maker.contains("Text(APCLocalization.text(.studioOutputPrivacy))"))
        #expect(!maker.contains("Text(APCLocalization.text(.studioReferencesContract))"))
        #expect(!maker.contains("Text(APCLocalization.text(.studioReferencesPrivacy))"))

        #expect(!configuration.contains("Text(section.subtitle)"))
        #expect(!configuration.contains("Text(event.rawValue)"))
        #expect(!configuration.contains("configLiveMessagePreview"))
        #expect(!configuration.contains("configPersistencePreview"))
        #expect(!configuration.contains("private func pageHeader"))
        #expect(!configuration.contains("Text(sourceDetail)"))
        #expect(!configuration.contains("configTimeoutPreviewFormat"))
        #expect(!configuration.contains("configPreviewSources"))
        #expect(!configuration.contains("configPreviewEvents"))

        #expect(!connections.contains("private var pageActionHeader"))
        #expect(!connections.contains("Text(APCLocalization.format(.connectionsTestDetailFormat"))
        #expect(!connections.contains("ConnectionCheckScope"))
        #expect(!connections.contains("connectionCheckCWD"))
        #expect(!connections.contains("chooseConnectionCheckDirectory"))
        #expect(!connections.contains("AgentVerificationSection"))
        #expect(!connections.contains("AgentCapabilitiesSection"))
        #expect(!connections.contains("petCoreRuntimeInfo"))
        #expect(!connections.contains("connectionsManagedDetail"))
        #expect(!connections.contains("connections.empty.check"))
        #expect(!connections.contains("connectionsSnapshotDescriptionFormat"))

        #expect(occurrences(
            of: "APCLocalization.text(.diagnosticsPackageTitle)",
            in: diagnostics
        ) == 1)
        #expect(!diagnostics.contains("DiagnosticPackageMetadataRow"))
        #expect(!diagnostics.contains("Text(presentation.status)"))
    }

    private func viewSource(_ fileName: String) throws -> String {
        try String(
            contentsOf: viewsDirectory.appendingPathComponent(fileName),
            encoding: .utf8
        )
    }

    private func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }

    private var viewsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentPetCompanion/Views", isDirectory: true)
    }
}
