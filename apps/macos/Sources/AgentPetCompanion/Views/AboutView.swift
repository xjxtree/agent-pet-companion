import SwiftUI

struct AboutView: View {
    @ObservedObject var store: AppStore

    private let projectURL = URL(string: "https://github.com/xjxtree/agent-pet-companion")!
    private let privacyURL = URL(string: "https://github.com/xjxtree/agent-pet-companion/blob/main/docs/integrations/agent-connectors.md#security-and-privacy-boundary")!
    private let licenseURL = URL(string: "https://github.com/xjxtree/agent-pet-companion/blob/main/LICENSE")!

    var body: some View {
        VStack(spacing: 16) {
            APCBrandMark(size: 72)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(APCLocalization.text(.appName))
                    .font(.title2.weight(.semibold))
                Text(versionLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text(APCLocalization.text(.aboutTagline))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)

            HStack(spacing: 8) {
                Link(APCLocalization.text(.aboutProject), destination: projectURL)
                Link(APCLocalization.text(.aboutPrivacy), destination: privacyURL)
                Link(APCLocalization.text(.aboutLicense), destination: licenseURL)
            }
            .buttonStyle(.bordered)

            Text(APCLocalization.text(.aboutCopyright))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(width: 440, height: 360)
        .accessibilityIdentifier("about.window")
    }

    private var versionLine: String {
        let bundle = Bundle.main
        let version = store.petCoreRuntimeInfo.version
            ?? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? APCLocalization.text(.aboutDevelopment)
        let build = store.petCoreRuntimeInfo.appBuild
            ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? APCLocalization.text(.aboutLocalBuild)
        return APCLocalization.format(.aboutVersionFormat, version, build)
    }
}
