import AgentPetCompanionCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(APCDesign.accent)
                            .frame(width: 40, height: 40)
                            .overlay(Text("P").font(.title3.bold()).foregroundStyle(APCDesign.onAccent))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Agent Pet")
                                .font(.headline)
                            Text("macOS Companion")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 30)

                    VStack(spacing: 10) {
                        ForEach(NavigationSection.allCases) { section in
                            Button {
                                store.selection = section
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: section.systemImage)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(section == store.selection ? APCDesign.accent : .secondary)
                                        .frame(width: 20)
                                    Text(title(for: section))
                                        .font(.headline)
                                        .foregroundStyle(section == store.selection ? .primary : .secondary)
                                    Spacer()
                                    if section == store.selection {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(APCDesign.accent)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(section == store.selection ? Color(nsColor: .controlBackgroundColor) : .clear)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(title(for: section))
                            .accessibilityValue(
                                UIControlSemantics.selectionValue(isSelected: section == store.selection)
                            )
                            .accessibilityAddTraits(section == store.selection ? .isSelected : [])
                        }
                    }

                    Spacer(minLength: 24)

                    Surface(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("当前宠物")
                                .font(.headline)
                            Text(store.activePet?.name ?? "未启用")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(store.activeAgentEventText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)

                            Divider()
                                .padding(.vertical, 2)

                            Text("状态")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                            Text(store.statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                                .accessibilityLabel("应用状态：\(store.statusText)")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(minHeight: max(0, proxy.size.height - 22), alignment: .top)
                .padding(.horizontal, 18)
                .padding(.bottom, 22)
            }
            .scrollIndicators(.visible)
        }
        .background(.ultraThinMaterial)
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
