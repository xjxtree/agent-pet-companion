import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("Pet library")
struct PetLibraryTests {
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
    func threeBundledPetsRemainScannableWithoutSearchAndPreferTheActivePet() {
        var first = makeBundledPet()
        first.active = false
        var second = makeBundledPet()
        second.id = "pet_bytebudcodex"
        second.name = "Bytebud 字节芽"
        second.active = true
        var third = makeBundledPet()
        third.id = "pet_pinklace"
        third.name = "桃蕾"
        third.active = false
        let pets = [first, second, third]

        #expect(pets.allSatisfy { $0.isBundled })
        #expect(!PetLibraryDensityPolicy.showsSearch(petCount: pets.count))
        #expect(!PetLibraryDensityPolicy.showsSearch(
            petCount: PetLibraryDensityPolicy.searchThreshold - 1
        ))
        #expect(PetLibraryDensityPolicy.showsSearch(
            petCount: PetLibraryDensityPolicy.searchThreshold
        ))
        #expect(PetLibrarySelectionPolicy.reconciledSelection(
            currentID: nil,
            pets: pets,
            preferredID: second.id,
            allowsDefaultSelection: true
        ) == second.id)
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
        #expect(bundled.stateSummary == "idle · thinking · tool · waiting · done · failed")
        #expect(bundled.timingSummary == "42 帧 · 9 个动作 · 逐帧创作时序")
        #expect(bundled.durationSummary.contains("idle：1,500 毫秒"))
        #expect(bundled.durationSummary.contains("waiting：1,000 毫秒"))
        #expect(bundled.heroSummary == "半写实 · App 内置")
        #expect(bundled.provenanceSummary.contains("verified_skill_source"))
        #expect(bundled.provenanceSummary.contains("apc.bundled-pets.v1"))
        #expect(bundled.frameCountSummary.contains("idle：4 帧"))
        #expect(bundled.frameCountSummary.contains("waiting：6 帧"))
        #expect(Set(bundled.technicalInformation.map(\.field))
            == Set(PetLibraryTechnicalItem.Field.allCases))
        #expect(bundled.technicalInformation.first?.field == .stableID)
        #expect(bundled.technicalInformation.last?.field == .validation)

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

        var highPet = imported.pet
        highPet.quality = .high
        highPet.renderSize = .init(width: 576, height: 624)
        let high = PetLibraryPresentation(
            pet: highPet,
            assetWarning: nil,
            localeIdentifier: "zh-Hans"
        )
        #expect(!high.canModify)
        #expect(high.canDelete)
        #expect(!high.canCustomizeAsCopy)
        #expect(high.technicalInformation.contains {
            $0.field == .renderSize && $0.value == "576×624"
        })

        let nonOwned = PetLibraryPresentation(
            pet: makePet(id: "pet_external", name: "外部包", origin: .externalImport),
            assetWarning: nil,
            localeIdentifier: "zh-Hans"
        )
        #expect(nonOwned.revisionIDSummary == "未提供（非 PetCore 自有）")
        #expect(nonOwned.revisionCountSummary == "0 个（非 PetCore 自有）")

        var customTimingPet = nonOwned.pet
        customTimingPet.states[0].frameDurationsMS = [250, 250, 250, 250]
        let customTiming = PetLibraryPresentation(
            pet: customTimingPet,
            assetWarning: nil,
            localeIdentifier: "zh-Hans"
        )
        #expect(customTiming.timingSummary == "42 帧 · 9 个动作 · 逐帧创作时序")
        #expect(customTiming.durationSummary.contains("idle：1,000 毫秒"))
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
    func sameNameCardsUseStableContentFreeVariantsWithoutSpeakingManifestIDs() {
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
            let firstPresentation = PetLibraryPresentation(
                pet: firstPet,
                assetWarning: nil,
                localeIdentifier: localeIdentifier
            )
            let secondPresentation = PetLibraryPresentation(
                pet: secondPet,
                assetWarning: nil,
                localeIdentifier: localeIdentifier
            )
            #expect(firstPresentation.sourceTitle == secondPresentation.sourceTitle)
            #expect(PetLibraryCardIdentityPolicy.variantOrdinal(
                for: firstPet,
                in: [secondPet, firstPet]
            ) == 1)
            #expect(PetLibraryCardIdentityPolicy.variantOrdinal(
                for: secondPet,
                in: [firstPet, secondPet]
            ) == 2)

            let first = PetCardAccessibilityPresentation(
                name: firstPet.name,
                styleTitle: firstPresentation.styleTitle,
                sourceTitle: firstPresentation.sourceTitle,
                variantOrdinal: 1,
                localeIdentifier: localeIdentifier
            )
            let second = PetCardAccessibilityPresentation(
                name: secondPet.name,
                styleTitle: secondPresentation.styleTitle,
                sourceTitle: secondPresentation.sourceTitle,
                variantOrdinal: 2,
                localeIdentifier: localeIdentifier
            )

            #expect(first.label != second.label)
            #expect(first.label.contains(firstPet.name))
            #expect(first.label.contains(firstPresentation.sourceTitle))
            #expect(first.label.contains(firstPresentation.styleTitle))
            #expect(!first.label.contains(firstPet.id))
            #expect(!first.label.contains(secondPet.id))
            #expect(second.label.contains(secondPet.name))
            #expect(second.label.contains(secondPresentation.sourceTitle))
            #expect(!second.label.contains(secondPet.id))
            #expect(!second.label.contains(firstPet.id))
        }

        let english = PetCardAccessibilityPresentation(
            name: firstPet.name,
            styleTitle: "Semi-realistic",
            sourceTitle: "Imported",
            variantOrdinal: nil,
            localeIdentifier: "en"
        )
        let chinese = PetCardAccessibilityPresentation(
            name: firstPet.name,
            styleTitle: "半写实",
            sourceTitle: "外部导入",
            variantOrdinal: nil,
            localeIdentifier: "zh-Hans"
        )
        #expect(english.label.hasPrefix("Select pet "))
        #expect(english.label.contains("Style Semi-realistic"))
        #expect(!english.label.contains(firstPet.id))
        #expect(chinese.label.hasPrefix("选择宠物 "))
        #expect(chinese.label.contains("风格：半写实"))
        #expect(!chinese.label.contains(firstPet.id))
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
    func transportProjectionRequiresV3TimingAndDecodesRevisionMetadata() throws {
        let expected = makePet(
            id: "pet_current",
            name: "Current",
            origin: .externalImport,
            revisionID: "rev_00000000000000000000000000000003",
            revisionCount: 4
        )
        let current = try JSONDecoder().decode(
            PetSummary.self,
            from: JSONEncoder().encode(expected)
        )
        #expect(current.revisionID == "rev_00000000000000000000000000000003")
        #expect(current.revisionCount == 4)
        #expect(current.states == PetAnimationContract.defaultStates)

        let missingTiming = #"{"id":"pet_missing","name":"Missing","style":"pixel","quality":"standard","render_size":{"width":384,"height":416},"petpack_path":"/external.petpack","cover_path":"","active":false,"created_at":"2026-07-21T00:00:00Z"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PetSummary.self, from: Data(missingTiming.utf8))
        }
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
        #expect(!PetLibraryPreviewPolicy.canOpenAssets(assetWarning: warning))
        #expect(!PetLibraryPreviewPolicy.canRender(assetWarning: warning))

        var loadCount = 0
        let blocked: String? = PetLibraryPreviewPolicy.loadIfValidated(
            assetWarning: warning
        ) {
            loadCount += 1
            return "must-not-open"
        }
        #expect(blocked == nil)
        #expect(loadCount == 0)

        let loaded: String? = PetLibraryPreviewPolicy.loadIfValidated(
            assetWarning: nil
        ) {
            loadCount += 1
            return "validated"
        }
        #expect(loaded == "validated")
        #expect(loadCount == 1)
    }

    @Test
    func motionPreviewUsesTheAuthoredPerFrameTimingWithoutRetiming() {
        let pet = makePet(id: "pet_timing", name: "Timing", origin: .externalImport)

        #expect(PetLibraryPreviewPolicy.canRender(assetWarning: nil))
        for action in PetLibraryPreviewActionPolicy.orderedActions {
            let timing = pet.timing(for: action.rawValue)
            let timeline = FrameTimeline(state: timing, periodicCooldownMS: 4_000)

            #expect(timeline.durationsMS == timing.frameDurationsMS)
            #expect(timeline.frameCount == timing.frameDurationsMS.count)
        }
    }

    @Test
    func motionPreviewDefaultsToIdleAndFollowsThePortableActionOrder() {
        #expect(PetLibraryPreviewActionPolicy.defaultAction == .idle)
        #expect(
            PetLibraryPreviewActionPolicy.orderedActions.map(\.rawValue)
                == PetAnimationContract.orderedStateNames
        )
        #expect(PetLibraryPreviewActionPolicy.accessibilityLabel(
            petName: "Bytebud",
            action: .thinking,
            localeIdentifier: "en"
        ) == "Bytebud — Thinking action preview")
        #expect(PetLibraryPreviewActionPolicy.accessibilityLabel(
            petName: "字节芽",
            action: .thinking,
            localeIdentifier: "zh-Hans"
        ) == "字节芽——“正在思考”动作预览")
    }

    @Test
    func motionPreviewContentReadinessIsScopedToTheExactRenderIdentity() {
        let pet = makePet(
            id: "pet_preview_identity",
            name: "Preview",
            origin: .externalImport
        )
        let idle = PetPreviewRenderIdentity(
            pet: pet,
            stateName: ProductLifecycleState.idle.rawValue,
            assetWarning: nil
        )
        let thinking = PetPreviewRenderIdentity(
            pet: pet,
            stateName: ProductLifecycleState.thinking.rawValue,
            assetWarning: nil
        )
        var state = PetPreviewContentState()

        #expect(!state.hasPresentedContent(for: idle))
        #expect(!state.hasPresentedContent(for: thinking))

        state.receive(hasContent: true, for: idle)
        #expect(state.hasPresentedContent(for: idle))
        #expect(!state.hasPresentedContent(for: thinking))

        state.receive(hasContent: true, for: thinking)
        state.receive(hasContent: false, for: idle)
        #expect(!state.hasPresentedContent(for: idle))
        #expect(state.hasPresentedContent(for: thinking))

        // A late positive callback from the replaced renderer must not hide
        // the current action's fallback or clear its already-presented state.
        state.receive(hasContent: true, for: idle)
        #expect(state.hasPresentedContent(for: thinking))
        state.receive(hasContent: false, for: thinking)
        #expect(!state.hasPresentedContent(for: thinking))
        #expect(state.hasPresentedContent(for: idle))
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
            query: "Semi-realistic",
            localeIdentifier: "en"
        ).map(\.id) == pets.map(\.id))
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
    func importFailureDistinguishesPackageRejectionFromLocalServiceFailure() {
        let url = URL(fileURLWithPath: "/private/backend-detail/realistic.petpack")
        let serviceFailure = PetLibraryImportFailure.requestFailure(
            at: url,
            error: PetCoreClientError.rpcErrorResponse(
                code: -32603,
                message: "private sqlite detail"
            )
        )
        let packageFailure = PetLibraryImportFailure.requestFailure(
            at: url,
            error: PetCoreClientError.rpcErrorResponse(
                code: -32000,
                message: "private validation detail"
            )
        )

        let serviceDetail = serviceFailure.localizedDetail(localeIdentifier: "zh-Hans")
        let packageDetail = packageFailure.localizedDetail(localeIdentifier: "zh-Hans")
        #expect(serviceDetail.contains("本地服务"))
        #expect(serviceDetail.contains("请重试"))
        #expect(!serviceDetail.contains("sqlite"))
        #expect(packageDetail.contains("有效的本 App .petpack"))
        #expect(!packageDetail.contains("validation"))
    }

    @Test
    func sourceContractCentersTheMotionHeroAndKeepsCardsSelectionOnly() throws {
        let source = try String(contentsOf: petLibraryViewURL, encoding: .utf8)
        let animationSource = try String(contentsOf: animationPreviewURL, encoding: .utf8)
        let appStoreSource = try String(contentsOf: appStoreURL, encoding: .utf8)

        #expect(source.contains("ProductPageHeader("))
        #expect(source.contains("PrimaryExperienceCard("))
        #expect(source.contains("PetPreviewStage("))
        #expect(source.contains("AdvancedDetailsDisclosure("))
        #expect(source.contains("private struct PetLibraryHero"))
        #expect(source.contains("minimumHeight: 280"))
        #expect(source.contains("minHeight: 280,"))
        #expect(source.contains("maxHeight: 360"))
        #expect(source.contains("if assetWarning != nil {"))
        #expect(source.contains("PetAssetRecoveryCard("))
        #expect(source.contains(".searchable("))
        #expect(source.contains("if showsSearch {"))
        #expect(source.contains("ToolbarItemGroup(placement: .primaryAction)"))
        #expect(!source.contains("ToolbarItemGroup(placement: .secondaryAction)"))
        #expect(source.contains("pet-library.import"))
        #expect(source.contains("pet-library.make"))
        #expect(source.contains("pet-library.notice.retry"))
        #expect(source.contains("onRetry: { store.importPetpacks() }"))
        #expect(source.contains(".disabled(retrying)"))
        #expect(source.contains("LazyVGrid("))
        #expect(!source.contains(".inspector(isPresented:"))
        #expect(!source.contains("PetLibraryInspector"))
        #expect(!source.contains("TapGesture(count: 2)"))
        #expect(!source.contains("onActivate: { store.activatePet(pet) }"))
        #expect(source.contains("pet-library.hero.customize-copy"))
        #expect(source.contains("pet-library.hero.modify"))
        #expect(source.contains("pet-library.hero.history"))
        #expect(source.contains("pet-library.hero.export"))
        #expect(source.contains("pet-library.hero.more"))
        #expect(source.contains("pet-library.hero.action-picker"))
        #expect(source.contains(
            "@State private var selectedPreviewAction = PetLibraryPreviewActionPolicy.defaultAction"
        ))
        #expect(source.contains("PetLibraryPreviewActionPolicy.orderedActions"))
        #expect(source.contains("action: selectedPreviewAction"))
        #expect(source.contains(".pickerStyle(.segmented)"))
        #expect(source.contains("presentation.technicalInformation"))
        #expect(source.contains("PetLibrarySourceBadge("))
        #expect(!source.contains("apcFloatingControlGlass"))

        let heroStart = try #require(source.range(of: "private struct PetLibraryHero"))
        let heroEnd = try #require(source.range(
            of: "struct PetCard: View",
            range: heroStart.upperBound ..< source.endIndex
        ))
        let heroSource = String(source[heroStart.lowerBound ..< heroEnd.lowerBound])
        #expect(heroSource.contains(
            "private var primaryAction: ProductActionPresentation<PetLibraryPrimaryAction>?"
        ))
        #expect(heroSource.contains("guard productPresentation.presentsHeroUseAction else"))
        #expect(heroSource.contains("if isBusy {"))
        #expect(heroSource.contains("appearance: .checking"))
        #expect(heroSource.contains(".libraryPetEnabling"))
        #expect(heroSource.contains("primaryAction: primaryAction"))
        #expect(occurrences(of: "PetLibrarySourceBadge(", in: heroSource) == 0)
        #expect(occurrences(of: "presentation.styleTitle", in: heroSource) == 0)

        let importStart = try #require(appStoreSource.range(of: "    func importPetpacks()"))
        let dismissImportStart = try #require(appStoreSource.range(
            of: "    func dismissPetLibraryNotice()",
            range: importStart.upperBound ..< appStoreSource.endIndex
        ))
        let importSource = appStoreSource[importStart.lowerBound ..< dismissImportStart.lowerBound]
        #expect(!importSource.contains("error.localizedDescription"))
        #expect(importSource.contains("diagnostics.logFailure("))
        #expect(importSource.contains("\"file_index\": .integer"))
        #expect(importSource.contains("failures.append(.requestFailure(at: url, error: error))"))

        let cardStart = try #require(source.range(of: "struct PetCard: View"))
        let coverStart = try #require(source.range(
            of: "struct PetCoverImage",
            range: cardStart.upperBound ..< source.endIndex
        ))
        let cardSource = source[cardStart.lowerBound ..< coverStart.lowerBound]
        #expect(!cardSource.contains("AI 修改"))
        #expect(!cardSource.contains("删除"))
        #expect(!cardSource.contains("导出"))
        #expect(!cardSource.contains("管理"))
        #expect(!cardSource.contains("PetLibraryAnimationPreview"))
        #expect(!cardSource.contains("onActivate"))
        #expect(!cardSource.contains("accessibilityAction"))
        #expect(cardSource.contains("assetWarning: PetAssetWarning?"))
        #expect(cardSource.contains("assetWarning: assetWarning"))

        #expect(animationSource.contains("PetActionFallbackImage("))
        #expect(animationSource.contains("reducedMotionFrameIndex"))
        #expect(animationSource.contains("pet: pet"))
        #expect(animationSource.contains("assetWarning: assetWarning"))
        #expect(animationSource.contains("loadIfValidated"))
        #expect(animationSource.contains("PetMetalFrameRenderer()"))
        #expect(animationSource.contains("let action: PetAnimationAction"))
        #expect(animationSource.contains("stateName: action.rawValue"))
        #expect(animationSource.contains("action.rawValue"))
        #expect(!animationSource.contains("stateName: \"idle\""))
        #expect(animationSource.contains("PetLibraryPreviewPolicy.canRender(assetWarning: assetWarning)"))
        #expect(animationSource.contains("@Environment(\\.accessibilityReduceMotion)"))
        #expect(animationSource.contains("reduceMotion: reduceMotion"))
        #expect(animationSource.contains("static func dismantleNSView"))
        #expect(animationSource.contains("coordinator.suspendPipeline()"))
        #expect(animationSource.contains("onFrameContentChanged: onRendererContentChanged"))
        #expect(!animationSource.contains("rendererHasContent"))
        #expect(!animationSource.contains("onChange(of: previewIdentity)"))
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
        let narrowWidth: CGFloat = 240
        let wideWidth: CGFloat = 290
        let title = "Revision ID"
        let value = "rev_00000000000000000000000000000003"

        #expect(InfoRowLayoutPolicy.mode(for: narrowWidth) == .stacked)
        #expect(InfoRowLayoutPolicy.mode(for: wideWidth) == .sideBySide)

        let narrow = try renderedInfoRow(width: narrowWidth, title: title, value: value)
        let wide = try renderedInfoRow(width: wideWidth, title: title, value: value)

        #expect(abs(narrow.size.width - narrowWidth) < 0.5)
        #expect(abs(wide.size.width - wideWidth) < 0.5)
        #expect(narrow.size.height >= wide.size.height + 4)
        #expect(narrow.bitmap.pixelsWide > 0)
        #expect(narrow.bitmap.pixelsHigh > wide.bitmap.pixelsHigh)
    }

    @MainActor
    @Test
    func inspectorInfoRowsWrapRealValuesWithoutPaintingPastTheirAvailableWidth() throws {
        let values = [
            (".petpack 版本", "apc.petpack.v3"),
            ("九动作", "idle · thinking · tool · waiting · done · failed · acknowledge · drag_left · drag_right"),
            ("动画时序", "42 帧 · 9 个动作 · 逐帧创作时序"),
            ("动作时长", "idle：1500 毫秒 · thinking：600 毫秒 · waiting：1000 毫秒"),
            ("Revision ID", "rev_00000000000000000000000000000003"),
        ]

        for width: CGFloat in [240, 272, 290] {
            #expect(
                InfoRowLayoutPolicy.mode(for: width)
                    == (width < InfoRowLayoutPolicy.minimumSideBySideWidth
                        ? .stacked
                        : .sideBySide)
            )

            for (title, value) in values {
                let rendering = try renderedInfoRowInSafetyCanvas(
                    width: width,
                    title: title,
                    value: value
                )
                #expect(rendering.rowHeight >= 36)
                #expect(!rendering.hasInkPastRowWidth)
            }
        }

        let wrappedRevision = try renderedInfoRow(
            width: 240,
            title: "Revision ID",
            value: "rev_00000000000000000000000000000003"
        )
        #expect(wrappedRevision.size.height >= 50)
    }

    @MainActor
    @Test
    func inspectorInfoRowsLayOutTrailingStateAndRevisionGlyphsInsideTheValueView() throws {
        let states = "idle · thinking · tool · waiting · done · failed · acknowledge · drag_left · drag_right"
        let revision = "rev_00000000000000000000000000000003"

        for width: CGFloat in [240, 272, 290] {
            let statesRendering = try renderedInfoRowValueView(
                width: width,
                title: "九动作",
                value: states
            )
            let statesView = statesRendering.textView
            let doneBounds = try glyphBounds(of: "done", in: statesView)
            let doneBoundsInHost = statesView.convert(doneBounds, to: statesRendering.hostingView)
            #expect(statesView.string == states)
            #expect(statesView.accessibilityLabel() == states)
            #expect(statesView.textContainer?.lineBreakMode == .byCharWrapping)
            #expect(doneBounds.width > 0 && doneBounds.height > 0)
            #expect(doneBounds.minX >= 0 && doneBounds.maxX <= statesView.bounds.width + 0.5)
            #expect(doneBounds.minY >= 0 && doneBounds.maxY <= statesView.bounds.height + 0.5)
            #expect(doneBoundsInHost.minX >= 0)
            #expect(doneBoundsInHost.maxX <= statesRendering.hostingView.bounds.width + 0.5)
            #expect(doneBoundsInHost.minY >= 0)
            #expect(doneBoundsInHost.maxY <= statesRendering.hostingView.bounds.height + 0.5)

            let revisionRendering = try renderedInfoRowValueView(
                width: width,
                title: "Revision ID",
                value: revision
            )
            let revisionView = revisionRendering.textView
            let suffixBounds = try glyphBounds(of: "03", in: revisionView)
            let suffixBoundsInHost = revisionView.convert(
                suffixBounds,
                to: revisionRendering.hostingView
            )
            #expect(revisionView.string == revision)
            #expect(revisionView.accessibilityLabel() == revision)
            #expect(revisionView.textContainer?.lineBreakMode == .byCharWrapping)
            #expect(suffixBounds.width > 0 && suffixBounds.height > 0)
            #expect(suffixBounds.minX >= 0 && suffixBounds.maxX <= revisionView.bounds.width + 0.5)
            #expect(suffixBounds.minY >= 0 && suffixBounds.maxY <= revisionView.bounds.height + 0.5)
            #expect(suffixBoundsInHost.minX >= 0)
            #expect(suffixBoundsInHost.maxX <= revisionRendering.hostingView.bounds.width + 0.5)
            #expect(suffixBoundsInHost.minY >= 0)
            #expect(suffixBoundsInHost.maxY <= revisionRendering.hostingView.bounds.height + 0.5)
        }
    }

    @MainActor
    @Test
    func inspectorScrollViewConstrainsInfoRowsToItsVisibleWidth() throws {
        let states = "idle · thinking · tool · waiting · done · failed · acknowledge · drag_left · drag_right"

        for viewportWidth: CGFloat in [286, 330, 390] {
            let rendering = try renderedInfoRowInInspectorScrollView(
                viewportWidth: viewportWidth,
                title: "九动作",
                value: states
            )
            let doneBounds = try glyphBounds(of: "done", in: rendering.textView)
            let doneBoundsInHost = rendering.textView.convert(
                doneBounds,
                to: rendering.hostingView
            )

            #expect(rendering.textView.string == states)
            #expect(doneBounds.maxX <= rendering.textView.bounds.width + 0.5)
            #expect(doneBoundsInHost.minX >= -0.5)
            #expect(doneBoundsInHost.maxX <= viewportWidth + 0.5)
        }
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

    @MainActor
    private func renderedInfoRowInSafetyCanvas(
        width: CGFloat,
        title: String,
        value: String
    ) throws -> (rowHeight: CGFloat, hasInkPastRowWidth: Bool) {
        let row = try renderedInfoRow(width: width, title: title, value: value)
        let safetyMargin: CGFloat = 48
        let canvasWidth = width + safetyMargin
        let hostingView = NSHostingView(rootView: ZStack(alignment: .topLeading) {
            Color.white
            InfoRow(title: title, value: value)
                .frame(width: width)
        }
        .frame(width: canvasWidth, height: row.size.height, alignment: .topLeading)
        .environment(\.colorScheme, .light))
        hostingView.frame = CGRect(
            origin: .zero,
            size: CGSize(width: canvasWidth, height: row.size.height)
        )
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        let scale = CGFloat(bitmap.pixelsWide) / canvasWidth
        let firstSafetyPixel = min(
            bitmap.pixelsWide,
            Int(ceil((width + 2) * scale))
        )
        var hasInkPastRowWidth = false
        if firstSafetyPixel < bitmap.pixelsWide {
            for x in firstSafetyPixel ..< bitmap.pixelsWide {
                for y in 0 ..< bitmap.pixelsHigh {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                        continue
                    }
                    if color.redComponent < 0.97
                        || color.greenComponent < 0.97
                        || color.blueComponent < 0.97
                    {
                        hasInkPastRowWidth = true
                        break
                    }
                }
                if hasInkPastRowWidth { break }
            }
        }

        return (row.size.height, hasInkPastRowWidth)
    }

    @MainActor
    private func renderedInfoRowValueView(
        width: CGFloat,
        title: String,
        value: String
    ) throws -> (textView: NSTextView, hostingView: NSView) {
        let hostingView = NSHostingView(rootView: InfoRow(title: title, value: value)
            .frame(width: width))
        let fittingSize = hostingView.fittingSize
        hostingView.frame = CGRect(
            origin: .zero,
            size: CGSize(width: width, height: ceil(fittingSize.height))
        )
        hostingView.layoutSubtreeIfNeeded()
        return (try #require(firstTextView(in: hostingView)), hostingView)
    }

    @MainActor
    private func renderedInfoRowInInspectorScrollView(
        viewportWidth: CGFloat,
        title: String,
        value: String
    ) throws -> (textView: NSTextView, hostingView: NSView) {
        let hostingView = NSHostingView(rootView: ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Current Info") {
                    VStack(spacing: 0) {
                        InfoRow(title: title, value: value)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: viewportWidth, height: 240))
        hostingView.frame = CGRect(x: 0, y: 0, width: viewportWidth, height: 240)
        hostingView.layoutSubtreeIfNeeded()
        return (try #require(firstTextView(in: hostingView)), hostingView)
    }

    @MainActor
    private func firstTextView(in root: NSView) -> NSTextView? {
        if let textView = root as? NSTextView { return textView }
        for subview in root.subviews {
            if let textView = firstTextView(in: subview) { return textView }
        }
        return nil
    }

    @MainActor
    private func glyphBounds(of suffix: String, in textView: NSTextView) throws -> CGRect {
        let characterRange = (textView.string as NSString).range(
            of: suffix,
            options: .backwards
        )
        #expect(characterRange.location != NSNotFound)
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        #expect(glyphRange.length > 0)
        return layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
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

    private func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
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
            quality: .standard,
            renderSize: QualityLevel.standard.renderSize,
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
