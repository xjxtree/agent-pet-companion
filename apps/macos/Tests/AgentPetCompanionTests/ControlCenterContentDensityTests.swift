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
        #expect(!library.contains("libraryPageSubtitle"))

        #expect(maker.contains("ToolbarItemGroup(placement: .secondaryAction)"))
        #expect(!maker.contains("studioSubtitleIdle"))
        #expect(!maker.contains("studioWelcomeTitle"))
        #expect(!maker.contains("studioOutputContractTitle"))

        #expect(connections.contains("ToolbarItemGroup(placement: .secondaryAction)"))
        #expect(!connections.contains("connectionsPageSubtitle"))
        #expect(!connections.contains("Text(APCLocalization.text(.connectionsListTitle))"))
        #expect(connections.contains("case .allColumns, .sidebarAndContent: .split"))
        #expect(!connections.contains("ConnectionEnvironmentInspector"))
        #expect(!connections.contains("connections.inspector"))

        #expect(diagnostics.contains("ToolbarItem(placement: .secondaryAction)"))
        #expect(!diagnostics.contains("Text(APCLocalization.text(.diagnosticsPageTitle))"))
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
        let inspectorStart = try #require(library.range(
            of: "private struct PetLibraryInspector"
        ))
        let inspectorEnd = try #require(library.range(
            of: "struct PetCoverImage",
            range: inspectorStart.upperBound ..< library.endIndex
        ))
        let libraryInspector = String(
            library[inspectorStart.lowerBound ..< inspectorEnd.lowerBound]
        )

        #expect(!libraryInspector.contains("Text(APCLocalization.text(.libraryInspectorTitle))"))
        #expect(!libraryInspector.contains("pet-library.inspector.history-summary"))
        #expect(!libraryInspector.contains("InfoRow(title: APCLocalization.text(.libraryFieldPackageVersion)"))
        #expect(!libraryInspector.contains("InfoRow(title: APCLocalization.text(.libraryFieldStates)"))
        #expect(!libraryInspector.contains("InfoRow(title: APCLocalization.text(.libraryFieldFPS)"))
        #expect(!libraryInspector.contains("libraryFieldCurrentState"))
        #expect(!libraryInspector.contains("libraryFieldSource"))
        #expect(libraryInspector.contains("DisclosureGroup"))

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
