import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("UI Next pet library")
struct PetLibraryNextTests {
    @Test
    func initialSnapshotLoadingNeverMasqueradesAsAnEmptyLibrary() {
        #expect(PetLibraryContentState.resolve(
            hasLoadedStateSnapshot: false,
            petCount: 0,
            filteredPetCount: 0
        ) == .loading)
        #expect(PetLibraryContentState.resolve(
            hasLoadedStateSnapshot: true,
            petCount: 0,
            filteredPetCount: 0
        ) == .empty)
        #expect(PetLibraryContentState.resolve(
            hasLoadedStateSnapshot: true,
            petCount: 2,
            filteredPetCount: 0
        ) == .searchEmpty)
        #expect(PetLibraryContentState.resolve(
            hasLoadedStateSnapshot: true,
            petCount: 2,
            filteredPetCount: 2
        ) == .results)
    }

    @Test
    func presentationExposesCapabilitiesAndImmutableRevisionContract() {
        let bundled = PetLibraryPresentation(
            pet: makeBundledPet(),
            assetWarning: nil,
            localeIdentifier: "zh-Hans"
        )
        #expect(bundled.isBundled)
        #expect(!bundled.canModify)
        #expect(!bundled.canDelete)
        #expect(bundled.canCustomizeAsCopy)
        #expect(bundled.sourceBadge.tone == .bundled)
        #expect(bundled.sourceBadge.systemImage == "shippingbox.fill")
        #expect(bundled.validationSummary.contains(bundled.validationTitle))
        #expect(bundled.revisionIDSummary == "rev_00000000000000000000000000000001")
        #expect(bundled.revisionCountSummary == "2 个")
        #expect(bundled.revisionSummary.contains("App 内置只读基线"))
        #expect(bundled.stateSummary == "idle · start · tool · waiting · review · done · failed")
        #expect(bundled.fpsSummary == "标准 12 FPS · 流畅 20 FPS")

        let imported = PetLibraryPresentation(
            pet: makePet(
                id: "pet_custom",
                name: "同名宠物",
                origin: .externalImport,
                revisionID: "rev_00000000000000000000000000000002",
                revisionCount: 3
            ),
            assetWarning: nil,
            localeIdentifier: "zh-Hans"
        )
        #expect(!imported.isBundled)
        #expect(imported.canModify)
        #expect(imported.canDelete)
        #expect(!imported.canCustomizeAsCopy)
        #expect(imported.sourceBadge.tone == .external)
        #expect(imported.revisionSummary.contains("rev_00000000000000000000000000000002"))
        #expect(imported.revisionSummary.contains("3 个"))
        #expect(imported.revisionSummary.contains("同一 ID 的新 revision"))

        let nonOwned = PetLibraryPresentation(
            pet: makePet(id: "pet_external", name: "外部包", origin: .externalImport),
            assetWarning: nil,
            localeIdentifier: "zh-Hans"
        )
        #expect(nonOwned.revisionIDSummary == "未提供（非 PetCore 自有）")
        #expect(nonOwned.revisionCountSummary == "0 个（非 PetCore 自有）")
    }

    @Test
    func bundledCopyDraftUsesANewStableIDAndPreservesCreationSettings() {
        let pet = makeBundledPet()
        let draft = PetLibraryCopyDraft.make(
            for: pet,
            existingPetIDs: Set([pet.id, "pet_xingwutuanzicopy"]),
            localeIdentifier: "zh-Hans"
        )

        #expect(draft.suggestedID == "pet_xingwutuanzicopy2")
        #expect(draft.suggestedID != pet.id)
        #expect(draft.brief.contains("新的稳定宠物 ID：pet_xingwutuanzicopy2"))
        #expect(draft.brief.contains("不得覆盖或复用原 ID"))
        #expect(draft.style == .semiRealistic)
        #expect(draft.quality == pet.quality)
    }

    @Test
    func libraryCopyAndSourcePresentationSupportExplicitEnglishAndChinese() {
        let bundled = makeBundledPet()
        let englishDraft = PetLibraryCopyDraft.make(
            for: bundled,
            existingPetIDs: [bundled.id],
            localeIdentifier: "en"
        )
        let chineseDraft = PetLibraryCopyDraft.make(
            for: bundled,
            existingPetIDs: [bundled.id],
            localeIdentifier: "zh-Hans"
        )

        #expect(englishDraft.brief.contains("new stable pet ID: \(englishDraft.suggestedID)"))
        #expect(chineseDraft.brief.contains("新的稳定宠物 ID：\(chineseDraft.suggestedID)"))
        #expect(englishDraft.brief.contains(bundled.id))
        #expect(chineseDraft.brief.contains(bundled.id))

        let imported = makePet(id: "pet_external", name: "Same", origin: .externalImport)
        let english = PetLibraryPresentation(
            pet: imported,
            assetWarning: nil,
            localeIdentifier: "en"
        )
        let chinese = PetLibraryPresentation(
            pet: imported,
            assetWarning: nil,
            localeIdentifier: "zh-Hans"
        )
        #expect(english.sourceTitle == "Imported")
        #expect(chinese.sourceTitle == "外部导入")
        #expect(english.revisionIDSummary == "Not provided (not PetCore-owned)")
        #expect(chinese.revisionIDSummary == "未提供（非 PetCore 自有）")
    }

    @Test
    func cardAccessibilityLabelsKeepMeaningAndDisambiguateStableManifestIDs() {
        let firstPet = makePet(
            id: "pet_same_name_alpha",
            name: "Same Name",
            origin: .externalImport
        )
        let secondPet = makePet(
            id: "pet_same_name_beta",
            name: firstPet.name,
            origin: firstPet.origin
        )

        for localeIdentifier in ["en", "zh-Hans"] {
            let firstSource = PetLibraryPresentation(
                pet: firstPet,
                assetWarning: nil,
                localeIdentifier: localeIdentifier
            ).sourceTitle
            let secondSource = PetLibraryPresentation(
                pet: secondPet,
                assetWarning: nil,
                localeIdentifier: localeIdentifier
            ).sourceTitle
            #expect(firstSource == secondSource)

            let first = PetCardAccessibilityPresentation(
                name: firstPet.name,
                sourceTitle: firstSource,
                stableID: firstPet.id,
                isActive: false,
                localeIdentifier: localeIdentifier
            )
            let second = PetCardAccessibilityPresentation(
                name: secondPet.name,
                sourceTitle: secondSource,
                stableID: secondPet.id,
                isActive: false,
                localeIdentifier: localeIdentifier
            )

            #expect(first.label != second.label)
            #expect(first.label.contains(firstPet.name))
            #expect(first.label.contains(firstSource))
            #expect(first.label.contains(firstPet.id))
            #expect(!first.label.contains(secondPet.id))
            #expect(second.label.contains(secondPet.name))
            #expect(second.label.contains(secondSource))
            #expect(second.label.contains(secondPet.id))
            #expect(!second.label.contains(firstPet.id))
        }

        let english = PetCardAccessibilityPresentation(
            name: firstPet.name,
            sourceTitle: "Imported",
            stableID: firstPet.id,
            isActive: false,
            localeIdentifier: "en"
        )
        let chinese = PetCardAccessibilityPresentation(
            name: firstPet.name,
            sourceTitle: "外部导入",
            stableID: firstPet.id,
            isActive: false,
            localeIdentifier: "zh-Hans"
        )
        #expect(english.label.hasPrefix("Select pet "))
        #expect(english.label.contains("Stable pet ID: \(firstPet.id)"))
        #expect(chinese.label.hasPrefix("选择宠物 "))
        #expect(chinese.label.contains("稳定宠物 ID：\(firstPet.id)"))
    }

    @Test
    func cardAccessibilityOnlyOffersActivationForInactivePets() {
        for localeIdentifier in ["en", "zh-Hans"] {
            let inactive = PetCardAccessibilityPresentation(
                name: "Same Name",
                sourceTitle: "Imported",
                stableID: "pet_same_name_alpha",
                isActive: false,
                localeIdentifier: localeIdentifier
            )
            let active = PetCardAccessibilityPresentation(
                name: "Same Name",
                sourceTitle: "Imported",
                stableID: "pet_same_name_alpha",
                isActive: true,
                localeIdentifier: localeIdentifier
            )

            #expect(inactive.activateActionName == APCLocalization.text(
                .libraryActivateAccessibility,
                locale: localeIdentifier
            ))
            #expect(active.activateActionName == nil)
            #expect(active.label == inactive.label)
        }
    }

    @MainActor
    @Test
    func preparingBundledCopyResetsMakerDraftWithoutStartingAJob() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apc-library-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cover = directory.appendingPathComponent("cover.png")
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        let png = try #require(bitmap?.representation(using: .png, properties: [:]))
        try png.write(to: cover)

        var bundled = makeBundledPet()
        bundled.coverPath = cover.path
        let occupiedCopy = makePet(
            id: "pet_xingwutuanzicopy",
            name: "已有副本",
            origin: .externalImport
        )
        let store = makeStore()
        store.pets = [bundled, occupiedCopy]
        store.updateGenerationDescription("旧草稿")
        let diagnosticsState = store.diagnosticsExportState

        store.preparePetCustomizationCopy(bundled)

        #expect(store.selection == .maker)
        #expect(store.descriptionText.contains("pet_xingwutuanzicopy2"))
        #expect(store.selectedStyle == .semiRealistic)
        #expect(store.selectedQuality == bundled.quality)
        #expect(store.referenceImages == [cover.standardizedFileURL.path])
        #expect(store.generationSession.state == .idle)
        #expect(store.generationSession.jobID == nil)
        #expect(store.diagnosticsExportState == diagnosticsState)

        let linkedCover = directory.appendingPathComponent("linked-cover.png")
        try FileManager.default.createSymbolicLink(at: linkedCover, withDestinationURL: cover)
        var symlinkedBundled = bundled
        symlinkedBundled.coverPath = linkedCover.path
        store.preparePetCustomizationCopy(symlinkedBundled)
        #expect(store.referenceImages.isEmpty)
    }

    @Test
    func transportProjectionDecodesRevisionMetadataAndLegacyDefaults() throws {
        let current = try JSONDecoder().decode(
            PetSummary.self,
            from: Data(
                #"{"id":"pet_current","name":"Current","style":"pixel","quality":"high","render_size":{"width":384,"height":416},"petpack_path":"/owned.petpack","cover_path":"","origin":"external_import","revision_id":"rev_00000000000000000000000000000003","revision_count":4,"active":false,"created_at":"2026-07-21T00:00:00Z"}"#.utf8
            )
        )
        #expect(current.revisionID == "rev_00000000000000000000000000000003")
        #expect(current.revisionCount == 4)

        let legacy = try JSONDecoder().decode(
            PetSummary.self,
            from: Data(
                #"{"id":"pet_legacy","name":"Legacy","style":"pixel","quality":"high","render_size":{"width":384,"height":416},"petpack_path":"/external.petpack","cover_path":"","active":false,"created_at":"2026-07-21T00:00:00Z"}"#.utf8
            )
        )
        #expect(legacy.revisionID == nil)
        #expect(legacy.revisionCount == 0)
    }

    @Test
    func validationSummaryRetainsTypedAssetFailure() {
        let pet = makePet(id: "pet_invalid", name: "损坏宠物", origin: .externalImport)
        let warning = PetAssetWarning(
            petId: pet.id,
            code: "pet_assets_invalid",
            fingerprint: "fingerprint",
            message: "idle frame is corrupt"
        )
        let presentation = PetLibraryPresentation(
            pet: pet,
            assetWarning: warning,
            localeIdentifier: "en"
        )

        #expect(presentation.validationStatus == .invalid)
        #expect(presentation.validationSummary.contains("idle frame is corrupt"))
    }

    @Test
    func searchMatchesNameStableIDAndSourceWithoutCollapsingSameNames() {
        let external = makePet(
            id: "pet_same_external",
            name: "同名宠物",
            origin: .externalImport
        )
        var generated = makePet(
            id: "pet_same_generated",
            name: "同名宠物",
            origin: .generatedByPetcoreJob
        )
        generated.provenance = "skill-full-source"
        let pets = [external, generated]

        #expect(PetLibraryPresentation.filtered(
            pets,
            query: "同名宠物",
            localeIdentifier: "zh-Hans"
        ).map(\.id) == [
            "pet_same_external",
            "pet_same_generated"
        ])
        #expect(PetLibraryPresentation.filtered(
            pets,
            query: "same_generated",
            localeIdentifier: "zh-Hans"
        ).map(\.id) == [
            "pet_same_generated"
        ])
        #expect(PetLibraryPresentation.filtered(
            pets,
            query: "外部导入",
            localeIdentifier: "zh-Hans"
        ).map(\.id) == [
            "pet_same_external"
        ])
        #expect(PetLibraryPresentation.filtered(
            pets,
            query: "App 内生成",
            localeIdentifier: "zh-Hans"
        ).map(\.id) == [
            "pet_same_generated"
        ])
        #expect(PetLibraryPresentation.filtered(
            pets,
            query: "Imported",
            localeIdentifier: "en"
        ).map(\.id) == ["pet_same_external"])
        #expect(PetLibraryPresentation.filtered(
            pets,
            query: "Created in App",
            localeIdentifier: "en"
        ).map(\.id) == ["pet_same_generated"])
    }

    @MainActor
    @Test
    func typedImportFailureLocalizesFileNameWithoutBackendOrPathDetails() {
        let pets = [
            makePet(id: "pet_selected", name: "已选择", origin: .externalImport),
            makePet(id: "pet_other", name: "其他", origin: .externalImport)
        ]
        let store = makeStore()
        store.statusText = "任意全局状态"
        store.setPetLibraryImportFailure(
            importedCount: 1,
            failures: [
                .file(at: URL(fileURLWithPath: "/private/backend-secret-reason/broken.petpack"))
            ]
        )

        let notice = store.petLibraryNotice
        #expect(notice?.kind == .importFailure)
        #expect(notice?.title == APCLocalization.text(.libraryImportPartialTitle))
        #expect(notice?.message.contains("broken.petpack") == true)
        #expect(notice?.message.contains("backend-secret-reason") == false)
        #expect(notice?.message.contains("/private") == false)
        #expect(store.statusText == "任意全局状态")
        #expect(PetLibrarySelectionPolicy.reconciledSelection(
            currentID: "pet_selected",
            pets: pets,
            preferredID: nil,
            allowsDefaultSelection: false
        ) == "pet_selected")

        store.dismissPetLibraryNotice()
        #expect(store.petLibraryNotice == nil)
    }

    @Test
    func typedImportFailureDetailHasExplicitEnglishAndChineseCopy() {
        let failure = PetLibraryImportFailure.file(
            at: URL(fileURLWithPath: "/private/validation-backend-detail/broken.petpack")
        )
        let english = PetLibraryNotice.importFailure(
            importedCount: 0,
            failures: [failure],
            localeIdentifier: "en"
        )
        let chinese = PetLibraryNotice.importFailure(
            importedCount: 0,
            failures: [failure],
            localeIdentifier: "zh-Hans"
        )

        #expect(english.message.contains("“broken.petpack” could not be imported"))
        #expect(chinese.message.contains("“broken.petpack” 导入失败"))
        #expect(!english.message.contains("validation-backend-detail"))
        #expect(!chinese.message.contains("validation-backend-detail"))
    }

    @Test
    func sourceContractKeepsCardsActionFreeAndUsesNativeInspectorSurfaces() throws {
        let source = try String(contentsOf: petLibraryViewURL, encoding: .utf8)
        let animationSource = try String(contentsOf: animationPreviewURL, encoding: .utf8)
        let appStoreSource = try String(contentsOf: appStoreURL, encoding: .utf8)

        #expect(source.contains("PageActionHeader("))
        #expect(source.contains("pet-library.search"))
        #expect(source.contains("pet-library.import"))
        #expect(source.contains("pet-library.make"))
        #expect(source.contains("pet-library.notice.retry"))
        #expect(source.contains("onRetry: { store.importPetpacks() }"))
        #expect(source.contains(".disabled(retrying)"))
        #expect(source.contains("LazyVGrid("))
        #expect(source.contains(".inspector(isPresented:"))
        #expect(source.contains("TapGesture(count: 2)"))
        #expect(source.contains(".onKeyPress(.return)"))
        #expect(source.contains("pet-library.inspector.activate"))
        #expect(source.contains("pet-library.inspector.customize-copy"))
        #expect(source.contains("InfoRow(title: APCLocalization.text(.libraryFieldRevisionID)"))
        #expect(source.contains("InfoRow(title: APCLocalization.text(.libraryFieldImmutableRevisions)"))
        #expect(source.contains("InfoRow(title: APCLocalization.text(.libraryFieldPackageVersion)"))
        #expect(source.contains("PetLibrarySourceBadge("))
        #expect(!source.contains("apcFloatingControlGlass"))

        let importStart = try #require(appStoreSource.range(of: "    func importPetpacks()"))
        let dismissImportStart = try #require(appStoreSource.range(
            of: "    func dismissPetLibraryNotice()",
            range: importStart.upperBound ..< appStoreSource.endIndex
        ))
        let importSource = appStoreSource[importStart.lowerBound ..< dismissImportStart.lowerBound]
        #expect(!importSource.contains("error.localizedDescription"))
        #expect(importSource.contains("diagnostics.logFailure("))
        #expect(importSource.contains("\"file_index\": .integer"))
        #expect(importSource.contains("failures.append(.file(at: url))"))

        let cardStart = try #require(source.range(of: "struct PetCard: View"))
        let inspectorStart = try #require(source.range(of: "private struct PetLibraryInspector"))
        let cardSource = source[cardStart.lowerBound ..< inspectorStart.lowerBound]
        #expect(!cardSource.contains("AI 修改"))
        #expect(!cardSource.contains("删除"))
        #expect(!cardSource.contains("导出"))
        #expect(!cardSource.contains("管理"))
        #expect(!cardSource.contains("PetLibraryAnimationPreview"))

        let inspectorSource = source[inspectorStart.lowerBound...]
        #expect(inspectorSource.contains("PetLibraryAnimationPreview(pet: pet)"))
        #expect(inspectorSource.contains("pet-library.inspector.more"))
        let deleteCapabilityStart = try #require(
            inspectorSource.range(of: "if presentation.canDelete {")
        )
        let deleteActionIdentifier = try #require(
            inspectorSource.range(
                of: "pet-library.inspector.delete",
                range: deleteCapabilityStart.upperBound ..< inspectorSource.endIndex
            )
        )
        let deleteMenuPrefix = inspectorSource[
            deleteCapabilityStart.lowerBound ..< deleteActionIdentifier.lowerBound
        ]
        let menuPosition = try #require(deleteMenuPrefix.range(of: "Menu {"))
        let deleteButtonPosition = try #require(
            deleteMenuPrefix.range(of: "APCLocalization.text(.libraryDeleteAction)")
        )
        #expect(menuPosition.lowerBound < deleteButtonPosition.lowerBound)
        #expect(animationSource.contains("PetCoverImage(pet: pet"))
        #expect(animationSource.contains("PetMetalFrameRenderer()"))
        #expect(animationSource.contains("stateName: \"idle\""))
        #expect(animationSource.contains("@Environment(\\.accessibilityReduceMotion)"))
        #expect(animationSource.contains("reduceMotion: reduceMotion"))
        #expect(animationSource.contains("static func dismantleNSView"))
        #expect(animationSource.contains("coordinator.suspendPipeline()"))
        #expect(!animationSource.contains("updateOverlayPetVisualEnvelope"))

        let copyStart = try #require(appStoreSource.range(of: "func preparePetCustomizationCopy"))
        let copyEnd = try #require(appStoreSource.range(
            of: "func clearStudioForm",
            range: copyStart.upperBound ..< appStoreSource.endIndex
        ))
        let copySource = appStoreSource[copyStart.lowerBound ..< copyEnd.lowerBound]
        #expect(copySource.contains("reduceGeneration(.reset)"))
        #expect(copySource.contains("selection = .maker"))
        #expect(copySource.contains("safeMakerReferenceImagePath"))
        #expect(!copySource.contains("requestPetCore"))
        #expect(!copySource.contains("beginGeneration"))
    }

    @MainActor
    @Test
    func narrowInfoRowRendersAsAStackWithoutCompressingCriticalValues() throws {
        let narrowWidth: CGFloat = 210
        let wideWidth: CGFloat = 340
        let title = "Revision ID"
        let value = "rev_00000000000000000000000000000003"

        #expect(InfoRowLayoutPolicy.mode(for: narrowWidth) == .stacked)
        #expect(InfoRowLayoutPolicy.mode(for: wideWidth) == .sideBySide)

        let narrow = try renderedInfoRow(width: narrowWidth, title: title, value: value)
        let wide = try renderedInfoRow(width: wideWidth, title: title, value: value)

        #expect(abs(narrow.size.width - narrowWidth) < 0.5)
        #expect(abs(wide.size.width - wideWidth) < 0.5)
        #expect(narrow.size.height > wide.size.height + 12)
        #expect(narrow.bitmap.pixelsWide > 0)
        #expect(narrow.bitmap.pixelsHigh > wide.bitmap.pixelsHigh)
    }

    @MainActor
    private func renderedInfoRow(
        width: CGFloat,
        title: String,
        value: String
    ) throws -> (size: CGSize, bitmap: NSBitmapImageRep) {
        let hostingView = NSHostingView(rootView: InfoRow(title: title, value: value)
            .frame(width: width))
        let fittingSize = hostingView.fittingSize
        hostingView.frame = CGRect(
            origin: .zero,
            size: CGSize(width: width, height: ceil(fittingSize.height))
        )
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return (hostingView.bounds.size, bitmap)
    }

    private var petLibraryViewURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentPetCompanion/Views/PetLibraryView.swift")
    }

    private var animationPreviewURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentPetCompanion/Views/PetLibraryAnimationPreview.swift")
    }

    private var appStoreURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentPetCompanion/App/AppStore.swift")
    }

    @MainActor
    private func makeStore() -> AppStore {
        AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            )
        )
    }

    private func makeBundledPet() -> PetSummary {
        var pet = makePet(
            id: "pet_xingwutuanzi",
            name: "星雾团子",
            origin: .verifiedSkillSource
        )
        pet.generator = "agent-pet-companion.release-inventory"
        pet.provenance = "apc.bundled-pets.v1"
        pet.revisionID = "rev_00000000000000000000000000000001"
        pet.revisionCount = 2
        return pet
    }

    private func makePet(
        id: String,
        name: String,
        origin: PetOrigin,
        revisionID: String? = nil,
        revisionCount: Int = 0
    ) -> PetSummary {
        PetSummary(
            id: id,
            name: name,
            style: "半写实",
            quality: .high,
            renderSize: RenderSize(width: 384, height: 416),
            petpackPath: "/tmp/\(id).petpack",
            coverPath: "",
            origin: origin,
            revisionID: revisionID,
            revisionCount: revisionCount,
            active: false,
            createdAt: "2026-07-21T00:00:00Z"
        )
    }
}
