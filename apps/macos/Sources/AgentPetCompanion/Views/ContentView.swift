import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var appliedShellMode: ControlCenterShellMode?

    var body: some View {
        GeometryReader { geometry in
            let policy = ControlCenterShellPolicy(windowWidth: geometry.size.width)

            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView()
                    .navigationSplitViewColumnWidth(
                        min: ControlCenterShellPolicy.primarySidebarMinimumWidth,
                        ideal: ControlCenterShellPolicy.primarySidebarIdealWidth,
                        max: ControlCenterShellPolicy.primarySidebarMaximumWidth
                    )
            } detail: {
                VStack(spacing: 0) {
                    if store.petCoreRuntimeInfo.errorMessage != nil,
                       store.selection != .diagnostics
                    {
                        PetCoreFailureBanner(
                            operationalState: store.petCoreOperationalState,
                            retrying: store.petCoreRuntimeInfo.phase == .checking,
                            onRetry: { store.retryPetCoreStartup() }
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 14)
                    }
                    mainContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle("")
            }
            .navigationSplitViewStyle(.balanced)
            .environment(\.controlCenterShellMode, policy.mode)
            .toolbar {
#if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) {
                        ControlCenterBrandTitle()
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) {
                        ControlCenterBrandTitle()
                    }
                }
#else
                ToolbarItem(placement: .navigation) {
                    ControlCenterBrandTitle()
                }
#endif

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        store.toggleOverlay()
                    } label: {
                        Label(
                            APCLocalization.text(
                                store.behavior.enabled ? .appActionHidePet : .appActionShowPet
                            ),
                            systemImage: store.behavior.enabled ? "eye.slash" : "eye"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .help(APCLocalization.text(
                        store.behavior.enabled ? .appHelpHidePet : .appHelpShowPet
                    ))
                    .accessibilityIdentifier("toolbar.toggle-pet")

                    Button {
                        store.selection = .diagnostics
                    } label: {
                        Label(serviceToolbar.title, systemImage: serviceToolbar.systemImage)
                            .labelStyle(.iconOnly)
                            .foregroundStyle(serviceToolbar.tone.color)
                    }
                    .help(APCLocalization.format(.appHelpServiceStatus, serviceToolbar.title))
                    .accessibilityLabel(
                        APCLocalization.format(.contentServiceStatusLabel, serviceToolbar.title)
                    )
                    .accessibilityIdentifier("toolbar.service-status")

                    Menu {
                        Button(APCLocalization.text(.navigationConnections)) {
                            store.selection = .connections
                        }
                        Divider()
                        Button(APCLocalization.text(.appActionQuit), role: .destructive) {
                            NSApplication.shared.terminate(nil)
                        }
                    } label: {
                        Label(APCLocalization.text(.appActionMore), systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                    }
                    .help(APCLocalization.text(.appHelpMore))
                    .accessibilityIdentifier("toolbar.more")
                }
            }
            .onAppear {
                apply(policy)
            }
            .onChange(of: policy.mode) { _, _ in
                apply(policy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func apply(_ policy: ControlCenterShellPolicy) {
        guard appliedShellMode != policy.mode else { return }
        appliedShellMode = policy.mode
        columnVisibility = policy.preferredColumnVisibility
    }

    @ViewBuilder
    private var mainContent: some View {
        switch store.selection {
        case .library:
            PetLibraryView()
        case .maker:
            AIPetMakerView()
        case .configuration:
            BehaviorSettingsView()
        case .connections:
            AgentConnectionsView()
        case .diagnostics:
            ServiceDiagnosticsView()
        }
    }

    private var serviceToolbar: ServiceToolbarPresentation {
        ServiceDiagnosticsPresentation.toolbar(
            operationalState: store.petCoreOperationalState,
            runtimeInfo: store.petCoreRuntimeInfo
        )
    }
}

private struct ControlCenterBrandTitle: View {
    var body: some View {
        HStack(spacing: 8) {
            APCBrandMark(size: 24)
                .accessibilityHidden(true)
            Text(APCLocalization.text(.appName))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(APCLocalization.text(.appName))
        .accessibilityIdentifier("toolbar.brand")
    }
}

enum PetCoreFailurePresentation {
    static func detail(
        for state: PetCoreOperationalState,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch state {
        case .checking, .recovering: .servicePetCoreRecoveringDetail
        case .offline: .servicePetCoreOfflineDetail
        case .runtimeMismatch: .servicePetCoreRuntimeMismatchDetail
        case .error: .servicePetCoreFailedDetail
        case .online: .servicePetCoreRunning
        }
        return APCLocalization.text(key, locale: localeIdentifier)
    }
}

private struct PetCoreFailureBanner: View {
    var operationalState: PetCoreOperationalState
    var retrying: Bool
    var onRetry: () -> Void

    private var localizedDetail: String {
        PetCoreFailurePresentation.detail(for: operationalState)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(APCDesign.warning)
                .font(.title3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(APCLocalization.text(
                    retrying ? .petCoreFailureRetryingTitle : .petCoreFailureTitle
                ))
                    .font(.callout.weight(.semibold))
                Text(localizedDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if retrying {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        APCLocalization.text(.petCoreFailureRetryingAccessibility)
                    )
            } else {
                Button(APCLocalization.text(.petCoreFailureRetryAction), action: onRetry)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(APCDesign.warning.opacity(0.45), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }
}
