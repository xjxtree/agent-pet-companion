import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var appliedShellMode: ControlCenterShellMode?

    var body: some View {
        if store.shouldBlockForAppUpdateConvergence {
            AppUpdateConvergenceBlockingView()
        } else if store.shouldPresentOnboarding {
            OnboardingView()
        } else {
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
                        AppUpdateConvergenceBanner()
                            .padding(.horizontal, 24)
                            .padding(.top, 14)
                        AppUpdateAvailableBanner(updater: store.appUpdater) {
                            store.appUpdater.presentAvailableUpdate()
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 14)
                        if let recoveryBanner,
                           store.selection != .diagnostics
                        {
                            InlineRecoveryBanner(
                                identity: ProductComponentIdentity(
                                    scope: "shell",
                                    instance: "service"
                                ),
                                status: recoveryBanner.status,
                                primaryAction: recoveryBanner.primaryAction
                            ) { action in
                                switch action {
                                case .openDiagnostics:
                                    store.selection = .diagnostics
                                }
                            }
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

                        if let serviceAttention {
                            Button {
                                store.selection = .diagnostics
                            } label: {
                                Label(
                                    serviceAttention.title,
                                    systemImage: serviceAttention.systemImage
                                )
                                .labelStyle(.iconOnly)
                                .foregroundStyle(serviceAttention.appearance.toolbarTint)
                            }
                            .help(APCLocalization.format(
                                .appHelpServiceStatus,
                                serviceAttention.title
                            ))
                            .accessibilityLabel(APCLocalization.format(
                                .contentServiceStatusLabel,
                                serviceAttention.title
                            ))
                            .accessibilityIdentifier("toolbar.service-attention")
                        }
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

    private var serviceAttention: ControlCenterServiceAttentionPresentation? {
        ControlCenterServiceAttentionPresentation.resolve(
            for: store.petCoreOperationalState
        )
    }

    private var recoveryBanner: ControlCenterRecoveryBannerPresentation? {
        ControlCenterRecoveryBannerPresentation.resolve(
            for: store.petCoreOperationalState
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

private extension ProductStatusAppearance {
    var toolbarTint: Color {
        switch self {
        case .neutral:
            .secondary
        case .normal:
            .secondary
        case .attention:
            APCDesign.warning
        case .error:
            APCDesign.destructive
        case .checking:
            APCDesign.accent
        }
    }
}
