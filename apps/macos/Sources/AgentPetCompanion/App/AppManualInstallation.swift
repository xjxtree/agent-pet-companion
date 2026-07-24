import AppKit
import Darwin
import Foundation
import SwiftUI

struct AppManualInstallationRequest: Equatable, Identifiable, Sendable {
    enum Origin: String, Equatable, Sendable {
        case updateDownload
        case launchedOutsideApplications
        case secondaryDownloadedBuild
        case invalidReleaseBundle
        case restartFailed
    }

    let origin: Origin
    let version: String?
    let candidateBundlePath: String?

    var id: String {
        [
            origin.rawValue,
            version ?? "unknown",
            candidateBundlePath ?? "downloads"
        ].joined(separator: ":")
    }

    var candidateBundleURL: URL? {
        candidateBundlePath.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
    }
}

enum AppInstallationPolicy {
    static let officialBundleIdentifier = "dev.agentpet.companion"
    static let canonicalBundleURL = URL(
        fileURLWithPath: "/Applications/AgentPetCompanion.app",
        isDirectory: true
    )

    static func isCanonicalBundle(
        _ bundleURL: URL,
        canonicalBundleURL: URL = canonicalBundleURL
    ) -> Bool {
        let bundleURL = bundleURL.standardizedFileURL
        guard bundleURL.path == canonicalBundleURL.standardizedFileURL.path else {
            return false
        }
        var status = stat()
        guard lstat(bundleURL.path, &status) == 0 else {
            // Pure policy tests may use a not-yet-created canonical path.
            return true
        }
        return status.st_mode & S_IFMT == S_IFDIR
    }

    static func requiresManualInstallation(
        bundleURL: URL = Bundle.main.bundleURL,
        manifest: RuntimeReleaseManifest? = bundleLocalManifest(),
        infoReleaseChannel: String? = Bundle.main.object(
            forInfoDictionaryKey: "APCReleaseChannel"
        ) as? String,
        canonicalBundleURL: URL = canonicalBundleURL
    ) -> Bool {
        (manifest?.releaseChannel == "release" || infoReleaseChannel == "release")
            && !isCanonicalBundle(bundleURL, canonicalBundleURL: canonicalBundleURL)
    }

