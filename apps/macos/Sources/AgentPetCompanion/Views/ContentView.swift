import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 206, ideal: 232, max: 280)
        } detail: {
            mainContent
                .navigationTitle(navigationTitle)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .status) {
                HStack(spacing: 7) {
                    Image(systemName: "pawprint.fill")
                        .foregroundStyle(APCDesign.accent)
                    Text(store.activePet?.name ?? "未启用宠物")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("当前宠物：\(store.activePet?.name ?? "未启用")")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.toggleOverlay()
                } label: {
                    Label(
                        store.behavior.enabled ? "隐藏桌宠" : "显示桌宠",
                        systemImage: store.behavior.enabled ? "eye.slash" : "eye"
                    )
                }
                .help(store.behavior.enabled ? "隐藏桌面上的宠物" : "显示桌面上的宠物")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch store.selection {
        case .studio:
            PetStudioView()
        case .behavior:
            BehaviorSettingsView()
        case .connections:
            AgentConnectionsView()
        }
    }

    private var navigationTitle: String {
        switch store.selection {
        case .studio:
            APCLocalization.text(.navigationStudio)
        case .behavior:
            APCLocalization.text(.navigationBehavior)
        case .connections:
            APCLocalization.text(.navigationConnections)
        }
    }
}
