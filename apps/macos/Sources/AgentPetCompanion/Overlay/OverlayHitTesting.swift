//! Pet frame hit-testing: visual envelope, alpha mask, and the
//! animation identity used for stale-mask detection.
import AppKit
import AgentPetCompanionCore
import Combine
import CoreGraphics
import Foundation
import QuartzCore

struct OverlayPetVisualEnvelope: Equatable, Sendable {
    var canvasSize: CGSize
    var visibleBounds: CGRect
}

/// A one-bit-per-pixel interaction mask extracted while a pet frame is
/// decoded. Rows are stored in the same top-to-bottom order as the source
/// `CGImage`; callers query it with bottom-left image coordinates so the
/// conversion to the Metal renderer's coordinate system stays explicit.
struct OverlayPetAlphaMask: Equatable, Sendable {
    static let interactionAlphaThreshold: UInt8 = 2

    let pixelWidth: Int
    let pixelHeight: Int
    private let opaqueBits: [UInt8]

    var storageByteCount: Int { opaqueBits.count }

    init?(
        pixelWidth: Int,
        pixelHeight: Int,
        opaqueBits: [UInt8]
    ) {
        guard let requiredByteCount = Self.requiredByteCount(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        ), opaqueBits.count == requiredByteCount else {
            return nil
        }
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.opaqueBits = opaqueBits
    }

    /// Test/support initializer for top-to-bottom, one-byte alpha samples.
    init?(
        pixelWidth: Int,
        pixelHeight: Int,
        alphaValuesTopToBottom: [UInt8],
        alphaThreshold: UInt8 = interactionAlphaThreshold
    ) {
        guard
            let pixelCount = Self.pixelCount(pixelWidth: pixelWidth, pixelHeight: pixelHeight),
            alphaValuesTopToBottom.count == pixelCount,
            let byteCount = Self.requiredByteCount(
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        else {
            return nil
        }
        var bits = [UInt8](repeating: 0, count: byteCount)
        for index in 0..<pixelCount where alphaValuesTopToBottom[index] > alphaThreshold {
            bits[index >> 3] |= UInt8(1 << (index & 7))
        }
        self.init(pixelWidth: pixelWidth, pixelHeight: pixelHeight, opaqueBits: bits)
    }

    func containsOpaquePixel(atBottomLeftPoint point: CGPoint) -> Bool {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0,
              point.x < CGFloat(pixelWidth), point.y < CGFloat(pixelHeight) else {
            return false
        }
        let x = Int(point.x.rounded(.down))
        let bottomRow = Int(point.y.rounded(.down))
        let topRow = pixelHeight - 1 - bottomRow
        let index = topRow * pixelWidth + x
        return opaqueBits[index >> 3] & UInt8(1 << (index & 7)) != 0
    }

    static func requiredByteCount(pixelWidth: Int, pixelHeight: Int) -> Int? {
        guard let pixels = pixelCount(pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
            return nil
        }
        let (adjusted, overflow) = pixels.addingReportingOverflow(7)
        return overflow ? nil : adjusted / 8
    }

    private static func pixelCount(pixelWidth: Int, pixelHeight: Int) -> Int? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let (count, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        return overflow ? nil : count
    }
}

/// Describes the exact decoded frame currently presented by the Metal view.
/// `frameID` lets the renderer and AppStore coalesce repeated display-link
/// draws without comparing the mask payload for every authored frame.
struct OverlayPetFrameHitTest: Equatable, Sendable {
    let frameID: UUID
    let canvasSize: CGSize
    let alphaMask: OverlayPetAlphaMask

    init(
        frameID: UUID = UUID(),
        canvasSize: CGSize,
        alphaMask: OverlayPetAlphaMask
    ) {
        self.frameID = frameID
        self.canvasSize = canvasSize
        self.alphaMask = alphaMask
    }
}

enum OverlayPetAnimationIdentity {
    static func stateEntryID(for state: ActiveAgentState?) -> String {
        guard let state else { return "idle" }
        if let projectedID = nonEmpty(state.overlayDisplay?.stateEntryID) {
            return projectedID
        }
        let event = state.event
        switch event.eventType {
        case .start:
            return "idle"
        case .thinking, .plan:
            let activation = nonEmpty(state.sessionActivatedAt)
                ?? event.id
            return scopedEntryID(
                event: event,
                sessionID: state.sessionID ?? event.sessionID,
                marker: activation,
                reaction: "thinking"
            )
        case .done:
            let completion = nonEmpty(state.sessionActivatedAt)
                ?? event.id
            return scopedEntryID(
                event: event,
                sessionID: state.sessionID ?? event.sessionID,
                marker: completion,
                reaction: "done"
            )
        case .tool, .waiting, .failed:
            // PetCore owns the projected identity, including the tool activity
            // run that lets genuinely new tool work replay its entry burst. A
            // single event carries no run history, so this compatibility
            // fallback keeps one stable identity per reaction.
            return event.eventType.rawValue
        }
    }

    private static func scopedEntryID(
        event: AgentEvent,
        sessionID: String?,
        marker: String,
        reaction: String
    ) -> String {
        [
            reaction,
            event.source.rawValue,
            nonEmpty(sessionID),
            marker
        ]
        .compactMap { $0 }
        .joined(separator: ":")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

}
