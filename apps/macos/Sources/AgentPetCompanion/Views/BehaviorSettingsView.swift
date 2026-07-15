import AgentPetCompanionCore
import SwiftUI

struct BehaviorSettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        PageScroll {
            HeaderView(title: "启用与行为", subtitle: "控制宠物何时响应") {
                EmptyView()
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    enableSurface
                    sourcesSurface
                }

                VStack(alignment: .leading, spacing: 18) {
                    enableSurface
                    sourcesSurface
                }
            }

            Surface {
                VStack(alignment: .leading, spacing: 16) {
                    Text("响应事件")
                        .font(.title3.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                        ForEach(AgentEventKind.allCases) { event in
                            EventToggle(event: event)
                        }
                    }
                }
            }
        }
    }

    private var enableSurface: some View {
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                Text("启用")
                    .font(.title3.bold())
                SettingToggle(title: "启用桌宠", detail: "显示当前宠物悬浮层", value: store.behavior.enabled) { value in
                    var next = store.behavior
                    next.enabled = value
                    store.updateBehavior(next)
                }
                SettingToggle(title: "状态气泡", detail: "显示简短任务状态", value: store.behavior.statusBubble) { value in
                    var next = store.behavior
                    next.statusBubble = value
                    store.updateBehavior(next)
                }
                SettingToggle(title: "自动收起气泡", detail: "空闲时隐藏气泡，有事件时自动显示", value: store.behavior.autoHide) { value in
                    var next = store.behavior
                    next.autoHide = value
                    store.updateBehavior(next)
                }
                Stepper(
                    value: Binding(
                        get: { store.behavior.sessionMessageTimeoutMinutes },
                        set: { minutes in
                            var next = store.behavior
                            next.sessionMessageTimeoutMinutes = minutes
                            store.updateBehavior(next)
                        }
                    ),
                    in: 1 ... 1_440
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("会话消息收起时间")
                                .font(.headline)
                            Spacer()
                            Text("\(store.behavior.sessionMessageTimeoutMinutes) 分钟")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text("普通会话超过此时间后收起；等待确认与失败会话保持显示")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("会话消息收起时间")
                .accessibilityValue("\(store.behavior.sessionMessageTimeoutMinutes) 分钟")
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) { Divider() }
                SettingToggle(title: "右击菜单", detail: "右击宠物打开快捷菜单", value: store.behavior.clickMenu) { value in
                    var next = store.behavior
                    next.clickMenu = value
                    store.updateBehavior(next)
                }
                SettingToggle(title: "透明区域穿透", detail: "桌宠周围空白不拦截其他 App", value: store.behavior.mousePassthrough) { value in
                    var next = store.behavior
                    next.mousePassthrough = value
                    store.updateBehavior(next)
                }
                Divider()
                Text("桌宠交互")
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)], spacing: 10) {
                    InteractionTile(title: "拖动", detail: "移动位置", systemImage: "hand.draw")
                    InteractionTile(title: "悬停", detail: "显示缩放手柄", systemImage: "cursorarrow.motionlines")
                    InteractionTile(title: "缩放", detail: "宠物右侧拖拽", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Divider()
                Picker("帧率", selection: Binding(
                    get: { store.behavior.fpsProfile },
                    set: { profile in
                        var next = store.behavior
                        next.fpsProfile = profile
                        store.updateBehavior(next)
                    }
                )) {
                    ForEach(FpsProfile.allCases) { profile in
                        Text("\(profile.title) · \(profile.fps) FPS").tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("桌宠动画帧率")
                .accessibilityValue("\(store.behavior.fpsProfile.title)，\(store.behavior.fpsProfile.fps) FPS")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var sourcesSurface: some View {
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                Text("响应来源")
                    .font(.title3.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ForEach(AgentSource.allCases) { source in
                        SourceToggle(source: source)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct SettingToggle: View {
    var title: String
    var detail: String
    var value: Bool
    var onChange: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { value }, set: { newValue in
            onChange(newValue)
        })) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Text(UIControlSemantics.toggleValue(isOn: value))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .tint(APCDesign.accent)
        .accessibilityLabel(title)
        .accessibilityValue(UIControlSemantics.toggleValue(isOn: value))
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct InteractionTile: View {
    var title: String
    var detail: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(APCDesign.accent)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .apcLiquidGlass(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}

struct SourceToggle: View {
    @EnvironmentObject private var store: AppStore
    var source: AgentSource

    var body: some View {
        Toggle(isOn: Binding(
            get: { store.behavior.sources[source, default: true] },
            set: { store.setSource(source, enabled: $0) }
        )) {
            HStack(spacing: 10) {
                AgentIconView(source: source, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.title)
                        .font(.headline)
                    Text("\(UIControlSemantics.toggleValue(isOn: isEnabled)) · \(sourceDetail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(APCDesign.accent)
        .accessibilityLabel(UIControlSemantics.sourceLabel(source))
        .accessibilityValue("\(UIControlSemantics.toggleValue(isOn: isEnabled))，\(sourceDetail)")
        .padding(12)
        .apcLiquidGlass(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            interactive: true
        )
    }

    private var isEnabled: Bool {
        store.behavior.sources[source, default: true]
    }

    private var sourceDetail: String {
        guard let status = store.connections.first(where: { $0.source == source }) else {
            return "连接待检查"
        }
        let badItems = status.blockingItems
        guard !badItems.isEmpty else {
            if status.checkMode == .light {
                return "待完整检查"
            }
            if !status.unverifiedItems.isEmpty {
                return "部分能力待验证"
            }
            if !status.unsupportedItems.isEmpty {
                return "连接可用，部分能力暂不支持"
            }
            return "连接正常"
        }
        if badItems.contains(where: { $0.status == .missing }) {
            return "未检测到"
        }
        return "需修复"
    }

}

struct EventToggle: View {
    @EnvironmentObject private var store: AppStore
    var event: AgentEventKind

    var body: some View {
        Toggle(isOn: Binding(
            get: { isEnabled },
            set: { store.setEvent(event, enabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.headline)
                Text(UIControlSemantics.toggleValue(isOn: isEnabled))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .tint(APCDesign.accent)
        .accessibilityLabel(UIControlSemantics.eventLabel(event))
        .accessibilityValue(UIControlSemantics.toggleValue(isOn: isEnabled))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .apcLiquidGlass(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            interactive: true
        )
    }

    private var isEnabled: Bool {
        store.behavior.events[event, default: true]
    }
}