    static func primaryLaunchRequest(
        bundleURL: URL = Bundle.main.bundleURL,
        manifest: RuntimeReleaseManifest? = bundleLocalManifest(),
        infoBundleIdentifier: String? = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleIdentifier"
        ) as? String,
        infoReleaseChannel: String? = Bundle.main.object(
            forInfoDictionaryKey: "APCReleaseChannel"
        ) as? String,
        infoBuildID: String? = Bundle.main.object(
            forInfoDictionaryKey: "APCBuildID"
        ) as? String,
        infoVersion: String? = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
        infoBuild: String? = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String,
        canonicalBundleURL: URL = canonicalBundleURL
    ) -> AppManualInstallationRequest? {
        let claimsRelease = manifest?.releaseChannel == "release"
            || infoReleaseChannel == "release"
        guard claimsRelease else { return nil }

        guard normalized(infoBundleIdentifier) == officialBundleIdentifier,
              infoReleaseChannel == "release",
              let manifest,
              manifest.releaseChannel == "release",
              normalized(infoBuildID) == manifest.buildID,
              normalized(infoVersion) == manifest.appVersion,
              normalized(infoBuild) == manifest.appBuild
        else {
            return AppManualInstallationRequest(
                origin: .invalidReleaseBundle,
                version: normalized(infoVersion) ?? manifest?.appVersion,
                candidateBundlePath: bundleURL.standardizedFileURL.path
            )
        }

        guard !isCanonicalBundle(
            bundleURL,
            canonicalBundleURL: canonicalBundleURL
        ) else { return nil }
        return AppManualInstallationRequest(
            origin: .launchedOutsideApplications,
            version: manifest.appVersion,
            candidateBundlePath: bundleURL.standardizedFileURL.path
        )
    }

    static func bundleLocalManifest(
        bundleURL: URL = Bundle.main.bundleURL
    ) -> RuntimeReleaseManifest? {
        try? RuntimeReleaseManifest.read(
            from: bundleURL.appendingPathComponent(
                "Contents/Resources/runtime-manifest.json"
            )
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
enum AppManualInstallationActions {
    static func revealCandidate(_ request: AppManualInstallationRequest) {
        guard let candidateURL = request.candidateBundleURL else {
            openDownloads()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([candidateURL])
    }

    static func openDownloads() {
        let downloadsURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first
        if let downloadsURL {
            NSWorkspace.shared.open(downloadsURL)
        }
    }

    static func openApplications() {
        NSWorkspace.shared.open(
            URL(fileURLWithPath: "/Applications", isDirectory: true)
        )
    }

    static func openLatestRelease() {
        guard let url = URL(
            string: "https://github.com/xjxtree/agent-pet-companion/releases/latest"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct AppManualInstallationGuideView: View {
    let request: AppManualInstallationRequest
    var allowsDismissal = true
    var dismiss: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                reassurance
                if request.origin == .invalidReleaseBundle {
                    invalidPackageActions
                } else if request.origin == .restartFailed {
                    restartFailureActions
                } else {
                    steps
                    actions
                }
            }
            .padding(32)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 520, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("app-update.manual-installation-guide")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            APCBrandMark(size: 52)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(APCLocalization.text(
                    request.origin == .invalidReleaseBundle
                        ? .appUpdatePackageInvalidTitle
                        : request.origin == .restartFailed
                        ? .appUpdateRestartFailedTitle
                        : .appUpdateInstallTitle
                ))
                    .font(.title2.weight(.semibold))
                if let version = request.version {
                    Text(APCLocalization.format(.appUpdateInstallVersionFormat, version))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(APCLocalization.text(
                    request.origin == .invalidReleaseBundle
                        ? .appUpdatePackageInvalidSubtitle
                        : request.origin == .restartFailed
                        ? .appUpdateRestartFailedSubtitle
                        : .appUpdateInstallSubtitle
                ))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var reassurance: some View {
        Label(
            APCLocalization.text(.appUpdateDataReassurance),
            systemImage: "checkmark.shield.fill"
        )
        .font(.callout.weight(.medium))
        .foregroundStyle(APCDesign.accent)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(APCDesign.accent.opacity(0.08), in: RoundedRectangle(
            cornerRadius: 12,
            style: .continuous
        ))
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 16) {
            installationStep(
                number: 1,
                title: APCLocalization.text(.appUpdateInstallStepDownloadTitle),
                detail: APCLocalization.text(.appUpdateInstallStepDownloadDetail)
            )
            installationStep(
                number: 2,
                title: APCLocalization.text(.appUpdateInstallStepReplaceTitle),
                detail: APCLocalization.text(.appUpdateInstallStepReplaceDetail)
            )
            installationStep(
                number: 3,
                title: APCLocalization.text(.appUpdateInstallStepOpenTitle),
                detail: APCLocalization.text(.appUpdateInstallStepOpenDetail)
            )
        }
    }

    private func installationStep(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(APCDesign.accent, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            APCLocalization.format(.appUpdateInstallStepAccessibilityFormat, number, title, detail)
        )
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                candidateButton
                applicationsButton
                Spacer(minLength: 8)
                dismissalButton
            }
            VStack(alignment: .leading, spacing: 10) {
                candidateButton
                applicationsButton
                dismissalButton
            }
        }
    }

    private var invalidPackageActions: some View {
        HStack(spacing: 10) {
            candidateButton
            Spacer(minLength: 8)
            if allowsDismissal {
                dismissalButton
            } else {
                Button(APCLocalization.text(.appActionQuit)) {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("app-update.invalid-package-quit")
            }
        }
    }

    private var restartFailureActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                applicationsButton
                candidateButton
                Spacer(minLength: 8)
                if allowsDismissal {
                    dismissalButton
                }
                Button(APCLocalization.text(.appActionQuit)) {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("app-update.restart-failed-quit")
            }
            VStack(alignment: .leading, spacing: 10) {
                applicationsButton
                candidateButton
                if allowsDismissal {
                    dismissalButton
                }
                Button(APCLocalization.text(.appActionQuit)) {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("app-update.restart-failed-quit")
            }
        }
    }

    private var candidateButton: some View {
        Button {
            if request.origin == .invalidReleaseBundle {
                AppManualInstallationActions.openLatestRelease()
            } else {
                AppManualInstallationActions.revealCandidate(request)
            }
        } label: {
            Label(
                APCLocalization.text(
                    request.origin == .invalidReleaseBundle
                        ? .appUpdateRedownloadAction
                        : request.candidateBundleURL == nil
                        ? .appUpdateOpenDownloads
                        : .appUpdateRevealNewApp
                ),
                systemImage: request.origin == .invalidReleaseBundle
                    ? "arrow.down.circle"
                    : "folder"
            )
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("app-update.reveal-candidate")
    }

    private var applicationsButton: some View {
        Button {
            AppManualInstallationActions.openApplications()
        } label: {
            Label(
                APCLocalization.text(.appUpdateOpenApplications),
                systemImage: "square.grid.2x2"
            )
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("app-update.open-applications")
    }

    @ViewBuilder
    private var dismissalButton: some View {
        if allowsDismissal {
            Button(APCLocalization.text(.appUpdateLater)) {
                dismiss()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("app-update.install-later")
        }
    }
}
