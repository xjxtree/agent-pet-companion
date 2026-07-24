import AgentPetCompanionCore
import SwiftUI

/// Compact, shared recovery surface for every product context that would
/// otherwise render a large empty pet stage. PetCore owns the repair; this
/// view only presents its typed state and the diagnostics escape hatch.
struct PetAssetRecoveryCard: View {
    let pet: PetSummary
    let state: PetAssetRepairState
    let onRepair: () -> Void
    let onOpenDiagnostics: () -> Void

    private var isRepairing: Bool {
        state == .repairing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(APCLocalization.text(.assetRecoveryTitle))
                    .font(.headline)

                Text(APCLocalization.text(.assetRecoveryDetail))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if state == .failed {
                    Text(APCLocalization.text(.assetRecoveryFailed))
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        recoveryButton
                        diagnosticsButton
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        recoveryButton
                        diagnosticsButton
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pet-asset-recovery.\(pet.id)")
    }

    private var recoveryButton: some View {
        Button(action: onRepair) {
            Label(
                APCLocalization.text(
                    isRepairing
                        ? .assetRecoveryRepairing
                        : .assetRecoveryRepair
                ),
                systemImage: "arrow.clockwise"
            )
        }
        .buttonStyle(.borderedProminent)
        .disabled(isRepairing)
        .accessibilityIdentifier("pet-asset-recovery.\(pet.id).repair")
    }

    private var diagnosticsButton: some View {
        Button(action: onOpenDiagnostics) {
            Label(
                APCLocalization.text(.assetRecoveryDiagnostics),
                systemImage: "stethoscope"
            )
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("pet-asset-recovery.\(pet.id).diagnostics")
    }
}
