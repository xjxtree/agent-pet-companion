import AgentPetCompanionCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List(selection: $store.selection) {
            Section {
                ForEach(NavigationSection.allCases) { section in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title(for: section))
                                .font(.callout.weight(.semibold))
                            Text(section.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 20)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .tag(section)
                    .accessibilityRepresentation {
                        Button(title(for: section)) {
                            store.selection = section
                        }
                        .accessibilityValue(
                            UIControlSemantics.selectionValue(isSelected: section == store.selection)
                        )
                        .accessibilityAddTraits(section == store.selection ? .isSelected : [])
                    }
                }
            } header: {
                Label("Agent Pet", systemImage: "pawprint.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarStatusView()
                .environmentObject(store)
                .padding(12)
        }
    }

    private func title(for section: NavigationSection) -> String {
        switch section {
        case .studio:
            APCLocalization.text(.navigationStudio)
        case .behavior:
            APCLocalization.text(.navigationBehavior)
        case .connections:
            APCLocalization.text(.navigationConnections)
        }
    }
}

private struct SidebarStatusView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: store.behavior.enabled ? "pawprint.fill" : "pawprint")
                    .foregroundStyle(store.behavior.enabled ? APCDesign.success : .secondary)
                Text(store.activePet?.name ?? "未启用")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Circle()
                    .fill(store.behavior.enabled ? APCDesign.success : Color.secondary)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }

            Text(store.activeAgentEventText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(store.statusText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .textSelection(.enabled)
                .accessibilityLabel("应用状态：\(store.statusText)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .apcLiquidGlass(
            in: RoundedRectangle(cornerRadius: 16, style: .continuous),
            interactive: true
        )
    }
}
