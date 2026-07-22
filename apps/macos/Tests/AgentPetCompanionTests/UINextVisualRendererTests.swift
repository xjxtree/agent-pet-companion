import AppKit
import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("UI Next executable visual renderer")
struct UINextVisualRendererTests {
    @MainActor
    @Test
    func rootRenderingHasOpaqueThemedCanvasesAndVisibleSidebarAndDetailInk() throws {
        let light = try UINextVisualFixtureRenderer.render(rootScenario(
            id: "render.root.light.library",
            section: .library,
            theme: .light,
            serviceState: .online,
            displayScale: 2
        ))
        let dark = try UINextVisualFixtureRenderer.render(rootScenario(
            id: "render.root.dark.diagnostics",
            section: .diagnostics,
            theme: .dark,
            serviceState: .runtimeMismatch,
            displayScale: 1
        ))
        let lightPixels = try UINextPNGPixelMap(pngData: light.pngData)
        let darkPixels = try UINextPNGPixelMap(pngData: dark.pngData)
        let sidebarRegion = CGRect(x: 0.02, y: 0.06, width: 0.18, height: 0.88)
        let detailRegion = CGRect(x: 0.24, y: 0.06, width: 0.72, height: 0.88)
        let canvasCorner = CGRect(x: 0.98, y: 0.98, width: 0.015, height: 0.015)

        for rendered in [light, dark] {
            #expect(rendered.offscreenHostState == UINextOffscreenHostState(
                wasVisible: true,
                wasKeyWindow: false,
                wasMainWindow: false,
                intersectedAnyScreen: false,
                preservedApplicationKeyWindow: true,
                preservedApplicationMainWindow: true,
                preservedApplicationActivation: true
            ))
        }

        for pixels in [lightPixels, darkPixels] {
            #expect(pixels.minimumAlpha == 255)

            let sidebar = pixels.statistics(in: sidebarRegion)
            #expect(sidebar.nonDominantColorFraction > 0.01)
            #expect(sidebar.edgeFraction > 0.001)

            let detail = pixels.statistics(in: detailRegion)
            #expect(detail.nonDominantColorFraction > 0.02)
            #expect(detail.edgeFraction > 0.001)
        }

        let lightCanvas = lightPixels.statistics(in: canvasCorner)
        let darkCanvas = darkPixels.statistics(in: canvasCorner)
        #expect(lightCanvas.meanLuminance > 180)
        #expect(darkCanvas.meanLuminance < 100)
        #expect(lightCanvas.meanLuminance - darkCanvas.meanLuminance > 100)
    }

    @MainActor
    @Test
    func minimumWindowRootAcceptanceScenariosRenderOpaqueVisibleCoreRegions() async throws {
        let scenarios = UINextVisualFixtureCatalog.minimumWindowAcceptanceScenarios
        let coreRegion = CGRect(x: 0.04, y: 0.06, width: 0.92, height: 0.88)

        #expect(scenarios.count == NavigationSection.allCases.count)
        for scenario in scenarios {
            let rendered = try UINextVisualFixtureRenderer.render(scenario)
            let pixels = try UINextPNGPixelMap(pngData: rendered.pngData)
            let core = pixels.statistics(in: coreRegion)

            #expect(rendered.logicalSize == CGSize(width: 760, height: 520))
            #expect(rendered.pixelWidth == 760 * Int(scenario.displayScale))
            #expect(rendered.pixelHeight == 520 * Int(scenario.displayScale))
            #expect(pixels.minimumAlpha == 255)
            #expect(core.nonDominantColorFraction > 0.02)
            #expect(core.edgeFraction > 0.001)
            await Task.yield()
        }
    }

    @MainActor
    @Test
    func auxiliaryRenderingHasOpaqueThemedCanvasesAndVisibleContent() throws {
        let about = try UINextVisualFixtureRenderer.render(aboutScenario(
            id: "render.auxiliary.about.light",
            locale: "en",
            displayScale: 2
        ))
        let menu = try UINextVisualFixtureRenderer.render(
            UINextVisualFixtureScenario(
                id: "render.auxiliary.menu.dark",
                surface: .menuBarExtra,
                width: 320,
                height: 420,
                theme: .dark,
                localeIdentifier: "en",
                displayScale: 2,
                accessibilityMode: .standard
            )
        )
        let aboutPixels = try UINextPNGPixelMap(pngData: about.pngData)
        let menuPixels = try UINextPNGPixelMap(pngData: menu.pngData)
        let contentRegion = CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
        let canvasCorner = CGRect(x: 0.98, y: 0.98, width: 0.015, height: 0.015)

        for pixels in [aboutPixels, menuPixels] {
            #expect(pixels.minimumAlpha == 255)
            let content = pixels.statistics(in: contentRegion)
            #expect(content.nonDominantColorFraction > 0.01)
            #expect(content.edgeFraction > 0.001)
        }
        #expect(aboutPixels.statistics(in: canvasCorner).meanLuminance > 180)
        #expect(menuPixels.statistics(in: canvasCorner).meanLuminance < 100)
    }

    @MainActor
    @Test
    func accessibilityOverridesProduceRealBubblePixelDifferences() throws {
        let standard = try UINextPNGPixelMap(pngData: UINextVisualFixtureRenderer.render(
            overlayScenario(id: "render.accessibility.standard", mode: .standard)
        ).pngData)
        let reducedTransparency = try UINextPNGPixelMap(
            pngData: UINextVisualFixtureRenderer.render(overlayScenario(
                id: "render.accessibility.reduce-transparency",
                mode: .reduceTransparency
            )).pngData
        )
        let increasedContrast = try UINextPNGPixelMap(
            pngData: UINextVisualFixtureRenderer.render(overlayScenario(
                id: "render.accessibility.increased-contrast",
                mode: .increasedContrast
            )).pngData
        )
        let bubbleRegion = CGRect(x: 0.02, y: 0.08, width: 0.66, height: 0.84)

        let reducedDifference = standard.differingPixelFraction(
            from: reducedTransparency,
            in: bubbleRegion,
            channelThreshold: 6
        )
        let contrastDifference = standard.differingPixelFraction(
            from: increasedContrast,
            in: bubbleRegion,
            channelThreshold: 6
        )
        #expect(reducedDifference > 0.01)
        #expect(contrastDifference > 0.002)
        #expect(
            reducedTransparency.statistics(in: bubbleRegion).meanLuminance
                > standard.statistics(in: bubbleRegion).meanLuminance
        )
    }

    @Test
    func evidenceExportValidatesOptInOutputPathsBeforeRendering() throws {
        #expect(
            try UINextVisualFixtureEvidenceExporter.outputDirectory(from: [:]) == nil
        )
        #expect(
            try UINextVisualFixtureEvidenceExporter.outputDirectory(from: [
                UINextVisualFixtureEvidenceExporter.environmentKey: "   "
            ]) == nil
        )

        do {
            _ = try UINextVisualFixtureEvidenceExporter.outputDirectory(from: [
                UINextVisualFixtureEvidenceExporter.environmentKey: "relative/evidence"
            ])
            Issue.record("Relative visual evidence path was accepted")
        } catch let error as UINextVisualFixtureEvidenceExporterError {
            #expect(error == .outputDirectoryMustBeAbsolute)
        }

        do {
            _ = try UINextVisualFixtureEvidenceExporter.outputDirectory(from: [
                UINextVisualFixtureEvidenceExporter.environmentKey: "/"
            ])
            Issue.record("Filesystem root was accepted as a visual evidence directory")
        } catch let error as UINextVisualFixtureEvidenceExporterError {
            #expect(error == .outputDirectoryMustNotBeFilesystemRoot)
        }

        let repositoryOutput = UINextVisualFixtureEvidenceExporter.repositoryRoot
            .appendingPathComponent(".apc-visual-evidence-must-not-exist")
        #expect(!FileManager.default.fileExists(atPath: repositoryOutput.path))
        do {
            _ = try UINextVisualFixtureEvidenceExporter.outputDirectory(from: [
                UINextVisualFixtureEvidenceExporter.environmentKey:
                    repositoryOutput.path
            ])
            Issue.record("A repository child was accepted as a visual evidence directory")
        } catch let error as UINextVisualFixtureEvidenceExporterError {
            #expect(error == .outputDirectoryMustBeOutsideRepository)
        }
        #expect(!FileManager.default.fileExists(atPath: repositoryOutput.path))
    }

    @Test
    func evidenceExportUsesStableCollisionResistantScenarioFileNames() throws {
        let scenarios = UINextVisualFixtureCatalog.regressionScenarios
        let names = try scenarios.map {
            try UINextVisualFixtureEvidenceExporter.stableFileName(for: $0)
        }

        #expect(names.count == Set(names).count)
        #expect(names.first == "regression-library-compact-checking.png")
        #expect(names.last == "regression-overlay-opencode-failed.png")
        #expect(names.allSatisfy { $0.hasSuffix(".png") })
        #expect(names.allSatisfy { !$0.contains("/") && !$0.contains("..") })

        let traversalScenario = aboutScenario(
            id: "../../outside/../escape",
            locale: "en",
            displayScale: 1
        )
        #expect(
            try UINextVisualFixtureEvidenceExporter.stableFileName(
                for: traversalScenario
            ) == "outside-escape.png"
        )
    }

    @Test
    func evidenceCatalogCombinesEveryFormalAcceptanceScenario() {
        let scenarios = UINextVisualFixtureEvidenceExporter.evidenceScenarios
        let ids = scenarios.map(\.id)

        #expect(ids.count == Set(ids).count)
        #expect(ids.count == UINextVisualFixtureCatalog.baselineScenarios.count
            + UINextVisualFixtureCatalog.regressionScenarios.count
            + UINextVisualFixtureCatalog.minimumWindowAcceptanceScenarios.count
            + UINextVisualFixtureCatalog.overlayAcceptanceScenarios.count)
        #expect(UINextVisualFixtureCatalog.baselineScenarios.allSatisfy {
            ids.contains($0.id)
        })
        #expect(UINextVisualFixtureCatalog.regressionScenarios.allSatisfy {
            ids.contains($0.id)
        })
        #expect(UINextVisualFixtureCatalog.minimumWindowAcceptanceScenarios.allSatisfy {
            ids.contains($0.id)
        })
        #expect(UINextVisualFixtureCatalog.overlayAcceptanceScenarios.allSatisfy {
            ids.contains($0.id)
        })
        #expect(Set(scenarios.compactMap(\.rootSection)) == Set(NavigationSection.allCases))
        #expect(scenarios.contains { $0.surface == .about })
        #expect(scenarios.contains { $0.surface == .menuBarExtra })
        #expect(Set(scenarios.compactMap(\.overlayState)) == Set(UINextOverlayFixtureState.allCases))
    }

    @MainActor
    @Test
    func evidenceExportIsDisabledWithoutTheExplicitEnvironmentVariable() throws {
        let invalidScenario = UINextVisualFixtureScenario(
            id: "must-not-render",
            surface: .about,
            width: 0,
            height: 0,
            theme: .light,
            localeIdentifier: "en",
            displayScale: 1,
            accessibilityMode: .standard
        )

        let outputs = try UINextVisualFixtureEvidenceExporter.exportIfRequested(
            environment: [:],
            scenarios: [invalidScenario]
        )

        #expect(outputs.isEmpty)
    }

    @MainActor
    @Test
    func evidenceExportWritesValidPNGsWithStableNamesToAnExplicitTempDirectory() throws {
        let fileManager = FileManager.default
        let outputDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "apc-ui-next-evidence-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: outputDirectory) }
        let scenarios = [
            aboutScenario(id: "evidence.about.en", locale: "en", displayScale: 1),
            aboutScenario(id: "evidence.about.zh-Hans", locale: "zh-Hans", displayScale: 1),
        ]

        let outputs = try UINextVisualFixtureEvidenceExporter.exportIfRequested(
            environment: [
                UINextVisualFixtureEvidenceExporter.environmentKey: outputDirectory.path
            ],
            scenarios: scenarios,
            fileManager: fileManager
        )

        #expect(outputs.map(\.lastPathComponent) == [
            "evidence-about-en.png",
            "evidence-about-zh-hans.png",
        ])
        #expect(outputs.allSatisfy { fileManager.fileExists(atPath: $0.path) })
        for output in outputs {
            let data = try Data(contentsOf: output)
            #expect(data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
            #expect(NSImage(data: data) != nil)
        }
    }

    @MainActor
    @Test
    func configuredEnvironmentExportsTheCurrentRepresentativeCatalog() async throws {
        let environment = ProcessInfo.processInfo.environment
        let outputs = try UINextVisualFixtureEvidenceExporter.exportIfRequested(
            environment: environment
        )

        guard let configuredPath = environment[
            UINextVisualFixtureEvidenceExporter.environmentKey
        ], !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            #expect(outputs.isEmpty)
            return
        }
        let scenarios = UINextVisualFixtureEvidenceExporter.evidenceScenarios
        #expect(outputs.count == scenarios.count)
        #expect(outputs.map(\.lastPathComponent) == (try scenarios.map {
            try UINextVisualFixtureEvidenceExporter.stableFileName(for: $0)
        }))
        await Task.yield()
    }

    @MainActor
    @Test
    func rendererScopesActualFixtureLayoutToEnglishAndChinese() throws {
        let englishScenario = aboutScenario(
            id: "render.about.en",
            locale: "en",
            displayScale: 1
        )
        let chineseScenario = aboutScenario(
            id: "render.about.zh-Hans",
            locale: "zh-Hans",
            displayScale: 1
        )

        let english = try UINextVisualFixtureRenderer.render(englishScenario)
        let chinese = try UINextVisualFixtureRenderer.render(chineseScenario)

        #expect(english.resolvedLocaleIdentifier == "en")
        #expect(chinese.resolvedLocaleIdentifier == "zh-Hans")
        #expect(english.localizationProbe == ["Pet Library", "About Agent Pet Companion"])
        #expect(chinese.localizationProbe == ["宠物库", "关于 Agent Pet Companion"])
        #expect(!english.pngData.isEmpty)
        #expect(!chinese.pngData.isEmpty)
        #expect(english.pngData != chinese.pngData)
    }

    @MainActor
    @Test
    func rendererConsumesLogicalSizeAndOneOrTwoTimesPixelScale() throws {
        for displayScale: CGFloat in [1, 2] {
            let scenario = aboutScenario(
                id: "render.scale.\(Int(displayScale))",
                locale: "en",
                displayScale: displayScale
            )
            let rendered = try UINextVisualFixtureRenderer.render(scenario)

            #expect(rendered.logicalSize == CGSize(width: 440, height: 360))
            #expect(rendered.pixelWidth == 440 * Int(displayScale))
            #expect(rendered.pixelHeight == 360 * Int(displayScale))
        }
    }

    @MainActor
    @Test
    func sevenOverlayStatesCaptureDistinctPetFramePixelsWithoutWaitingForMetal() async throws {
        var captures: [Data] = []
        for state in UINextOverlayFixtureState.allCases {
            let scenario = UINextVisualFixtureScenario(
                id: "render.overlay.\(state.rawValue)",
                surface: .overlay(state),
                width: 520,
                height: 280,
                theme: .light,
                localeIdentifier: "en",
                displayScale: 1,
                accessibilityMode: .standard,
                agentSource: .codex,
                activeSessionCount: 0
            )
            captures.append(try UINextVisualFixtureRenderer.render(scenario).pngData)
            await Task.yield()
        }

        #expect(Set(captures).count == UINextOverlayFixtureState.allCases.count)
    }

    @MainActor
    @Test
    func nonAttentionMultiSessionFixturesProduceDistinctStackedAndExpandedPixels() throws {
        let scenarios = UINextVisualFixtureCatalog.overlayAcceptanceScenarios
        let stackedScenario = try #require(scenarios.first {
            $0.overlayGroupPresentation == .stacked
                && $0.overlayControlPresentation == .resting
                && $0.activeSessionCount == 8
        })
        let expandedScenario = try #require(scenarios.first {
            $0.overlayGroupPresentation == .expanded
                && $0.activeSessionCount == 8
        })
        let stacked = try UINextVisualFixtureRenderer.render(stackedScenario)
        let expanded = try UINextVisualFixtureRenderer.render(expandedScenario)
        let stackedPixels = try UINextPNGPixelMap(pngData: stacked.pngData)
        let expandedPixels = try UINextPNGPixelMap(pngData: expanded.pngData)
        let bubbleRegion = CGRect(x: 0.01, y: 0.02, width: 0.62, height: 0.96)

        #expect(stacked.logicalSize == expanded.logicalSize)
        #expect(stacked.pngData != expanded.pngData)
        #expect(stackedPixels.differingPixelFraction(
            from: expandedPixels,
            in: bubbleRegion,
            channelThreshold: 8
        ) > 0.08)
    }

    @MainActor
    @Test
    func mixedAgentAcceptanceRendersEveryProductionBubbleGroupWithVisibleInk() throws {
        let scenario = try #require(
            UINextVisualFixtureCatalog.overlayAcceptanceScenarios.first {
                $0.overlayContentProfile == .mixedAgents
            }
        )
        let rendered = try UINextVisualFixtureRenderer.render(scenario)
        let pixels = try UINextPNGPixelMap(pngData: rendered.pngData)
        let contents = UINextVisualFixtureData.mixedAgentBubbleContents
        let canvasBounds = CGRect(origin: .zero, size: rendered.logicalSize)
        let bubbleStackRegion = CGRect(x: 0.02, y: 0.02, width: 0.60, height: 0.96)
        let stack = pixels.statistics(in: bubbleStackRegion)

        #expect(rendered.logicalSize == CGSize(width: 640, height: 720))
        #expect(!rendered.pngData.isEmpty)
        #expect(stack.nonDominantColorFraction > 0.04)
        #expect(stack.edgeFraction > 0.002)
        #expect(contents.count == 4)
        #expect(contents[0].source == .codex)
        #expect(contents[1].source == .claudeCode)
        #expect(contents[2].source == .pi)
        #expect(contents[3].isOmittedSummary)
        #expect(rendered.overlayBubbleRegions.map(\.contentID) == contents.map(\.id))

        var bubbleStackFrame = CGRect.null
        for (content, region) in zip(contents, rendered.overlayBubbleRegions) {
            #expect(region.contentID == content.id)
            #expect(region.frame.width > 0)
            #expect(region.frame.height > 0)
            #expect(region.frame.minX >= canvasBounds.minX)
            #expect(region.frame.minY >= canvasBounds.minY)
            #expect(region.frame.maxX <= canvasBounds.maxX)
            #expect(region.frame.maxY <= canvasBounds.maxY)
            bubbleStackFrame = bubbleStackFrame.union(region.frame)

            let contentFrame = region.frame.insetBy(
                dx: OverlayGeometry.bubbleLeadingPadding,
                dy: OverlayGeometry.bubbleVerticalPadding
            )
            let statistics = pixels.statistics(
                in: normalizedRegion(contentFrame, in: rendered.logicalSize)
            )
            #expect(statistics.nonDominantColorFraction > 0.04)
            #expect(statistics.edgeFraction > 0.002)
        }

        #expect(!bubbleStackFrame.isNull)
        #expect(bubbleStackFrame.minX > canvasBounds.minX)
        #expect(bubbleStackFrame.minY > canvasBounds.minY)
        #expect(bubbleStackFrame.maxX < canvasBounds.maxX)
        #expect(bubbleStackFrame.maxY < canvasBounds.maxY)
    }

    @MainActor
    @Test
    func hoverAndResizeFixturesRenderProductionControlsInThePetControlRegion() throws {
        let scenarios = UINextVisualFixtureCatalog.overlayAcceptanceScenarios
        let hoveredScenario = try #require(scenarios.first {
            $0.overlayControlPresentation == .hovered
        })
        let resizingScenario = try #require(scenarios.first {
            $0.overlayControlPresentation == .resizing
        })
        let restingScenario = UINextVisualFixtureScenario(
            id: "render.overlay.controls-resting",
            surface: .overlay(.tool),
            width: hoveredScenario.width,
            height: hoveredScenario.height,
            theme: hoveredScenario.theme,
            localeIdentifier: hoveredScenario.localeIdentifier,
            displayScale: hoveredScenario.displayScale,
            accessibilityMode: hoveredScenario.accessibilityMode,
            agentSource: hoveredScenario.agentSource,
            activeSessionCount: hoveredScenario.activeSessionCount,
            overlayGroupPresentation: hoveredScenario.overlayGroupPresentation,
            overlayControlPresentation: .resting
        )
        let resting = try UINextPNGPixelMap(
            pngData: UINextVisualFixtureRenderer.render(restingScenario).pngData
        )
        let hovered = try UINextPNGPixelMap(
            pngData: UINextVisualFixtureRenderer.render(hoveredScenario).pngData
        )
        let resizing = try UINextPNGPixelMap(
            pngData: UINextVisualFixtureRenderer.render(resizingScenario).pngData
        )
        let petControlRegion = CGRect(x: 0.68, y: 0.05, width: 0.31, height: 0.90)

        #expect(resting.differingPixelFraction(
            from: hovered,
            in: petControlRegion,
            channelThreshold: 8
        ) > 0.002)
        #expect(hovered.differingPixelFraction(
            from: resizing,
            in: petControlRegion,
            channelThreshold: 8
        ) > 0.0005)
    }

    @MainActor
    @Test
    func everyRepresentativeScenarioCompletesAnOffscreenRenderTransaction() async throws {
        for scenario in UINextVisualFixtureCatalog.regressionScenarios {
            let rendered = try UINextVisualFixtureRenderer.render(scenario)

            #expect(rendered.id == scenario.id)
            #expect(rendered.resolvedLocaleIdentifier == scenario.localeIdentifier)
            #expect(rendered.accessibilityPresentation == scenario.accessibilityPresentation)
            #expect(!rendered.pngData.isEmpty)
            // Each AppKit transaction is synchronous on the main actor. Yield
            // between scenarios so unrelated lifecycle/hover tasks retain
            // their real timing semantics during the parallel full test run.
            await Task.yield()
        }
    }

    private func aboutScenario(
        id: String,
        locale: String,
        displayScale: CGFloat
    ) -> UINextVisualFixtureScenario {
        UINextVisualFixtureScenario(
            id: id,
            surface: .about,
            width: 440,
            height: 360,
            theme: .light,
            localeIdentifier: locale,
            displayScale: displayScale,
            accessibilityMode: .standard
        )
    }

    private func rootScenario(
        id: String,
        section: NavigationSection,
        theme: AppearanceTheme,
        serviceState: PetCoreOperationalState,
        displayScale: CGFloat
    ) -> UINextVisualFixtureScenario {
        UINextVisualFixtureScenario(
            id: id,
            surface: .root(section),
            width: 1_120,
            height: 720,
            theme: theme,
            localeIdentifier: "en",
            displayScale: displayScale,
            accessibilityMode: .standard,
            serviceState: serviceState
        )
    }

    private func overlayScenario(
        id: String,
        mode: UINextAccessibilityFixtureMode
    ) -> UINextVisualFixtureScenario {
        UINextVisualFixtureScenario(
            id: id,
            surface: .overlay(.tool),
            width: 520,
            height: 280,
            theme: .light,
            localeIdentifier: "en",
            displayScale: 1,
            accessibilityMode: mode,
            agentSource: .codex,
            activeSessionCount: 1
        )
    }

    private func normalizedRegion(
        _ region: CGRect,
        in logicalSize: CGSize
    ) -> CGRect {
        CGRect(
            x: region.minX / logicalSize.width,
            y: region.minY / logicalSize.height,
            width: region.width / logicalSize.width,
            height: region.height / logicalSize.height
        )
    }
}

