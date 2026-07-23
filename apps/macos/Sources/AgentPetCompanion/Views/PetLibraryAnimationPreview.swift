import AgentPetCompanionCore
import MetalKit
import SwiftUI

enum PetLibraryPreviewPolicy {
    static func playbackProfile(for pet: PetSummary) -> FpsProfile {
        pet.nativeFPS == FpsProfile.smooth.fps ? .smooth : .standard
    }

    static func canOpenAssets(assetWarning: PetAssetWarning?) -> Bool {
        assetWarning == nil
    }

    static func canRender(assetWarning: PetAssetWarning?) -> Bool {
        canOpenAssets(assetWarning: assetWarning)
    }

    static func loadIfValidated<Value>(
        assetWarning: PetAssetWarning?,
        _ load: () -> Value?
    ) -> Value? {
        guard canOpenAssets(assetWarning: assetWarning) else { return nil }
        return load()
    }
}

/// A single, library-scoped idle preview. It owns an independent renderer and
/// never writes to AppStore or the desktop overlay's visual-envelope state.
struct PetLibraryAnimationPreview: View {
    let pet: PetSummary
    let assetWarning: PetAssetWarning?

    @State private var rendererHasContent = false

    init(pet: PetSummary, assetWarning: PetAssetWarning? = nil) {
        self.pet = pet
        self.assetWarning = assetWarning
    }

    var body: some View {
        ZStack {
            PetCoverImage(
                pet: pet,
                assetWarning: assetWarning,
                fallbackScale: 0.44
            )
                .opacity(rendererHasContent ? 0 : 1)

            if PetLibraryPreviewPolicy.canRender(assetWarning: assetWarning) {
                PetLibraryIdleMetalView(pet: pet) { hasContent in
                    rendererHasContent = hasContent
                }
                .id(previewIdentity)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .onAppear {
            rendererHasContent = false
        }
        .onChange(of: previewIdentity) {
            rendererHasContent = false
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(APCLocalization.format(
            .libraryAnimationAccessibilityFormat,
            pet.name
        ))
        .accessibilityIdentifier("pet-library.inspector.idle-preview")
    }

    private var previewIdentity: String {
        [
            pet.id,
            pet.petpackPath,
            pet.coverPath,
            pet.revisionID ?? "legacy",
            assetWarning?.fingerprint ?? "validated",
        ].joined(separator: ":")
    }
}

private struct PetLibraryIdleMetalView: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pet: PetSummary
    let onRendererContentChanged: @MainActor (Bool) -> Void

    func makeCoordinator() -> PetMetalFrameRenderer {
        PetMetalFrameRenderer()
    }

    @MainActor
    func makeNSView(context: Context) -> MTKView {
        context.coordinator.makeView()
    }

    @MainActor
    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.configure(
            view: view,
            pet: pet,
            stateName: "idle",
            stateEntryID: "library-hero-idle:\(pet.id):\(pet.revisionID ?? pet.petpackPath)",
            fpsProfile: PetLibraryPreviewPolicy.playbackProfile(for: pet),
            active: true,
            reduceMotion: reduceMotion,
            onVisualEnvelopeChanged: { envelope in
                onRendererContentChanged(envelope != nil)
            }
        )
    }

    @MainActor
    static func dismantleNSView(_ view: MTKView, coordinator: PetMetalFrameRenderer) {
        coordinator.suspendPipeline()
        view.isPaused = true
        view.delegate = nil
    }
}
