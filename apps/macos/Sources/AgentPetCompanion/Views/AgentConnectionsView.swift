import AgentPetCompanionCore
import SwiftUI

struct AgentConnectionsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderView(title: "Agent 连接", subtitle: "检查插件、Hook 与本地服务") {
                SecondaryActionButton(title: "全部检查", systemImage: "checkmark.seal") {
                    Task { await store.refresh() }
                }
            }

            Surface {
                VStack(alignment: .leading, spacing: 18) {
                    Text("连接状态")
                        .font(.title3.bold())
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        StatusOverviewTile(title: "本地服务", value: store.statusText, tone: store.statusText.contains("运行") ? .good : .warning)
                        StatusOverviewTile(title: "事件通道", value: store.events.isEmpty ? "待事件" : "正常", tone: store.events.isEmpty ? .neutral : .good)
                        StatusOverviewTile(title: "插件检查", value: needsFixCount == 0 ? "正常" : "\(needsFixCount) 项待修复", tone: needsFixCount == 0 ? .good : .warning)
                        StatusOverviewTile(title: "最近事件", value: store.events.first.map { "\($0.source.shortTitle) · \($0.title)" } ?? "暂无", tone: .neutral)
                    }
                }
            }

            Surface {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Agent 连接")
                        .font(.title3.bold())
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(connectionStatuses) { status in
                            AgentConnectionCard(status: status)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 28)
    }

    private var connectionStatuses: [AgentConnectionStatus] {
        if store.connections.isEmpty {
            return AgentSource.allCases.map {
                AgentConnectionStatus(
                    source: $0,
                    items: [
                        ConnectionCheckItem(name: "CLI", status: .missing, detail: "等待检查"),
                        ConnectionCheckItem(name: "事件", status: .needsFix, detail: "等待配置")
                    ],
                    installPaths: []
                )
            }
        }
        return store.connections
    }

    private var needsFixCount: Int {
        connectionStatuses.flatMap(\.items).filter { $0.status != .ok }.count
    }
}

struct StatusOverviewTile: View {
    var title: String
    var value: String
    var tone: StatusBadge.Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(APCDesign.stroke))
        )
    }

    private var dotColor: Color {
        switch tone {
        case .good: .green
        case .warning: .orange
        case .neutral: .secondary
        case .accent: APCDesign.accent
        }
    }
}

struct AgentConnectionCard: View {
    @EnvironmentObject private var store: AppStore
    var status: AgentConnectionStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(iconColor)
                    .frame(width: 36, height: 36)
                    .overlay(Text(iconText).font(.headline.bold()).foregroundStyle(.white))
                Text(status.source.title)
                    .font(.title3.bold())
                Spacer()
                SecondaryActionButton(title: "检查", systemImage: "checkmark") {
                    store.checkConnection(status.source)
                }
            }

            VStack(spacing: 8) {
                ForEach(status.items) { item in
                    HStack {
                        Text(item.name)
                            .font(.callout.weight(.semibold))
                        Spacer()
                        StatusBadge(title: item.status.title, tone: tone(for: item.status))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
                    )
                }
            }

            Button {
                store.repairConnection(status.source)
            } label: {
                Text("一键修复")
                    .font(.callout.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(APCDesign.stroke))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(APCDesign.stroke))
        )
    }

    private var iconText: String {
        switch status.source {
        case .codex: "C"
        case .claudeCode: "Cl"
        case .pi: "Pi"
        case .opencode: "O"
        }
    }

    private var iconColor: Color {
        switch status.source {
        case .codex: Color(red: 0.12, green: 0.15, blue: 0.22)
        case .claudeCode: Color.orange
        case .pi: Color.green
        case .opencode: Color.blue
        }
    }

    private func tone(for status: CheckStatus) -> StatusBadge.Tone {
        switch status {
        case .ok: .good
        case .needsFix: .warning
        case .missing: .neutral
        }
    }
}
