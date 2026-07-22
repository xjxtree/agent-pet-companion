import AgentPetCompanionCore
import MetalKit
import SwiftUI

/// A single, inspector-scoped idle preview. It owns an independent renderer and
/// never writes to AppStore or the desktop overlay's visual-envelope state.
struct PetLibraryAnimationPreview: View {
    let pet: PetSummary

    @State private var rendererHasContent = false

    var body: some View {
        ZStack {
            PetCoverImage(pet: pet, fallbackScale: 0.44)
                .opacity(rendererHasContent ? 0 : 1)

            PetLibraryIdleMetalView(pet: pet) { hasContent in
                rendererHasContent = hasContent
            }
            .id(previewIdentity)
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
        [pet.id, pet.petpackPath, pet.coverPath, pet.revisionID ?? "legacy"].joined(separator: ":")
    }
}

private struct PetLibraryIdleMetalView: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.apcVisualAccessibilityOverrides) private var accessibilityOverrides
    let pet: PetSummary
    let onRendererContentChanged: @MainActor (Bool) -> Void

    private var reduceMotion: Bool {
        accessibilityOverrides.reduceMotion ?? systemReduceMotion
    }

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
            stateEntryID: "library-inspector-idle:\(pet.id):\(pet.revisionID ?? pet.petpackPath)",
            fpsProfile: .standard,
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
