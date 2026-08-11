import AppKit
import SwiftUI

struct PortableMakerSkillManagementSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUninstall = false

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    overviewCard
                    installationCard
                    statusNotice
                    if store.portableMakerSkillStatus?.managed == true {
                        managedContentNotice
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()
            actionBar
        }
        .frame(width: 640)
        .frame(minHeight: 520, idealHeight: 570, maxHeight: 680)
        .task {
            await store.refreshPortableMakerSkillStatus()
        }
        .confirmationDialog(
            APCLocalization.text(.studioPortableSkillUninstallConfirmTitle),
            isPresented: $confirmingUninstall,
            titleVisibility: .visible
        ) {
            Button(
                APCLocalization.text(.studioPortableSkillActionUninstall),
                role: .destructive
            ) {
                Task { await store.uninstallPortableMakerSkill() }
            }
            Button(APCLocalization.text(.commonCancel), role: .cancel) {}
        } message: {
            Text(APCLocalization.text(.studioPortableSkillUninstallConfirmDetail))
        }
        .interactiveDismissDisabled(store.portableMakerSkillOperation.isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maker.portable-skill.sheet")
    }

    private var sheetHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "wand.and.stars.inverse")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(APCLocalization.text(.studioPortableSkillTitle))
                    .font(.title3.weight(.semibold))
                Text(APCLocalization.text(.studioPortableSkillSubtitle))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            statusPill

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .disabled(store.portableMakerSkillOperation.isBusy)
            .help(APCLocalization.text(.commonClose))
            .accessibilityLabel(APCLocalization.text(.commonClose))
            .accessibilityIdentifier("maker.portable-skill.close")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                APCLocalization.text(.studioPortableSkillAboutTitle),
                systemImage: "sparkles"
            )
            .font(.headline)

            Text(APCLocalization.text(.studioPortableSkillAboutDetail))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(APCLocalization.text(.studioPortableSkillCompatibilityTitle))
                        .font(.callout.weight(.semibold))
                    Text(APCLocalization.text(.studioPortableSkillCompatibilityDetail))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "checklist")
                    .foregroundStyle(.blue)
            }
        }
        .portableSkillCard()
    }

    private var installationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(APCLocalization.text(.studioPortableSkillInstallationTitle))
                .font(.headline)

            LabeledContent(APCLocalization.text(.studioPortableSkillLocationLabel)) {
                Text(status?.targetDisplayPath ?? "~/agent/skills/agent-pet-maker")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            LabeledContent(APCLocalization.text(.studioPortableSkillBundledVersionLabel)) {
                Text(status?.expectedVersion ?? "—")
                    .font(.callout.monospacedDigit())
            }
            LabeledContent(APCLocalization.text(.studioPortableSkillInstalledVersionLabel)) {
                Text(
                    status?.installedVersion
                        ?? APCLocalization.text(.studioPortableSkillNotInstalled)
                )
                .font(.callout.monospacedDigit())
                .foregroundStyle(status?.installedVersion == nil ? .secondary : .primary)
            }
        }
        .portableSkillCard()
    }

    @ViewBuilder
    private var statusNotice: some View {
        if let failure = store.portableMakerSkillFailure {
            PortableSkillNotice(
                title: APCLocalization.text(.studioPortableSkillErrorTitle),
                detail: failureDetail(failure),
                systemImage: "exclamationmark.triangle.fill",
                color: APCDesign.destructive
            )
        } else if store.portableMakerSkillOperation == .checking && status == nil {
            PortableSkillNotice(
                title: APCLocalization.text(.studioPortableSkillChecking),
                detail: APCLocalization.text(.studioPortableSkillCheckingDetail),
                systemImage: "hourglass",
                color: .secondary
            )
        } else if let status {
            let presentation = status.state.presentation
            PortableSkillNotice(
                title: APCLocalization.text(presentation.titleKey),
                detail: APCLocalization.text(presentation.detailKey),
                systemImage: presentation.systemImage,
                color: presentation.color
            )
        }
    }

    private var managedContentNotice: some View {
        PortableSkillNotice(
            title: APCLocalization.text(.studioPortableSkillManagedTitle),
            detail: APCLocalization.text(.studioPortableSkillManagedDetail),
            systemImage: "arrow.triangle.2.circlepath",
            color: APCDesign.warning
        )
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await store.refreshPortableMakerSkillStatus() }
            } label: {
                Label(
                    APCLocalization.text(.studioPortableSkillActionRefresh),
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(store.portableMakerSkillOperation.isBusy)
            .accessibilityIdentifier("maker.portable-skill.refresh")

            if status?.targetExists == true {
                Button {
                    openSkillDirectory()
                } label: {
                    Label(
                        APCLocalization.text(.studioPortableSkillActionOpenFolder),
                        systemImage: "folder"
                    )
                }
                .disabled(store.portableMakerSkillOperation.isBusy)
                .accessibilityIdentifier("maker.portable-skill.open-folder")
            }

            if status?.canUninstall == true {
                Button(role: .destructive) {
                    confirmingUninstall = true
                } label: {
                    Label(
                        APCLocalization.text(.studioPortableSkillActionUninstall),
                        systemImage: "trash"
                    )
                }
                .disabled(store.portableMakerSkillOperation.isBusy)
                .accessibilityIdentifier("maker.portable-skill.uninstall")
            }

            Spacer()

            Button(APCLocalization.text(.commonClose)) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(store.portableMakerSkillOperation.isBusy)

            if let actionTitle = primaryActionTitle {
                Button {
                    Task { await store.installPortableMakerSkill() }
                } label: {
                    if store.portableMakerSkillOperation == .installing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(actionTitle, systemImage: primaryActionIcon)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.portableMakerSkillOperation.isBusy)
                .accessibilityIdentifier("maker.portable-skill.primary-action")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var status: PortableMakerSkillStatus? {
        store.portableMakerSkillStatus
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status?.state.presentation.color ?? Color.secondary)
                .frame(width: 7, height: 7)
            Text(
                status.map { APCLocalization.text($0.state.presentation.titleKey) }
                    ?? APCLocalization.text(.studioPortableSkillChecking)
            )
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var primaryActionTitle: String? {
        guard let key = status?.state.presentation.primaryActionKey else { return nil }
        return APCLocalization.text(key)
    }

    private var primaryActionIcon: String {
        status?.state.presentation.primaryActionIcon ?? "square.and.arrow.down"
    }

    private func failureDetail(_ failure: PortableMakerSkillFailure) -> String {
        let key: APCLocalizationKey = switch failure {
        case .load: .studioPortableSkillErrorLoad
        case .install: .studioPortableSkillErrorInstall
        case .uninstall: .studioPortableSkillErrorUninstall
        }
        return APCLocalization.text(key)
    }

    private func openSkillDirectory() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("agent-pet-maker", isDirectory: true)
        NSWorkspace.shared.open(url)
    }
}

private struct PortableSkillStatePresentation {
    let titleKey: APCLocalizationKey
    let detailKey: APCLocalizationKey
    let systemImage: String
    let color: Color
    let primaryActionKey: APCLocalizationKey?
    let primaryActionIcon: String
}

private extension PortableMakerSkillState {
    var presentation: PortableSkillStatePresentation {
        switch self {
        case .missing:
            PortableSkillStatePresentation(
                titleKey: .studioPortableSkillStateMissing,
                detailKey: .studioPortableSkillStateMissingDetail,
                systemImage: "shippingbox",
                color: .secondary,
                primaryActionKey: .studioPortableSkillActionInstall,
                primaryActionIcon: "square.and.arrow.down"
            )
        case .current:
            PortableSkillStatePresentation(
                titleKey: .studioPortableSkillStateCurrent,
                detailKey: .studioPortableSkillStateCurrentDetail,
                systemImage: "checkmark.circle.fill",
                color: APCDesign.success,
                primaryActionKey: .studioPortableSkillActionReinstall,
                primaryActionIcon: "arrow.clockwise"
            )
        case .updateAvailable:
            PortableSkillStatePresentation(
                titleKey: .studioPortableSkillStateUpdateAvailable,
                detailKey: .studioPortableSkillStateUpdateAvailableDetail,
                systemImage: "arrow.down.circle.fill",
                color: .blue,
                primaryActionKey: .studioPortableSkillActionUpdate,
                primaryActionIcon: "arrow.down.circle"
            )
        case .needsReinstall:
            PortableSkillStatePresentation(
                titleKey: .studioPortableSkillStateNeedsReinstall,
                detailKey: .studioPortableSkillStateNeedsReinstallDetail,
                systemImage: "wrench.and.screwdriver.fill",
                color: APCDesign.warning,
                primaryActionKey: .studioPortableSkillActionReinstall,
                primaryActionIcon: "arrow.clockwise"
            )
        case .unmanagedCurrent:
            PortableSkillStatePresentation(
                titleKey: .studioPortableSkillStateUnmanagedCurrent,
                detailKey: .studioPortableSkillStateUnmanagedCurrentDetail,
                systemImage: "checkmark.shield",
                color: .blue,
                primaryActionKey: .studioPortableSkillActionManage,
                primaryActionIcon: "square.and.arrow.down"
            )
        case .conflict:
            PortableSkillStatePresentation(
                titleKey: .studioPortableSkillStateConflict,
                detailKey: .studioPortableSkillStateConflictDetail,
                systemImage: "exclamationmark.triangle.fill",
                color: APCDesign.destructive,
                primaryActionKey: nil,
                primaryActionIcon: "square.and.arrow.down"
            )
        }
    }
}

private struct PortableSkillNotice: View {
    let title: String
    let detail: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    func portableSkillCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.secondary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            }
    }
}
