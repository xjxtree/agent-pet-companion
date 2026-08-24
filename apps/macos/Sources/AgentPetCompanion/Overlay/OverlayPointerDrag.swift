//! Pointer ownership, gesture classification, drag sessions, and
//! direct-manipulation move planning for the overlay composition.
import AppKit
import AgentPetCompanionCore
import Combine
import CoreGraphics
import Foundation
import QuartzCore

struct OverlayPetInteractionPresentation: Equatable, Sendable {
    var stateName: String
    var entryID: String
}

enum OverlayPetInteractionPolicy {
    static let directionThresholdPt: CGFloat = 0.5
    static let pressFeedbackDurationSeconds = 0.16
}

enum OverlayPointerMaskState: Equatable, Sendable {
    case missing
    case valid
    case stale
}

struct OverlayPointerOwnershipInput: Equatable, Sendable {
    var overlayVisible: Bool
    var activeInteractionID: UUID?
    var maskState: OverlayPointerMaskState
    var validMaskPixelIsOpaque: Bool
    var pointerInBubble: Bool
    var pointerInMenu: Bool
    var pointerInGeometricPetRegion: Bool
}

enum OverlayPointerOwnership: Equatable, Sendable {
    case passthrough
    case pet
    case auxiliarySurface
    case activeLease(UUID)

    var isOwnedByOverlay: Bool {
        self != .passthrough
    }
}

/// The only policy that decides whether the overlay owns a pointer location.
/// AppKit event routing remains a defensive delivery mechanism; it does not
/// redefine mask fallback or active-gesture ownership.
enum OverlayPointerOwnershipPolicy {
    static func resolve(
        _ input: OverlayPointerOwnershipInput
    ) -> OverlayPointerOwnership {
        guard input.overlayVisible else { return .passthrough }
        if let interactionID = input.activeInteractionID {
            return .activeLease(interactionID)
        }
        if input.pointerInBubble || input.pointerInMenu {
            return .auxiliarySurface
        }
        guard input.pointerInGeometricPetRegion else {
            return .passthrough
        }
        switch input.maskState {
        case .valid:
            return input.validMaskPixelIsOpaque ? .pet : .passthrough
        case .missing, .stale:
            return .pet
        }
    }
}

enum OverlayPetPointerGesture {
    static let dragThreshold: CGFloat = 4

    static func exceedsDragThreshold(from start: CGPoint, to current: CGPoint) -> Bool {
        hypot(current.x - start.x, current.y - start.y) >= dragThreshold
    }

    /// AppKit reports a double-click as click counts one and two. Performing
    /// the primary action only for the first release preserves responsive
    /// single-click behavior without toggling the bubble back on the second.
    static func shouldPerformPrimaryClick(clickCount: Int, didDrag: Bool) -> Bool {
        !didDrag && clickCount == 1
    }
}

/// Converts a pointer sample out of CoreGraphics' global event space into the
/// AppKit screen space the drag anchor uses. A drag translates the host window
/// on every display tick, so a sample derived from the window's own coordinate
/// system silently subtracts a move it never observed; taking the event's
/// absolute location instead keeps the grab point fixed under the pointer no
/// matter how far or how fast the composition has moved.
enum OverlayPointerCoordinateSpace {
    static func screenPoint(
        forGlobalEventLocation location: CGPoint,
        zeroOriginScreenFrame: CGRect
    ) -> CGPoint {
        CGPoint(
            x: location.x,
            y: zeroOriginScreenFrame.maxY - location.y
        )
    }
}

enum OverlayPointerGesturePhase: Equatable, Sendable {
    case idle
    case pressed
    case dragging
    case finalized
}

struct OverlayDragSession: Equatable, Sendable {
    let interactionID: UUID
    let startPointerScreen: CGPoint
    let startAnchorScreen: CGPoint
    var latestPointerScreen: CGPoint
    let startDisplayID: String
    var hasCrossedThreshold: Bool
    private(set) var phase: OverlayPointerGesturePhase

    init(
        interactionID: UUID = UUID(),
        startPointerScreen: CGPoint,
        startAnchorScreen: CGPoint,
        startDisplayID: String
    ) {
        self.interactionID = interactionID
        self.startPointerScreen = startPointerScreen
        self.startAnchorScreen = startAnchorScreen
        latestPointerScreen = startPointerScreen
        self.startDisplayID = startDisplayID
        hasCrossedThreshold = false
        phase = .pressed
    }

    var proposedAnchorScreen: CGPoint {
        CGPoint(
            x: startAnchorScreen.x
                + latestPointerScreen.x
                - startPointerScreen.x,
            y: startAnchorScreen.y
                + latestPointerScreen.y
                - startPointerScreen.y
        )
    }

    mutating func updatePointer(_ point: CGPoint) {
        guard phase != .finalized else { return }
        latestPointerScreen = point
        if !hasCrossedThreshold {
            hasCrossedThreshold = OverlayPetPointerGesture.exceedsDragThreshold(
                from: startPointerScreen,
                to: point
            )
            if hasCrossedThreshold {
                phase = .dragging
            }
        }
    }

    mutating func compareAndFinalize(interactionID: UUID) -> Bool {
        guard self.interactionID == interactionID,
              phase != .finalized else { return false }
        phase = .finalized
        return true
    }
}

struct OverlayDragDisplay: Equatable, Sendable {
    let id: String
    let frame: CGRect
    let visibleFrame: CGRect
}

/// Display geometry and presentation cadence captured once per gesture rather
/// than per pointer sample. Rebuilding the screen list and asking CoreGraphics
/// for the selected display mode on every event costs a window-server round
/// trip inside the pointer handler, which is exactly the per-event main-thread
/// work that makes a fast drag stutter. The desktop arrangement only changes
/// through a screen-parameter notification, so a gesture-scoped snapshot stays
/// authoritative for the whole drag.
struct OverlayDragDisplayCatalog: Equatable, Sendable {
    let displays: [OverlayDragDisplay]
    let fallbackCadence: OverlayDisplayRefreshCadence
    private let cadences: [String: OverlayDisplayRefreshCadence]

    init(
        displays: [OverlayDragDisplay],
        cadences: [String: OverlayDisplayRefreshCadence],
        fallbackCadence: OverlayDisplayRefreshCadence
    ) {
        self.displays = displays
        self.cadences = cadences
        self.fallbackCadence = fallbackCadence
    }

    func cadence(for displayID: String?) -> OverlayDisplayRefreshCadence {
        guard let displayID, let cadence = cadences[displayID] else {
            return fallbackCadence
        }
        return cadence
    }
}

/// Selects the drag display from injected geometry so crossing a display edge
/// does not replace the absolute pointer anchor with window-relative deltas.
enum OverlayDragScreenResolver {
    static func resolve(
        pointer: CGPoint,
        proposedPetCenter: CGPoint,
        displays: [OverlayDragDisplay],
        fallbackDisplayID: String?
    ) -> OverlayDragDisplay? {
        displays.first { $0.frame.contains(pointer) }
            ?? displays.first { $0.frame.contains(proposedPetCenter) }
            ?? fallbackDisplayID.flatMap { fallbackID in
                displays.first { $0.id == fallbackID }
            }
            ?? displays.first
    }
}
