import SwiftUI

struct AppUpdateConvergenceBlockingView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 20) {
            APCBrandMark(size: 72)
                .accessibilityHidden(true)
            ProgressView()
                .controlSize(.regular)
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(
                APCLocalization.text(.appUpdateDataReassurance),
                systemImage: "checkmark.shield.fill"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(APCDesign.accent)
        }
        .padding(40)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app-update.convergence.blocking")
    }

    private var title: String {
        switch store.appUpdateConvergenceState {
        case .waitingForActiveWork:
            APCLocalization.text(.appUpdateConvergenceWaitingTitle)
        case .updating, .idle, .completed, .needsAttention:
            APCLocalization.text(.appUpdateConvergenceTitle)
        }
    }

    private var detail: String {
        switch store.appUpdateConvergenceState {
        case .waitingForActiveWork:
            APCLocalization.text(.appUpdateConvergenceWaitingDetail)
        case .updating, .idle, .completed, .needsAttention:
            APCLocalization.text(.appUpdateConvergenceDetail)
        }
    }
}

struct AppUpdateConvergenceBanner: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        switch store.appUpdateConvergenceState {
        case .idle:
            EmptyView()
        case .waitingForActiveWork:
            banner(
                systemImage: "clock.arrow.circlepath",
                title: APCLocalization.text(.appUpdateConvergenceWaitingTitle),
                detail: APCLocalization.text(.appUpdateConvergenceWaitingDetail),
                tint: APCDesign.accent
            )
        case .updating:
            banner(
                systemImage: "arrow.triangle.2.circlepath",
                title: APCLocalization.text(.appUpdateConvergenceTitle),
                detail: APCLocalization.text(.appUpdateConvergenceDetail),
                tint: APCDesign.accent,
                showsProgress: true
            )
        case let .completed(version):
            banner(
                systemImage: "checkmark.circle.fill",
                title: APCLocalization.format(
                    .appUpdateConvergenceCompleteTitleFormat,
                    version
                ),
                detail: APCLocalization.text(.appUpdateConvergenceCompleteDetail),
                tint: .green,
                dismiss: store.dismissAppUpdateConvergenceNotice
            )
        case let .needsAttention(attention):
            banner(
                systemImage: "exclamationmark.triangle.fill",
                title: APCLocalization.text(.appUpdateConvergenceAttentionTitle),
                detail: APCLocalization.text(.appUpdateConvergenceAttentionDetail),
                tint: APCDesign.warning,
                primaryAction: (
                    APCLocalization.text(.appUpdateConvergenceRetryAction),
                    store.retryProductConvergence
                ),
                secondaryAction: secondaryAction(for: attention)
            )
        }
    }

    private func secondaryAction(
        for attention: AppUpdateConvergenceAttention
    ) -> (String, () -> Void)? {
        switch attention {
        case let .connectors(sources) where !sources.isEmpty:
            (
                APCLocalization.text(.appUpdateConvergenceOpenConnectionsAction),
                { store.selection = .connections }
            )
        case .service:
            (
                APCLocalization.text(.appUpdateConvergenceOpenDiagnosticsAction),
                { store.selection = .diagnostics }
            )
        case .bundledPets, .connectors(_):
            nil
        }
    }

    private func banner(
        systemImage: String,
        title: String,
        detail: String,
        tint: Color,
        showsProgress: Bool = false,
        primaryAction: (String, () -> Void)? = nil,
        secondaryAction: (String, () -> Void)? = nil,
        dismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if let secondaryAction {
                Button(secondaryAction.0, action: secondaryAction.1)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if let primaryAction {
                Button(primaryAction.0, action: primaryAction.1)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if let dismiss {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(APCLocalization.text(.commonClose))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08), in: RoundedRectangle(
            cornerRadius: 12,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.3), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app-update.convergence.banner")
    }
}
