//! Observable control/interaction presentation state for the
//! overlay composition.
import AppKit
import AgentPetCompanionCore
import Combine
import CoreGraphics
import Foundation
import QuartzCore

enum OverlayControlVisibility {
    static let hoverShowDelay = Duration.zero
    static let hoverHideDelay = Duration.milliseconds(300)

    static func isVisible(
        pointerNearPet: Bool,
        petDragInProgress: Bool,
        keyboardFocusActive: Bool = false
    ) -> Bool {
        pointerNearPet || petDragInProgress || keyboardFocusActive
    }

    static func transitionDelay(showing: Bool, forced: Bool) -> Duration {
        forced ? .zero : (showing ? hoverShowDelay : hoverHideDelay)
    }
}

/// Motion values shared by SwiftUI content and the AppKit overlay panels.
enum OverlayMotion {
    static let controlFadeDuration: TimeInterval = 0.14
    static let controlFadeDelay = Duration.milliseconds(140)
    static let bubbleLayoutDuration: TimeInterval = 0.16
    static let bubbleLayoutDelay = Duration.milliseconds(160)
    static let reducedMotionCrossfadeDuration: TimeInterval = 0.16
    static let reducedMotionCrossfadeDelay = Duration.milliseconds(160)
    static let reducedMotionCrossfadeHalfDelay = Duration.milliseconds(80)
}

/// One presentation state coordinates every transient overlay control. Pointer
/// hover begins the visual fade immediately, while pointer exit is delayed to
/// avoid flicker between the pet and its controls. Keyboard focus and an active
/// pet drag remain immediate.
@MainActor
final class OverlayControlPresentationState: ObservableObject {
    typealias TransitionSleeper = @MainActor @Sendable (Duration) async throws -> Void

    enum Region: Hashable {
        case pet
        case bubble
        case menu
    }

    @Published private(set) var isVisible = false
    @Published private(set) var keyboardNavigationActive = false
    var visibilityDidChange: (() -> Void)?

    private var hoveredRegions: Set<Region> = []
    private var focusedRegions: Set<Region> = []
    private var activeRegions: Set<Region> = []
    private var transitionTask: Task<Void, Never>?
    private let transitionSleeper: TransitionSleeper

    init(
        transitionSleeper: @escaping TransitionSleeper = { delay in
            try await Task.sleep(for: delay)
        }
    ) {
        self.transitionSleeper = transitionSleeper
    }

    func setHovered(_ region: Region, _ hovered: Bool) {
        update(region, enabled: hovered, in: &hoveredRegions)
        scheduleVisibilityUpdate()
    }

    func setFocused(_ region: Region, _ focused: Bool) {
        update(region, enabled: focused, in: &focusedRegions)
        let nextKeyboardNavigationActive = !focusedRegions.isEmpty
        if keyboardNavigationActive != nextKeyboardNavigationActive {
            keyboardNavigationActive = nextKeyboardNavigationActive
        }
        scheduleVisibilityUpdate()
    }

    func setActive(_ region: Region, _ active: Bool) {
        update(region, enabled: active, in: &activeRegions)
        scheduleVisibilityUpdate()
    }

    func reset() {
        transitionTask?.cancel()
        transitionTask = nil
        hoveredRegions.removeAll()
        focusedRegions.removeAll()
        activeRegions.removeAll()
        keyboardNavigationActive = false
        setVisible(false)
    }

    private func update(
        _ region: Region,
        enabled: Bool,
        in regions: inout Set<Region>
    ) {
        if enabled {
            regions.insert(region)
        } else {
            regions.remove(region)
        }
    }

