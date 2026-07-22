import AppKit
import SwiftUI
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("Control Center render smoke")
struct ControlCenterRenderSmokeTests {
    @MainActor
    @Test
    func featurePagesRenderAtTheDefaultDetailSize() throws {
        let store = makeStore()
        let pages: [(name: String, view: AnyView)] = [
            ("library", AnyView(PetLibraryView())),
            ("maker", AnyView(AIPetMakerView())),
            ("configuration", AnyView(BehaviorSettingsView())),
            ("configuration-messages", AnyView(BehaviorSettingsView(initialSection: .messages))),
            ("connections", AnyView(AgentConnectionsView())),
            ("diagnostics", AnyView(ServiceDiagnosticsView())),
        ]

        for page in pages {
            let bitmap = try render(page.view, store: store)
            #expect(bitmap.pixelsWide > 0)
            #expect(bitmap.pixelsHigh > 0)
            #expect(hasVisibleContent(bitmap))
            try writeCaptureIfRequested(bitmap, name: page.name)
        }
    }

    @MainActor
    private func render(_ view: AnyView, store: AppStore) throws -> NSBitmapImageRep {
        let size = CGSize(width: 856, height: 720)
        let root = view
            .environmentObject(store)
            .environment(\.controlCenterShellMode, .allColumns)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(origin: .zero, size: size)
        let captureWindow: NSWindow? = if ProcessInfo.processInfo.environment[
            "APC_CAPTURE_CONTROL_CENTER_DIR"
        ] != nil {
            NSWindow(
                contentRect: hostingView.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
        } else {
            nil
        }
        captureWindow?.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        if captureWindow != nil {
            // Sidebar-backed Lists finish materializing on the next AppKit
            // pass. The window remains hidden and never becomes key.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            hostingView.layoutSubtreeIfNeeded()
        }

        let bitmap = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        withExtendedLifetime(captureWindow) {}
        return bitmap
    }

    private func hasVisibleContent(_ bitmap: NSBitmapImageRep) -> Bool {
        let stride = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 32)
        for x in Swift.stride(from: 0, to: bitmap.pixelsWide, by: stride) {
            for y in Swift.stride(from: 0, to: bitmap.pixelsHigh, by: stride) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                if color.alphaComponent > 0.05 { return true }
            }
        }
        return false
    }

    private func writeCaptureIfRequested(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment[
            "APC_CAPTURE_CONTROL_CENTER_DIR"
        ] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("\(name).png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    @MainActor
    private func makeStore() -> AppStore {
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            )
        )
        store.pets = capturePets
        return store
    }

    private var capturePets: [PetSummary] {
        let environment = ProcessInfo.processInfo.environment
        return [
            PetSummary(
                id: "pet_bytebudcodex",
                name: "Bytebud 字节芽",
                style: "半写实",
                quality: .high,
                renderSize: RenderSize(width: 384, height: 416),
                petpackPath: environment["APC_CAPTURE_PRIMARY_PETPACK"] ?? "",
                coverPath: environment["APC_CAPTURE_PRIMARY_COVER"] ?? "",
                origin: .externalImport,
                revisionID: "rev_capture_bytebud",
                revisionCount: 1,
                active: true,
                createdAt: "2026-07-22T00:00:00Z"
            ),
            PetSummary(
                id: "pet_xingwutuanzi",
                name: "星雾团子",
                style: "半写实",
                quality: .high,
                renderSize: RenderSize(width: 384, height: 416),
                petpackPath: environment["APC_CAPTURE_SECONDARY_PETPACK"] ?? "",
                coverPath: environment["APC_CAPTURE_SECONDARY_COVER"] ?? "",
                origin: .verifiedSkillSource,
                revisionID: "rev_capture_xingwu",
                revisionCount: 1,
                active: false,
                createdAt: "2026-07-22T00:00:00Z"
            ),
        ]
    }
}
