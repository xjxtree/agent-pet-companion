import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite
struct UIModelTests {
    @Test
    func allV1CopyKeysExistInEnglishAndChinese() throws {
        for key in APCLocalization.requiredV1Keys {
            let english = try #require(APCLocalization.localizedValue(for: key, locale: "en"))
            let chinese = try #require(APCLocalization.localizedValue(for: key, locale: "zh-Hans"))
            #expect(!english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(english != key.rawValue)
            #expect(chinese != key.rawValue)
        }
    }

    @Test
    func stringCatalogMatchesPackagedRuntimeTranslations() throws {
        for key in APCLocalization.requiredV1Keys {
            for locale in ["en", "zh-Hans"] {
                let catalog = try #require(APCLocalization.catalogValue(for: key, locale: locale))
                let runtime = try #require(APCLocalization.localizedValue(for: key, locale: locale))
                #expect(catalog == runtime)
            }
        }
    }

    @Test
    func v1InterfaceUsesTheCompleteChineseSurfaceInsteadOfMixingLocales() {
        #expect(APCLocalization.interfaceLocaleIdentifier == "zh-Hans")
        #expect(APCLocalization.text(.navigationBehavior) == "启用与行为")
        #expect(APCLocalization.text(.studioTabLibrary) == "宠物库")
    }

    @Test
    func eventAndSourceControlsHaveDistinctLabels() {
        let sourceLabels = AgentSource.allCases.map(UIControlSemantics.sourceLabel)
        let eventLabels = AgentEventKind.allCases.map(UIControlSemantics.eventLabel)

        #expect(Set(sourceLabels).count == AgentSource.allCases.count)
        #expect(Set(eventLabels).count == AgentEventKind.allCases.count)
        for (source, label) in zip(AgentSource.allCases, sourceLabels) {
            #expect(label.contains(source.title))
        }
        for (event, label) in zip(AgentEventKind.allCases, eventLabels) {
            #expect(label.contains(event.title))
        }
        #expect(UIControlSemantics.toggleValue(isOn: true) != UIControlSemantics.toggleValue(isOn: false))
    }

    @Test
    func connectionGridIsTopAligned() throws {
        let overview = try #require(ConnectionGridLayout.overviewColumns.first)
        let cards = try #require(ConnectionGridLayout.cardColumns.first)
        #expect(overview.alignment == .top)
        #expect(cards.alignment == .top)
    }

    @Test
    func studioAdaptiveColumnsDependOnContainerWidthNotTextContent() {
        #expect(AdaptiveTwoColumnLayout.usesColumns(
            availableWidth: 760,
            minimumColumnWidth: 300,
            spacing: 18
        ))
        #expect(!AdaptiveTwoColumnLayout.usesColumns(
            availableWidth: 600,
            minimumColumnWidth: 300,
            spacing: 18
        ))
    }

    @Test
    func libraryUsesValidationSummary() {
        let pet = makePet(id: "pet_warning", active: true)
        let warning = PetAssetWarning(
            petId: pet.id,
            code: "pet_assets_invalid",
            fingerprint: "sha256:test",
            message: "idle frame is corrupt"
        )
        let invalid = PetLibraryPresentation(pet: pet, assetWarning: warning)
        let unverified = PetLibraryPresentation(pet: pet, assetWarning: nil)

        #expect(invalid.validationStatus == .invalid)
        #expect(invalid.validationDetail.contains("idle frame is corrupt"))
        #expect(unverified.validationStatus == .notFullyReported)
        #expect(unverified.validationTitle == "规格未完整报告")
        #expect(unverified.validationTitle.count < unverified.validationDetail.count)
        #expect(!unverified.validationDetail.contains("资源完整"))
        #expect(unverified.stateSpecification == nil)
        #expect(unverified.fpsSpecification == nil)
    }

    @Test
    func daemonAssetWarningsDecodeAndIndexByPetID() throws {
        let data = Data(#"[{"pet_id":"pet_a","code":"pet_assets_invalid","fingerprint":"sha256:a","message":"broken frame"}]"#.utf8)
        let warnings = try JSONDecoder().decode([PetAssetWarning].self, from: data)
        let index = PetAssetWarningIndex(warnings)

        #expect(index["pet_a"]?.message == "broken frame")
        #expect(index["pet_missing"] == nil)
    }

    @Test
    func importAcceptsOnlyPetpack() {
        #expect(PetpackImportPolicy.contentType.identifier == "dev.agentpet.petpack")
        #expect(PetpackImportPolicy.acceptsFileName("Cloud.petpack"))
        #expect(PetpackImportPolicy.acceptsFileName("Cloud.PETPACK"))
        #expect(!PetpackImportPolicy.acceptsFileName("Cloud.petdex"))
        #expect(!PetpackImportPolicy.acceptsFileName("Cloud.zip"))
        #expect(!PetpackImportPolicy.acceptsFileName("petpack"))
    }

    @Test
    func nonActivePetDoesNotShowGlobalEvent() {
        let event = AgentEvent(
            id: "evt_global",
            source: .codex,
            eventType: .tool,
            title: "执行工具",
            detail: nil,
            createdAt: "2026-07-10T00:00:00Z"
        )
        let inactive = PetLibraryPresentation(
            pet: makePet(id: "pet_inactive", active: false),
            assetWarning: nil
        )
        let active = PetLibraryPresentation(
            pet: makePet(id: "pet_active", active: true),
            assetWarning: nil
        )

        #expect(inactive.currentStateTitle(activeEvent: event) == nil)
        #expect(active.currentStateTitle(activeEvent: event) == event.eventType.title)
    }

    @Test
    func semanticTokensResolveInEveryAppearanceMode() throws {
        let appearances: [NSAppearance.Name] = [
            .aqua,
            .darkAqua,
            .accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua
        ]
        for token in APCSemanticColorToken.allCases {
            for appearance in appearances {
                let color = try #require(APCDesign.resolvedColor(token, appearance: appearance))
                #expect(color.alphaComponent > 0)
            }
        }
    }

    private func makePet(id: String, active: Bool) -> PetSummary {
        PetSummary(
            id: id,
            name: id,
            style: "半写实",
            quality: .high,
            renderSize: RenderSize(width: 384, height: 416),
            petpackPath: "/tmp/\(id).petpack",
            coverPath: "/tmp/\(id).webp",
            active: active,
            createdAt: "2026-07-10T00:00:00Z"
        )
    }
}