    private func scheduleVisibilityUpdate() {
        transitionTask?.cancel()
        let shouldShow = !hoveredRegions.isEmpty
            || !focusedRegions.isEmpty
            || !activeRegions.isEmpty
        let forced = !focusedRegions.isEmpty || !activeRegions.isEmpty
        guard shouldShow != isVisible else { return }
        let delay = OverlayControlVisibility.transitionDelay(
            showing: shouldShow,
            forced: forced
        )
        if delay == .zero {
            setVisible(shouldShow)
            return
        }
        let transitionSleeper = transitionSleeper
        transitionTask = Task { @MainActor [weak self] in
            do {
                try await transitionSleeper(delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            let latestShouldShow = !self.hoveredRegions.isEmpty
                || !self.focusedRegions.isEmpty
                || !self.activeRegions.isEmpty
            guard latestShouldShow == shouldShow else { return }
            self.setVisible(shouldShow)
        }
    }

    private func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        visibilityDidChange?()
    }
}

/// Keeps high-frequency display-size preview out of `AppStore`. Only the pet
/// canvas observes this state, so slider movement does not invalidate the
/// control center, bubbles, or unrelated overlay content.
@MainActor
final class OverlayInteractionPresentationState: ObservableObject {
    private struct DisplayWidthPresentation: Equatable {
        var displayWidthPt: CGFloat
        var petLocalCenter: CGPoint
    }

    @Published private var displayWidthPresentation: DisplayWidthPresentation?
    @Published private(set) var petInteraction: OverlayPetInteractionPresentation?
    @Published private(set) var pressFeedbackActive = false
    private var dragInteractionID: UUID?
    private var lastDragCenter: CGPoint?

    func resolvedDisplayWidthPt(fallback: CGFloat) -> CGFloat {
        displayWidthPresentation?.displayWidthPt ?? fallback
    }

    func resolvedPetLocalCenter(fallback: CGPoint) -> CGPoint {
        displayWidthPresentation?.petLocalCenter ?? fallback
    }

    func present(displayWidthPt: CGFloat, petLocalCenter: CGPoint) {
        let next = DisplayWidthPresentation(
            displayWidthPt: displayWidthPt,
            petLocalCenter: petLocalCenter
        )
        guard displayWidthPresentation != next else { return }
        displayWidthPresentation = next
    }

    func clearDisplayWidthPreview() {
        guard displayWidthPresentation != nil else { return }
        displayWidthPresentation = nil
    }

    func acknowledge(reduceMotion: Bool) {
        guard !reduceMotion, dragInteractionID == nil else { return }
        let interactionID = UUID()
        petInteraction = OverlayPetInteractionPresentation(
            stateName: "acknowledge",
            entryID: "interaction:\(interactionID.uuidString):acknowledge"
        )
    }

    func beginPressFeedback(enabled: Bool, reduceMotion: Bool) {
        guard enabled, !reduceMotion, dragInteractionID == nil else { return }
        pressFeedbackActive = true
    }

    func beginDrag(interactionID: UUID, center: CGPoint) {
        dragInteractionID = interactionID
        lastDragCenter = center
        petInteraction = nil
    }

    func updateDrag(interactionID: UUID, center: CGPoint) {
        guard dragInteractionID == interactionID else { return }
        pressFeedbackActive = false
        let priorCenter = lastDragCenter ?? center
        lastDragCenter = center
        let horizontalDelta = center.x - priorCenter.x
        guard abs(horizontalDelta) >= OverlayPetInteractionPolicy.directionThresholdPt else {
            return
        }
        let stateName = horizontalDelta < 0 ? "drag_left" : "drag_right"
        guard petInteraction?.stateName != stateName else { return }
        petInteraction = OverlayPetInteractionPresentation(
            stateName: stateName,
            entryID: "interaction:\(interactionID.uuidString):\(stateName)"
        )
    }

    func endDrag(interactionID: UUID?) {
        if let interactionID, dragInteractionID != interactionID { return }
        dragInteractionID = nil
        lastDragCenter = nil
        pressFeedbackActive = false
        if petInteraction?.stateName == "drag_left"
            || petInteraction?.stateName == "drag_right"
        {
            petInteraction = nil
        }
    }

    func complete(entryID: String) {
        guard petInteraction?.entryID == entryID,
              petInteraction?.stateName == "acknowledge"
        else { return }
        petInteraction = nil
    }
}
