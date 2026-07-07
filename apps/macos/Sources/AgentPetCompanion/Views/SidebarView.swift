import AgentPetCompanionCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 11, height: 11)
                Circle().fill(Color.yellow).frame(width: 11, height: 11)
                Circle().fill(Color.green).frame(width: 11, height: 11)
            }
            .padding(.top, 22)

            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(APCDesign.accent)
                    .frame(width: 40, height: 40)
                    .overlay(Text("P").font(.title3.bold()).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent Pet")
                        .font(.headline)
                    Text("macOS Companion")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

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
                            Text(section.title)
                                .font(.headline)
                                .foregroundStyle(section == store.selection ? .primary : .secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(section == store.selection ? Color(nsColor: .controlBackgroundColor) : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            Surface(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前宠物")
                        .font(.headline)
                    Text(store.activePet?.name ?? "未启用")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(store.events.first.map { "\($0.source.title) · \($0.title)" } ?? store.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 22)
        .background(.ultraThinMaterial)
    }
}
