import AgentPetCompanionCore
import AppKit
import MetalKit
import SwiftUI

enum PetLibraryPreviewPolicy {
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

struct PetPreviewRenderIdentity: Hashable, Sendable {
    let assetKey: String
    let assetWarningFingerprint: String?

    init(
        pet: PetSummary,
        stateName: String,
        assetWarning: PetAssetWarning?
    ) {
        assetKey = PetFrameLoadRequest(
            pet: pet,
            stateName: stateName,
            timing: pet.timing(for: stateName)
        ).assetKey
        assetWarningFingerprint = assetWarning?.fingerprint
    }
}

struct PetPreviewContentState: Equatable {
    private(set) var presentedIdentities: Set<PetPreviewRenderIdentity> = []

    func hasPresentedContent(for identity: PetPreviewRenderIdentity) -> Bool {
        presentedIdentities.contains(identity)
    }

    mutating func receive(
        hasContent: Bool,
        for identity: PetPreviewRenderIdentity
    ) {
        if hasContent {
            presentedIdentities.insert(identity)
        } else {
            presentedIdentities.remove(identity)
        }
    }
}

struct PetActionFallbackImage: View {
    let pet: PetSummary
    let stateName: String
    let assetWarning: PetAssetWarning?
    let fallbackScale: CGFloat

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(6)
        } else {
            MissingPetCoverPlaceholder(scale: fallbackScale)
        }
    }

    private var image: NSImage? {
        let frameURLs = PetAssetLocator.frameURLs(for: pet, stateName: stateName)
        guard !frameURLs.isEmpty else { return nil }
        let representativeIndex = min(
            pet.timing(for: stateName).reducedMotionFrameIndex,
            frameURLs.count - 1
        )
        return PetLibraryPreviewPolicy.loadIfValidated(assetWarning: assetWarning) {
            NSImage(contentsOf: frameURLs[representativeIndex])
        }
    }
}

/// A library-scoped action preview. It owns an independent renderer and never
/// writes to AppStore or the desktop overlay's visual-envelope state.
struct PetLibraryAnimationPreview: View {
    let pet: PetSummary
    let action: PetAnimationAction
    let assetWarning: PetAssetWarning?

    @State private var contentState = PetPreviewContentState()

    init(
        pet: PetSummary,
        action: PetAnimationAction = PetLibraryPreviewActionPolicy.defaultAction,
        assetWarning: PetAssetWarning? = nil
    ) {
        self.pet = pet
        self.action = action
        self.assetWarning = assetWarning
    }

    var body: some View {
        let identity = previewIdentity
        ZStack {
            PetActionFallbackImage(
                pet: pet,
                stateName: action.rawValue,
                assetWarning: assetWarning,
                fallbackScale: 0.44
            )
                .opacity(contentState.hasPresentedContent(for: identity) ? 0 : 1)

            if PetLibraryPreviewPolicy.canRender(assetWarning: assetWarning) {
                PetLibraryMetalView(pet: pet, action: action) { hasContent in
                    contentState.receive(hasContent: hasContent, for: identity)
                }
                .id(identity)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PetLibraryPreviewActionPolicy.accessibilityLabel(
            petName: pet.name,
            action: action
        ))
        .accessibilityIdentifier("pet-library.animation-preview")
    }

    private var previewIdentity: PetPreviewRenderIdentity {
        PetPreviewRenderIdentity(
            pet: pet,
            stateName: action.rawValue,
            assetWarning: assetWarning
        )
    }
}

private struct PetLibraryMetalView: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pet: PetSummary
    let action: PetAnimationAction
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
            stateName: action.rawValue,
            stateEntryID: "library-preview-\(action.rawValue):\(pet.id):\(pet.revisionID ?? pet.petpackPath)",
            active: true,
            reduceMotion: reduceMotion,
            onVisualEnvelopeChanged: { _ in },
            onFrameContentChanged: onRendererContentChanged
        )
    }

    @MainActor
    static func dismantleNSView(_ view: MTKView, coordinator: PetMetalFrameRenderer) {
        coordinator.suspendPipeline()
        view.isPaused = true
        view.delegate = nil
    }
}
