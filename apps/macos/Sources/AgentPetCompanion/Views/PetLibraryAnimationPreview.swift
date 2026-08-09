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
    private(set) var selectedIdentity: PetPreviewRenderIdentity?
    private(set) var presentedIdentity: PetPreviewRenderIdentity?

    init(selectedIdentity: PetPreviewRenderIdentity? = nil) {
        self.selectedIdentity = selectedIdentity
    }

    func hasPresentedContent(for identity: PetPreviewRenderIdentity) -> Bool {
        selectedIdentity == identity && presentedIdentity == identity
    }

    mutating func select(_ identity: PetPreviewRenderIdentity) {
        guard selectedIdentity != identity else { return }
        selectedIdentity = identity
        presentedIdentity = nil
    }

    @discardableResult
    mutating func receive(
        hasContent: Bool,
        for identity: PetPreviewRenderIdentity
    ) -> Bool {
        guard selectedIdentity == identity else { return false }
        let nextIdentity = hasContent ? identity : nil
        guard presentedIdentity != nextIdentity else { return false }
        presentedIdentity = nextIdentity
        return true
    }
}

enum PetLibraryPreviewPlaybackPolicy {
    static func returnsToIdle(after mode: PetPlaybackMode) -> Bool {
        mode == .burstThenIdle || mode == .onceThenReturn
    }

    static func entryDurationMS(for timing: PetStateTiming) -> Int? {
        guard returnsToIdle(after: timing.playback.mode) else { return nil }
        return timing.frameDurationsMS.reduce(0, +)
            * max(1, timing.playback.entryRepeatCount ?? 1)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pet: PetSummary
    let action: PetAnimationAction
    let assetWarning: PetAssetWarning?

    @State private var contentState: PetPreviewContentState
    @State private var settledSelectionIdentity: PetPreviewRenderIdentity?

    init(
        pet: PetSummary,
        action: PetAnimationAction = PetLibraryPreviewActionPolicy.defaultAction,
        assetWarning: PetAssetWarning? = nil
    ) {
        self.pet = pet
        self.action = action
        self.assetWarning = assetWarning
        _contentState = State(initialValue: PetPreviewContentState(
            selectedIdentity: PetPreviewRenderIdentity(
                pet: pet,
                stateName: action.rawValue,
                assetWarning: assetWarning
            )
        ))
    }

    var body: some View {
        let selectionIdentity = selectedPreviewIdentity
        let presentedAction = settledSelectionIdentity == selectionIdentity
            ? PetAnimationAction.idle
            : action
        let identity = previewIdentity(for: presentedAction)
        let rendererHasContent = contentState.hasPresentedContent(for: identity)
        let entryID = renderEntryID(for: presentedAction)
        ZStack {
            if PetLibraryPreviewPolicy.canRender(assetWarning: assetWarning) {
                PetLibraryMetalView(
                    pet: pet,
                    action: presentedAction,
                    stateEntryID: entryID,
                    onPlaybackCompleted: { completedEntryID, mode in
                        guard completedEntryID == entryID,
                              PetLibraryPreviewPlaybackPolicy.returnsToIdle(after: mode)
                        else { return }
                        settledSelectionIdentity = selectionIdentity
                    },
                    onRendererContentChanged: { hasContent in
                        contentState.receive(hasContent: hasContent, for: identity)
                    }
                )
                .id(identity)
            }

            if !rendererHasContent {
                Color(nsColor: .textBackgroundColor)
                    .overlay {
                        PetActionFallbackImage(
                            pet: pet,
                            stateName: presentedAction.rawValue,
                            assetWarning: assetWarning,
                            fallbackScale: 0.44
                        )
                    }
            }
        }
        // The opaque fallback mask lets Metal acquire and present a drawable
        // without ever compositing its retained prior frame underneath the
        // replacement image during an action or pet handoff.
        .transaction { transaction in
            transaction.animation = nil
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PetLibraryPreviewActionPolicy.accessibilityLabel(
            petName: pet.name,
            action: action
        ))
        .accessibilityIdentifier("pet-library.animation-preview")
        .onChange(of: selectionIdentity) { _, _ in
            settledSelectionIdentity = nil
        }
        .onChange(of: identity) { _, nextIdentity in
            contentState.select(nextIdentity)
        }
        .task(id: finitePlaybackTaskID(
            for: selectionIdentity,
            rendererHasContent: rendererHasContent
        )) {
            let timing = pet.timing(for: action.rawValue)
            guard rendererHasContent,
                  let durationMS = PetLibraryPreviewPlaybackPolicy.entryDurationMS(
                    for: timing
                  )
            else { return }
            do {
                try await Task.sleep(for: .milliseconds(durationMS))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            settledSelectionIdentity = selectionIdentity
        }
    }

    private var selectedPreviewIdentity: PetPreviewRenderIdentity {
        previewIdentity(for: action)
    }

    private func previewIdentity(for action: PetAnimationAction) -> PetPreviewRenderIdentity {
        PetPreviewRenderIdentity(
            pet: pet,
            stateName: action.rawValue,
            assetWarning: assetWarning
        )
    }

    private func renderEntryID(for action: PetAnimationAction) -> String {
        "library-preview-\(action.rawValue):\(pet.id):\(pet.revisionID ?? pet.petpackPath)"
    }

    private func finitePlaybackTaskID(
        for selectionIdentity: PetPreviewRenderIdentity,
        rendererHasContent: Bool
    ) -> String {
        "\(selectionIdentity.assetKey):\(selectionIdentity.assetWarningFingerprint ?? "ok"):\(reduceMotion):\(rendererHasContent)"
    }
}

private struct PetLibraryMetalView: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pet: PetSummary
    let action: PetAnimationAction
    let stateEntryID: String
    let onPlaybackCompleted: @MainActor (String, PetPlaybackMode) -> Void
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
            stateEntryID: stateEntryID,
            active: true,
            reduceMotion: reduceMotion,
            onPlaybackCompleted: onPlaybackCompleted,
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
