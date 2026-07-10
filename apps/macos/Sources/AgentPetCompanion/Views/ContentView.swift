import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 226)
            Divider()
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
}
