import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

private let controlCenterIdentifier = "dev.agentpet.companion.control-center"

private func fail(_ message: String) -> Never {
    fputs("main window cold-launch probe failed: \(message)\n", stderr)
    exit(1)
}

private func copyAttribute(
    _ element: AXUIElement,
    _ attribute: String
) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
    ) == .success else {
        return nil
    }
    return value
}

private func stringAttribute(
    _ element: AXUIElement,
    _ attribute: String
) -> String {
    copyAttribute(element, attribute) as? String ?? ""
}

private func pointAttribute(
    _ element: AXUIElement,
    _ attribute: String
) -> CGPoint? {
    guard let value = copyAttribute(element, attribute) else { return nil }
    var result = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &result) else {
        return nil
    }
    return result
}

private func sizeAttribute(
    _ element: AXUIElement,
    _ attribute: String
) -> CGSize? {
    guard let value = copyAttribute(element, attribute) else { return nil }
    var result = CGSize.zero
    guard AXValueGetValue(value as! AXValue, .cgSize, &result) else {
        return nil
    }
    return result
}

private struct VisibleWindow {
    let id: CGWindowID
    let layer: Int
    let alpha: Double
    let bounds: CGRect
}

private func visibleWindows(ownerPID: pid_t) -> [VisibleWindow] {
    let options = CGWindowListOption(
        arrayLiteral: .optionOnScreenOnly,
        .excludeDesktopElements
    )
    let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
        as? [[String: Any]] ?? []
    return rows.compactMap { row in
        guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                == ownerPID,
              let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let boundsDictionary = row[kCGWindowBounds as String]
                as? [String: Any],
              let bounds = CGRect(
                dictionaryRepresentation: boundsDictionary as CFDictionary
              )
        else {
            return nil
        }
        return VisibleWindow(
            id: id,
            layer: layer,
            alpha: (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0,
            bounds: bounds
        )
    }
}

private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) <= 3
        && abs(lhs.minY - rhs.minY) <= 3
        && abs(lhs.width - rhs.width) <= 3
        && abs(lhs.height - rhs.height) <= 3
}

private func pixelRange(_ image: CGImage) -> (opaqueFraction: Double, range: Int)? {
    let width = 160
    let height = max(1, Int(Double(width) * Double(image.height) / Double(image.width)))
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }
    context.interpolationQuality = .low
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var opaquePixels = 0
    var minimumLuminance = 255
    var maximumLuminance = 0
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        let alpha = Int(pixels[offset + 3])
        guard alpha > 16 else { continue }
        opaquePixels += 1
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        let luminance = (54 * red + 183 * green + 19 * blue) / 256
        minimumLuminance = min(minimumLuminance, luminance)
        maximumLuminance = max(maximumLuminance, luminance)
    }
    return (
        Double(opaquePixels) / Double(width * height),
        maximumLuminance - minimumLuminance
    )
}

@main
private struct MainWindowColdLaunchProbe {
    static func main() async {
        guard let pidValue = ProcessInfo.processInfo.environment["APP_PID"],
              let appPID = Int32(pidValue),
              let app = NSRunningApplication(processIdentifier: appPID),
              !app.isTerminated
        else {
            fail("owned App PID is unavailable")
        }

        let axApp = AXUIElementCreateApplication(appPID)
        var controlCenter: AXUIElement?
        var controlCenterFrame: CGRect?
        var visibleControlCenter: VisibleWindow?
        var overlayWasPresented = false

        for _ in 0..<160 {
            let windows = copyAttribute(axApp, kAXWindowsAttribute)
                as? [AXUIElement] ?? []
            let exactWindows = windows.filter {
                stringAttribute($0, kAXIdentifierAttribute)
                    == controlCenterIdentifier
            }
            if exactWindows.count > 1 {
                fail("more than one exact Control Center window is registered")
            }
            if let exactWindow = exactWindows.first,
               let position = pointAttribute(exactWindow, kAXPositionAttribute),
               let size = sizeAttribute(exactWindow, kAXSizeAttribute) {
                let frame = CGRect(origin: position, size: size)
                let appWindows = visibleWindows(ownerPID: appPID)
                let layerZero = appWindows.first {
                    $0.layer == 0
                        && $0.alpha > 0
                        && $0.bounds.width >= 760
                        && $0.bounds.height >= 520
                        && framesMatch($0.bounds, frame)
                }
                let hasOverlay = appWindows.contains {
                    $0.layer > 0
                        && $0.alpha > 0
                        && $0.bounds.width > 20
                        && $0.bounds.height > 20
                }
                if let layerZero {
                    controlCenter = exactWindow
                    controlCenterFrame = frame
                    visibleControlCenter = layerZero
                }
                overlayWasPresented = overlayWasPresented || hasOverlay
            }
            if controlCenter != nil, visibleControlCenter != nil,
               overlayWasPresented {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard let controlCenter, let controlCenterFrame,
              let visibleControlCenter
        else {
            fail("exact layer-0 Control Center never became visible")
        }
        guard visibleControlCenter.alpha > 0,
              visibleControlCenter.layer == 0,
              controlCenterFrame.width >= 760,
              controlCenterFrame.height >= 520
        else {
            fail("Control Center layer, alpha, or frame invariant failed")
        }
        guard overlayWasPresented else {
            fail("overlay never became visible before focus verification")
        }

        // Give the first overlay ordering turn time to settle. Passive panels
        // must not change the exact focused window after this point.
        try? await Task.sleep(for: .milliseconds(250))
        guard let focusedWindow = copyAttribute(
            axApp,
            kAXFocusedWindowAttribute
        ) as! AXUIElement?,
        stringAttribute(focusedWindow, kAXIdentifierAttribute)
            == controlCenterIdentifier,
        CFEqual(focusedWindow, controlCenter)
        else {
            fail("overlay presentation displaced Control Center keyboard focus")
        }

        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let captureWindow = shareableContent.windows.first(where: {
                $0.windowID == visibleControlCenter.id
            }) else {
                fail("ScreenCaptureKit could not resolve the exact Control Center")
            }
            let filter = SCContentFilter(desktopIndependentWindow: captureWindow)
            let configuration = SCStreamConfiguration()
            configuration.width = min(1_280, max(1, Int(controlCenterFrame.width * 2)))
            configuration.height = min(1_024, max(1, Int(controlCenterFrame.height * 2)))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            guard let result = pixelRange(image),
                  result.opaqueFraction >= 0.80,
                  result.range >= 12
            else {
                fail("captured Control Center pixels are blank or transparent")
            }
        } catch {
            fail("ScreenCaptureKit pixel proof failed: \(error.localizedDescription)")
        }

        print(
            "Control Center cold-launch probe ok: pid=\(appPID) "
                + "window=\(visibleControlCenter.id)"
        )
    }
}
