import AgentPetCompanionCore
import SwiftUI

enum ConnectionGridLayout {
    static let overviewColumns = [
        GridItem(.adaptive(minimum: 140), spacing: 12, alignment: .top)
    ]
    static let cardColumns = [
        GridItem(.adaptive(minimum: 260), spacing: 14, alignment: .top)
    ]
}

struct AgentConnectionsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmingRepairAll = false
    @State private var confirmingUninstallAll = false

    var body: some View {
        PageScroll {
            HeaderView(title: "Agent 连接", subtitle: "检查插件、Hook 与本地服务") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        connectionActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        connectionActions
                    }
                }
            }

            Surface {
                VStack(alignment: .leading, spacing: 18) {
                    Text("连接状态")
                        .font(.title3.bold())
                    LazyVGrid(columns: ConnectionGridLayout.overviewColumns, spacing: 12) {
                        StatusOverviewTile(title: "本地服务", value: store.serviceStatusText, tone: store.serviceStatusText.contains("运行") ? .good : .warning)
                        StatusOverviewTile(title: "事件通道", value: eventChannelOverview.value, tone: eventChannelOverview.tone)
                        StatusOverviewTile(title: "插件检查", value: pluginOverview.value, tone: pluginOverview.tone)
                        StatusOverviewTile(title: "最近事件", value: store.recentEvents.first.map { "\($0.source.shortTitle) · \($0.title)" } ?? "暂无事件", tone: .neutral)
                    }
                }
            }

            Surface {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Agent 连接")
                        .font(.title3.bold())
                    if connectionStatuses.isEmpty {
                        ConnectionEmptyState()
                    } else {
                        LazyVGrid(columns: ConnectionGridLayout.cardColumns, spacing: 14) {
                            ForEach(connectionStatuses) { status in
                                AgentConnectionCard(status: status)
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "确认修复所有待处理连接",
            isPresented: $confirmingRepairAll,
            titleVisibility: .visible
        ) {
            Button("修复 \(repairableSources.count) 个连接") {
                store.repairConnections(repairableSources)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(repairAllConfirmationMessage)
        }
        .confirmationDialog(
            "确认卸载所有连接",
            isPresented: $confirmingUninstallAll,
            titleVisibility: .visible
        ) {
            Button("卸载 \(installedSources.count) 个连接", role: .destructive) {
                store.uninstallConnections(installedSources)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(uninstallAllConfirmationMessage)
        }
    }

    private var connectionStatuses: [AgentConnectionStatus] {
        store.connections
    }

    @ViewBuilder
    private var connectionActions: some View {
        SecondaryActionButton(title: "全部检查", systemImage: "checkmark.seal") {
            store.checkAllConnections()
        }
        .disabled(!store.connectionOperationSources.isEmpty)

        PrimaryActionButton(title: "全部修复", systemImage: "wrench.and.screwdriver") {
            confirmingRepairAll = true
        }
        .disabled(repairableSources.isEmpty || !store.connectionOperationSources.isEmpty)

        SecondaryActionButton(title: "全部卸载", systemImage: "trash") {
            confirmingUninstallAll = true
        }
        .disabled(installedSources.isEmpty || !store.connectionOperationSources.isEmpty)
    }

    private var needsFixCount: Int {
        connectionStatuses.flatMap(\.items).filter { $0.status != .ok }.count
    }

    private var pluginOverview: (value: String, tone: StatusBadge.Tone) {
        guard !connectionStatuses.isEmpty else {
            return ("待检查", .neutral)
        }
        if needsFixCount == 0, connectionStatuses.contains(where: { $0.checkMode == .light }) {
            return ("待完整检查", .neutral)
        }
        return needsFixCount == 0
            ? ("正常", .good)
            : ("\(needsFixCount) 项待修复", .warning)
    }

    private var eventChannelOverview: (value: String, tone: StatusBadge.Tone) {
        let eventItems = connectionStatuses.compactMap { status in
            status.items.first { $0.name == "事件回传" }
        }
        guard !eventItems.isEmpty else {
            return ("待检查", .neutral)
        }
        let brokenCount = eventItems.filter { $0.status != .ok }.count
        guard brokenCount > 0 else {
            return ("正常", .good)
        }
        return ("\(brokenCount) 项待修复", .warning)
    }

    private var repairableSources: [AgentSource] {
        connectionStatuses
            .filter(\.hasRepairableConnectorIssue)
            .map(\.source)
    }

    private var installedSources: [AgentSource] {
        connectionStatuses
            .filter(\.hasInstalledConnectorArtifacts)
            .map(\.source)
    }

    private var repairAllConfirmationMessage: String {
        guard !repairableSources.isEmpty else {
            return "当前没有需要修复的 Agent 连接。"
        }
        let names = repairableSources.map(\.title).joined(separator: "、")
        return "将安装或更新这些 Agent 的本地连接文件：\(names)"
    }

    private var uninstallAllConfirmationMessage: String {
        guard !installedSources.isEmpty else {
            return "当前没有检测到可卸载的 Agent 连接。"
        }
        let names = installedSources.map(\.title).joined(separator: "、")
        return "将移除这些 Agent 的本地连接文件或配置：\(names)"
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
                    .accessibilityHidden(true)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(APCDesign.stroke))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)：\(value)")
    }

    private var dotColor: Color {
        switch tone {
        case .good: APCDesign.success
        case .warning: APCDesign.warning
        case .neutral: .secondary
        case .accent: APCDesign.accent
        }
    }
}

struct ConnectionEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("等待真实连接状态", systemImage: "hourglass")
                .font(.headline)
            Text("本地服务尚未返回连接快照。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(APCDesign.stroke))
        )
    }
}

