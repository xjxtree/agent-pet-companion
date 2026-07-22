import AgentPetCompanionCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List(selection: $store.selection) {
            ForEach(NavigationSection.allCases) { section in
                Label {
                    Text(section.localizedTitle)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: section.systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .tag(section)
                .accessibilityIdentifier("sidebar.navigation.\(section.rawValue)")
                .accessibilityRepresentation {
                    Button(section.localizedTitle) {
                        store.selection = section
                    }
                    .accessibilityIdentifier("sidebar.navigation.\(section.rawValue)")
                    .accessibilityValue(
                        UIControlSemantics.selectionValue(isSelected: section == store.selection)
                    )
                    .accessibilityAddTraits(section == store.selection ? .isSelected : [])
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarCurrentPetView()
                .environmentObject(store)
        }
    }

}

private struct SidebarCurrentPetView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                APCBrandMark(size: 18)
                    .saturation(store.behavior.enabled ? 1 : 0)
                    .opacity(store.behavior.enabled ? 1 : 0.55)
                    .accessibilityHidden(true)
                Text(store.activePet?.name ?? APCLocalization.text(.appStateNoPetEnabled))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Circle()
                    .fill(store.behavior.enabled ? APCDesign.success : Color.secondary)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.current-pet")
        .accessibilityLabel(APCLocalization.format(
            .configCurrentPetFormat,
            store.activePet?.name ?? APCLocalization.text(.appStateNoPet)
        ))
        .accessibilityValue(UIControlSemantics.toggleValue(isOn: store.behavior.enabled))
    }
}
