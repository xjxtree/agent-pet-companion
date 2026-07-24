import Foundation
import Testing
@testable import AgentPetCompanion

@Suite("Onboarding view")
struct OnboardingViewTests {
    @Test
    func stableAccessibilityIdentifiersCoverEverySceneAndAction() throws {
        let source = try onboardingSource()
        let identifiers = [
            "onboarding.root",
            "onboarding.scene.choose-pet",
            "onboarding.scene.connect-agents",
            "onboarding.scene.demo",
            "onboarding.close",
            "onboarding.skip",
            "onboarding.primary.",
            "onboarding.pet.",
            "onboarding.pets.restore",
            "onboarding.pets.diagnostics",
            "onboarding.service.retry",
            "onboarding.demo.local",
            "onboarding.demo.phase",
            "onboarding.demo.restart",
        ]

        for identifier in identifiers {
            #expect(source.contains(identifier), "Missing \(identifier)")
        }
    }

    @Test
    func layoutAndCopyRemainUsableAtMinimumWindowAndBothLocales() throws {
        let source = try onboardingSource()
        let keys = APCLocalizationKey.allCases.filter {
            $0.rawValue.hasPrefix("onboarding.")
        }

        #expect(keys.count == 39)
        for key in keys {
            let english = APCLocalization.text(key, locale: "en")
            let chinese = APCLocalization.text(key, locale: "zh-Hans")
            #expect(!english.isEmpty)
            #expect(!chinese.isEmpty)
            #expect(english != key.rawValue)
            #expect(chinese != key.rawValue)
        }

        #expect(APCLocalization.text(.onboardingConnectDetail, locale: "en").count > 100)
        #expect(APCLocalization.text(.onboardingConnectDetail, locale: "zh-Hans").count > 35)
        #expect(
            APCLocalization.text(.onboardingPetsUnavailableTitle, locale: "en")
                == "Included companions are unavailable"
        )
        #expect(
            APCLocalization.text(.onboardingPetsUnavailableDetail, locale: "zh-Hans")
                == "恢复 App 随附的两只桌宠，然后选择一只继续。"
        )
        #expect(ControlCenterShellPolicy.supportedMinimumWindowWidth == 760)
        #expect(ControlCenterShellPolicy.supportedMinimumWindowHeight == 520)
        #expect(source.contains("ControlCenterShellPolicy.supportedMinimumWindowWidth"))
        #expect(source.contains("ControlCenterShellPolicy.supportedMinimumWindowHeight"))
        #expect(source.contains("ScrollView"))
        #expect(source.contains(".adaptive(minimum: 260"))
        #expect(source.contains("minHeight: 300, maxHeight: 360"))
        #expect(!source.contains(".lineLimit("))
        #expect(source.contains("accessibilityReduceMotion"))
    }

    @Test
    func localDemoProjectionHasNoPetCoreEventOrDiagnosticWritePath() throws {
        let viewSource = try onboardingSource()
        let modelSource = try String(
            contentsOf: macOSPackageURL
                .appendingPathComponent(
                    "Sources/AgentPetCompanionCore/OnboardingModels.swift"
                ),
            encoding: .utf8
        )
        let combined = viewSource + modelSource
        let forbidden = [
            "agent.ingest",
            "requestPetCore",
            "AgentEvent(",
            "activeAgentSessions",
            "connection_receipts",
            "suppressed_agent_sessions",
            "diagnostics.",
        ]

        for token in forbidden {
            #expect(!combined.contains(token), "Local demo contains \(token)")
        }
        #expect(viewSource.contains("@State private var demoSequence"))
        #expect(viewSource.contains("OnboardingDemoSequence()"))
        #expect(viewSource.contains("onboarding-local-demo:"))
        #expect(viewSource.contains(
            "assetWarning: store.petAssetWarningIndex[pet.id]"
        ))
        #expect(viewSource.contains(
            "PetLibraryPreviewPolicy.canRender("
        ))
        #expect(viewSource.contains("assetWarning: assetWarning"))
    }

    @Test
    func repairRequiresTypedAuthorizationAndExplicitConfirmation() throws {
        let source = try onboardingSource()

        #expect(source.contains(".confirmationDialog("))
        #expect(source.contains("presentation.canRepairManagedConnector"))
        #expect(source.contains("current.canRepairManagedConnector"))
        #expect(source.contains(
            "current.primaryAction == .connect || current.primaryAction == .repair"
        ))
        #expect(source.contains("store.repairConnection(source)"))
        #expect(!source.contains("contains(\"repair\")"))
        #expect(!source.contains("contains(\"修复\")"))
    }

    @Test
    func contentRootPresentsOnboardingOutsideTheFivePageNavigation() throws {
        let content = try String(
            contentsOf: macOSPackageURL.appendingPathComponent(
                "Sources/AgentPetCompanion/Views/ContentView.swift"
            ),
            encoding: .utf8
        )
        let app = try String(
            contentsOf: macOSPackageURL.appendingPathComponent(
                "Sources/AgentPetCompanion/App/AgentPetCompanionApp.swift"
            ),
            encoding: .utf8
        )

        #expect(content.contains("if store.shouldPresentOnboarding"))
        #expect(content.contains("OnboardingView()"))
        #expect(!content.contains("case .onboarding"))
        #expect(!app.contains("menubar.summary.petcore"))
        #expect(!app.contains("static func petCore("))
    }

    private func onboardingSource() throws -> String {
        try String(
            contentsOf: macOSPackageURL.appendingPathComponent(
                "Sources/AgentPetCompanion/Views/OnboardingView.swift"
            ),
            encoding: .utf8
        )
    }

    private var macOSPackageURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
