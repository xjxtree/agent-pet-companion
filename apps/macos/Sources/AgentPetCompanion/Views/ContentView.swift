import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 226)
            Divider()
            mainContent
        }
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(red: 0.92, green: 0.97, blue: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
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
