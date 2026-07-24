import SwiftUI

struct AppUpdateAvailableBanner: View {
    @ObservedObject var updater: AppUpdateController
    let openUpdate: () -> Void

    var body: some View {
        if updater.shouldShowBanner, let release = updater.availableRelease {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(APCDesign.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(APCLocalization.format(
                        .appUpdateAvailableTitleFormat,
                        release.version.description
                    ))
                    .font(.callout.weight(.semibold))
                    Text(APCLocalization.text(.appUpdateDataReassurance))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(APCLocalization.text(.appUpdateViewAction)) {
                    openUpdate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("app-update.banner-open")
                Button {
                    updater.dismissBannerForCurrentLaunch()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(APCLocalization.text(.appUpdateLater))
                .accessibilityLabel(APCLocalization.text(.appUpdateLater))
                .accessibilityIdentifier("app-update.banner-dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(APCDesign.accent.opacity(0.08), in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            ))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(APCDesign.accent.opacity(0.3), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("app-update.banner")
        }
    }
}

struct AppUpdateSheetView: View {
    @ObservedObject var updater: AppUpdateController
    let beginDownload: (AppReleaseUpdate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            content
        }
        .padding(30)
        .frame(width: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("app-update.sheet")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            APCBrandMark(size: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(APCLocalization.text(.appUpdateCheckTitle))
                    .font(.title2.weight(.semibold))
                Text(APCLocalization.text(.appName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        if updater.isChecking {
            checkingContent
        } else if case let .failed(trigger, failure) = updater.state,
                  trigger == .manual {
            failureContent(failure)
        } else if let release = updater.availableRelease {
            availableContent(release)
        } else {
            switch updater.state {
            case let .upToDate(_, latestVersion, _):
                upToDateContent(latestVersion)
            case let .failed(_, failure):
                failureContent(failure)
            case .idle, .checking, .updateAvailable:
                checkingContent
            }
        }
    }

    private var checkingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(APCLocalization.text(.appUpdateCheckingTitle))
                .font(.headline)
            Text(APCLocalization.text(.appUpdateCheckingDetail))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("app-update.checking")
    }

    private func availableContent(_ release: AppReleaseUpdate) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(APCLocalization.format(
                    .appUpdateAvailableTitleFormat,
                    release.version.description
                ))
                .font(.title3.weight(.semibold))
                Text(APCLocalization.text(.appUpdateAvailableDetail))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label(
                APCLocalization.format(
                    .appUpdateAssetDetailFormat,
                    architectureTitle(release.asset.architecture),
                    ByteCountFormatter.string(
                        fromByteCount: release.asset.size,
                        countStyle: .file
                    )
                ),
                systemImage: "desktopcomputer"
            )
            .font(.callout)

            Label(
                APCLocalization.text(.appUpdateVerifiedRelease),
                systemImage: "checkmark.shield.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    downloadButton(release)
                    releaseNotesButton(release)
                    Spacer(minLength: 8)
                    laterButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    downloadButton(release)
                    releaseNotesButton(release)
                    laterButton
                }
            }
        }
        .accessibilityIdentifier("app-update.available")
    }

    private func upToDateContent(_ latestVersion: StableSemanticVersion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                APCLocalization.text(.appUpdateCurrentTitle),
                systemImage: "checkmark.circle.fill"
            )
            .font(.headline)
            .foregroundStyle(.green)
            Text(APCLocalization.format(
                .appUpdateCurrentDetailFormat,
                latestVersion.description
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            Button(APCLocalization.text(.commonClose)) {
                updater.dismissSheet()
            }
            .keyboardShortcut(.defaultAction)
        }
        .accessibilityIdentifier("app-update.current")
    }

    private func failureContent(_ failure: AppUpdateCheckFailure) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                APCLocalization.text(
                    failure == .downloadOpenFailed
                        ? .appUpdateDownloadFailureTitle
                        : .appUpdateFailureTitle
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.headline)
            .foregroundStyle(APCDesign.warning)
            Text(APCLocalization.text(
                failure.detailLocalizationKey
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if failure == .downloadOpenFailed,
                   let release = updater.availableRelease
                {
                    Button(APCLocalization.text(.appUpdateRetryDownloadAction)) {
                        beginDownload(release)
                    }
                    .buttonStyle(.borderedProminent)
                    Link(
                        APCLocalization.text(.appUpdateOpenReleasePageAction),
                        destination: release.releasePageURL
                    )
                    .buttonStyle(.bordered)
                } else {
                    Button(APCLocalization.text(.commonRetry)) {
                        updater.checkManually()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(APCLocalization.text(.commonClose)) {
                    updater.dismissSheet()
                }
            }
        }
        .accessibilityIdentifier("app-update.failure")
    }

    private func downloadButton(_ release: AppReleaseUpdate) -> some View {
        Button {
            beginDownload(release)
        } label: {
            Label(
                APCLocalization.text(.appUpdateDownloadAction),
                systemImage: "arrow.down.circle"
            )
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("app-update.download")
    }

    private func releaseNotesButton(_ release: AppReleaseUpdate) -> some View {
        Link(
            APCLocalization.text(.appUpdateReleaseNotesAction),
            destination: release.releasePageURL
        )
        .buttonStyle(.bordered)
        .accessibilityIdentifier("app-update.release-notes")
    }

    private var laterButton: some View {
        Button(APCLocalization.text(.appUpdateLater)) {
            updater.dismissSheet()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("app-update.later")
    }

    private func architectureTitle(_ architecture: AppReleaseArchitecture) -> String {
        APCLocalization.text(
            architecture == .arm64
                ? .appUpdateArchitectureAppleSilicon
                : .appUpdateArchitectureIntel
        )
    }
}

struct AppUpdateAboutSection: View {
    @ObservedObject var updater: AppUpdateController
    let checkForUpdates: () -> Void
    let presentUpdate: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button {
                checkForUpdates()
            } label: {
                if updater.isChecking {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(APCLocalization.text(.appUpdateCheckingAction))
                    }
                } else {
                    Text(APCLocalization.text(.appUpdateCheckAction))
                }
            }
            .disabled(updater.isChecking)
            .accessibilityIdentifier("about.check-for-updates")

            if let release = updater.availableRelease {
                Button(APCLocalization.format(
                    .appUpdateAvailableCompactFormat,
                    release.version.description
                )) {
                    presentUpdate()
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("about.update-available")
            }
        }
    }
}

struct AppUpdateMenuSection: View {
    @ObservedObject var updater: AppUpdateController
    let presentUpdate: () -> Void

    var body: some View {
        if let release = updater.availableRelease {
            Button(APCLocalization.format(
                .appUpdateAvailableCompactFormat,
                release.version.description
            )) {
                presentUpdate()
            }
            .accessibilityIdentifier("menubar.update-available")
            Divider()
        }
    }
}

struct AppUpdateStatusDot: View {
    @ObservedObject var updater: AppUpdateController

    var body: some View {
        if updater.isUpdateAvailable {
            Circle()
                .fill(APCDesign.accent)
                .frame(width: 6, height: 6)
                .overlay {
                    Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
                }
                .accessibilityHidden(true)
        }
    }
}

private extension AppUpdateCheckFailure {
    var detailLocalizationKey: APCLocalizationKey {
        switch self {
        case .transport, .unexpectedHTTPStatus:
            .appUpdateFailureNetworkDetail
        case .downloadOpenFailed:
            .appUpdateFailureOpenDetail
        default:
            .appUpdateFailureVerificationDetail
        }
    }
}