private enum UINextPNGPixelMapError: Error {
    case invalidPNG
    case contextAllocationFailed
}

private struct UINextPNGRegionStatistics {
    let meanLuminance: Double
    let nonDominantColorFraction: Double
    let edgeFraction: Double
}

private struct UINextPNGPixelMap {
    let width: Int
    let height: Int
    private let rgba: [UInt8]

    init(pngData: Data) throws {
        guard let image = NSBitmapImageRep(data: pngData)?.cgImage else {
            throw UINextPNGPixelMapError.invalidPNG
        }
        let pixelWidth = image.width
        let pixelHeight = image.height
        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
            )
            return true
        }
        guard rendered else {
            throw UINextPNGPixelMapError.contextAllocationFailed
        }
        width = pixelWidth
        height = pixelHeight
        rgba = pixels
    }

    var minimumAlpha: UInt8 {
        stride(from: 3, to: rgba.count, by: 4)
            .reduce(UInt8.max) { min($0, rgba[$1]) }
    }

    func statistics(in normalizedRegion: CGRect) -> UINextPNGRegionStatistics {
        let region = pixelRegion(normalizedRegion)
        var luminanceTotal = 0.0
        var sampleCount = 0
        var edgeCount = 0
        var edgeComparisons = 0
        var buckets: [Int: Int] = [:]

        for y in region.minY ..< region.maxY {
            for x in region.minX ..< region.maxX {
                let pixel = color(x: x, y: y)
                let luminance = pixel.luminance
                luminanceTotal += luminance
                sampleCount += 1
                let bucket = (Int(pixel.red >> 4) << 8)
                    | (Int(pixel.green >> 4) << 4)
                    | Int(pixel.blue >> 4)
                buckets[bucket, default: 0] += 1

                if x + 1 < region.maxX {
                    edgeComparisons += 1
                    if abs(luminance - color(x: x + 1, y: y).luminance) >= 18 {
                        edgeCount += 1
                    }
                }
                if y + 1 < region.maxY {
                    edgeComparisons += 1
                    if abs(luminance - color(x: x, y: y + 1).luminance) >= 18 {
                        edgeCount += 1
                    }
                }
            }
        }

        let dominantCount = buckets.values.max() ?? 0
        return UINextPNGRegionStatistics(
            meanLuminance: luminanceTotal / Double(max(1, sampleCount)),
            nonDominantColorFraction: 1 - (Double(dominantCount) / Double(max(1, sampleCount))),
            edgeFraction: Double(edgeCount) / Double(max(1, edgeComparisons))
        )
    }

    func differingPixelFraction(
        from other: Self,
        in normalizedRegion: CGRect,
        channelThreshold: Int
    ) -> Double {
        guard width == other.width, height == other.height else { return 1 }
        let region = pixelRegion(normalizedRegion)
        var differingPixels = 0
        var sampleCount = 0
        for y in region.minY ..< region.maxY {
            for x in region.minX ..< region.maxX {
                let lhs = color(x: x, y: y)
                let rhs = other.color(x: x, y: y)
                sampleCount += 1
                if abs(Int(lhs.red) - Int(rhs.red)) >= channelThreshold
                    || abs(Int(lhs.green) - Int(rhs.green)) >= channelThreshold
                    || abs(Int(lhs.blue) - Int(rhs.blue)) >= channelThreshold
                    || abs(Int(lhs.alpha) - Int(rhs.alpha)) >= channelThreshold
                {
                    differingPixels += 1
                }
            }
        }
        return Double(differingPixels) / Double(max(1, sampleCount))
    }

    private func pixelRegion(_ normalizedRegion: CGRect) -> PixelRegion {
        PixelRegion(
            minX: max(0, min(width - 1, Int(normalizedRegion.minX * Double(width)))),
            maxX: max(1, min(width, Int(normalizedRegion.maxX * Double(width)))),
            minY: max(0, min(height - 1, Int(normalizedRegion.minY * Double(height)))),
            maxY: max(1, min(height, Int(normalizedRegion.maxY * Double(height))))
        )
    }

    private func color(x: Int, y: Int) -> PixelColor {
        let offset = ((y * width) + x) * 4
        return PixelColor(
            red: rgba[offset],
            green: rgba[offset + 1],
            blue: rgba[offset + 2],
            alpha: rgba[offset + 3]
        )
    }

    private struct PixelRegion {
        let minX: Int
        let maxX: Int
        let minY: Int
        let maxY: Int
    }

    private struct PixelColor {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8

        var luminance: Double {
            (0.2126 * Double(red))
                + (0.7152 * Double(green))
                + (0.0722 * Double(blue))
        }
    }
}
