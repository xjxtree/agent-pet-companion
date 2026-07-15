import Foundation

/// Resolves SwiftPM resources from the location used by the hand-built macOS
/// app bundle. SwiftPM's generated `Bundle.module` accessor looks beside
/// `Bundle.main.bundleURL`, while a conventional `.app` stores resources under
/// `Contents/Resources`. Prefer the packaged location and retain
/// `Bundle.module` as the test/development fallback.
enum APCResourceBundle {
    static let bundleName = "AgentPetCompanion_AgentPetCompanion.bundle"

    static let shared: Bundle = {
        if let url = packagedBundleURL(in: Bundle.main.resourceURL),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    static func packagedBundleURL(in resourceRoot: URL?) -> URL? {
        guard let resourceRoot else { return nil }
        let candidate = resourceRoot.appendingPathComponent(bundleName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: candidate.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return nil
        }
        return candidate
    }

    static func resourceURL(_ relativePath: String) -> URL {
        shared.bundleURL.appendingPathComponent(relativePath)
    }
}
