import Foundation
import Testing
@testable import AgentPetCompanion

@Suite("Packaged resource bundle")
struct PackagedResourceBundleTests {
    @Test(arguments: [false, true])
    func readsResourcesFromFlatAndMacOSBundles(usesContentsDirectory: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apc-resource-bundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(APCResourceBundle.bundleName, isDirectory: true)
        let contents = usesContentsDirectory
            ? bundleURL.appendingPathComponent("Contents", isDirectory: true)
            : bundleURL
        let resources = usesContentsDirectory
            ? contents.appendingPathComponent("Resources", isDirectory: true)
            : contents
        let relativePath = "Localization/Overlay/en.lproj/Overlay.strings"
        let fixture = resources.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fixture.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "dev.agentpet.resource-fixture.\(UUID().uuidString)",
                "CFBundlePackageType": "BNDL"
            ],
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let expected = Data("\"fixture\" = \"Resource found\";".utf8)
        try expected.write(to: fixture)

        let packagedURL = try #require(APCResourceBundle.packagedBundleURL(in: root))
        let bundle = try #require(Bundle(url: packagedURL))
        let resolved = APCResourceBundle.resourceURL(relativePath, in: bundle)
        #expect(try Data(contentsOf: resolved) == expected)
    }
}
