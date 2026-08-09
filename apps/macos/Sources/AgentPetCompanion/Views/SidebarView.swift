import AgentPetCompanionCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selection) {
                ForEach(ControlCenterNavigationPresentation.items(selection: store.selection)) { item in
                    Label {
                        Text(item.title)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: item.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .tag(item.section)
                    .accessibilityIdentifier("sidebar.navigation.\(item.section.rawValue)")
                    .accessibilityRepresentation {
                        Button(item.title) {
                            store.selection = item.section
                        }
                        .accessibilityIdentifier("sidebar.navigation.\(item.section.rawValue)")
                        .accessibilityValue(
                            UIControlSemantics.selectionValue(isSelected: item.isSelected)
                        )
                        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("sidebar.navigation-list")

            SidebarCurrentPetView()
                .environmentObject(store)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar, ignoresSafeAreaEdges: .all)
    }
}

private struct SidebarCurrentPetView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            SidebarConfigurationLivePreview(
                behavior: store.behavior,
                pet: store.activePet,
                assetWarning: activePetAssetWarning,
                displayWidthPt: store.overlayDisplayWidthPt
            )
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
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sidebar.current-pet")
            .accessibilityLabel(APCLocalization.format(
                .configCurrentPetFormat,
                store.activePet?.name ?? APCLocalization.text(.appStateNoPet)
            ))
            .accessibilityValue(UIControlSemantics.toggleValue(isOn: store.behavior.enabled))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activePetAssetWarning: PetAssetWarning? {
        store.activePet.flatMap { store.petAssetWarningIndex[$0.id] }
    }
}