struct AgentConnectionCard: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmingRepair = false
    @State private var confirmingUninstall = false
    var status: AgentConnectionStatus

    var body: some View {
        let busy = store.connectionOperationSources.contains(status.source)
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    connectionTitle
                    Spacer()
                    checkButton(disabled: busy)
                }
                VStack(alignment: .leading, spacing: 10) {
                    connectionTitle
                    checkButton(disabled: busy)
                }
            }

            VStack(spacing: 8) {
                ForEach(status.items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                                .font(.callout.weight(.semibold))
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        StatusBadge(title: statusTitle(for: item), tone: tone(for: item))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(item.name)：\(statusTitle(for: item))，\(item.detail)")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("将写入路径")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if status.installPaths.isEmpty {
                    Text("检查完成后显示")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(status.installPaths, id: \.self) { path in
                        Text(path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.45))
            )

            Button {
                store.sendConnectionTestEvent(status.source)
            } label: {
                Label("发送测试事件", systemImage: "play.circle")
                    .font(.callout.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(APCDesign.accentSoft.opacity(0.65))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(APCDesign.accent.opacity(0.26)))
                    )
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityLabel("向 \(status.source.title) 发送测试事件")

            HStack(spacing: 10) {
                Button {
                    confirmingRepair = true
                } label: {
                    Label("一键修复", systemImage: "wrench.and.screwdriver")
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
                .disabled(!status.hasRepairableConnectorIssue || busy)
                .accessibilityLabel("修复 \(status.source.title) 连接")
                .confirmationDialog(
                    "确认修复 \(status.source.title)",
                    isPresented: $confirmingRepair,
                    titleVisibility: .visible
                ) {
                    Button("写入并修复") {
                        store.repairConnection(status.source)
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text(repairConfirmationMessage)
                }

                Button {
                    confirmingUninstall = true
                } label: {
                    Label("卸载连接", systemImage: "trash")
                        .font(.callout.bold())
                        .foregroundStyle(hasInstalledItems ? APCDesign.destructive : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay(RoundedRectangle(cornerRadius: 11).stroke(hasInstalledItems ? APCDesign.destructive.opacity(0.48) : APCDesign.stroke))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!hasInstalledItems || busy)
                .accessibilityLabel("卸载 \(status.source.title) 连接")
                .confirmationDialog(
                    "确认卸载 \(status.source.title)",
                    isPresented: $confirmingUninstall,
                    titleVisibility: .visible
                ) {
                    Button("卸载连接", role: .destructive) {
                        store.uninstallConnection(status.source)
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text(uninstallConfirmationMessage)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(APCDesign.stroke))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private var repairConfirmationMessage: String {
        guard status.hasRepairableConnectorIssue else {
            return "当前状态无需修复。"
        }
        guard !status.installPaths.isEmpty else {
            return "请先完成连接检查，确认将写入的本地路径。"
        }
        return "将安装或更新以下本地连接文件：\n" + status.installPaths.joined(separator: "\n")
    }

    private var uninstallConfirmationMessage: String {
        guard !status.installPaths.isEmpty else {
            return "将移除该 Agent 的本地连接配置。"
        }
        return "将移除以下本地连接文件或配置：\n" + status.installPaths.joined(separator: "\n")
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
        case .codex: Color(nsColor: .labelColor)
        case .claudeCode: APCDesign.warning
        case .pi: APCDesign.success
        case .opencode: Color(nsColor: .systemBlue)
        }
    }

    private var hasInstalledItems: Bool {
        status.hasInstalledConnectorArtifacts
    }

    private var connectionTitle: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(iconColor)
                .frame(width: 36, height: 36)
                .overlay(Text(iconText).font(.headline.bold()).foregroundStyle(APCDesign.onAccent))
            Text(status.source.title)
                .font(.title3.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            StatusBadge(
                title: status.checkMode.title,
                tone: status.checkMode == .runtime ? .good : .neutral
            )
        }
    }

    private func checkButton(disabled: Bool) -> some View {
        SecondaryActionButton(title: "检查", systemImage: "checkmark") {
            store.checkConnection(status.source)
        }
        .disabled(disabled)
        .accessibilityLabel("检查 \(status.source.title) 连接")
    }

    private func statusTitle(for item: ConnectionCheckItem) -> String {
        if status.checkMode == .light, item.status == .ok {
            return "已定位"
        }
        return item.status.title
    }

    private func tone(for item: ConnectionCheckItem) -> StatusBadge.Tone {
        if status.checkMode == .light, item.status == .ok {
            return .neutral
        }
        return switch item.status {
        case .ok: .good
        case .needsFix: .warning
        case .missing: .neutral
        }
    }
}
