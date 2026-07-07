import AgentPetCompanionCore
import SwiftUI

struct BehaviorSettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderView(title: "启用与行为", subtitle: "控制宠物何时响应") {
                SecondaryActionButton(title: "触发演示事件", systemImage: "bolt.fill") {
                    store.ingestDemoEvent(.tool)
                }
            }

            HStack(alignment: .top, spacing: 18) {
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
                        SettingToggle(title: "点击菜单", detail: "点击宠物打开快捷菜单", value: store.behavior.clickMenu) { value in
                            var next = store.behavior
                            next.clickMenu = value
                            store.updateBehavior(next)
                        }
                        Divider()
                        Text("桌宠交互")
                            .font(.headline)
                        HStack(spacing: 10) {
                            InteractionTile(title: "拖动", detail: "移动位置", systemImage: "hand.draw")
                            InteractionTile(title: "悬停", detail: "显示缩放手柄", systemImage: "cursorarrow.motionlines")
                            InteractionTile(title: "缩放", detail: "右下角拖拽", systemImage: "arrow.up.left.and.arrow.down.right")
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
                    }
                }

                Surface {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("响应来源")
                            .font(.title3.bold())
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(AgentSource.allCases) { source in
                                SourceToggle(source: source)
                            }
                        }
                    }
                }
            }

            Surface {
                VStack(alignment: .leading, spacing: 16) {
                    Text("响应事件")
                        .font(.title3.bold())
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(AgentEventKind.allCases) { event in
                            EventToggle(event: event)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 28)
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
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(APCDesign.stroke))
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
            VStack(alignment: .leading, spacing: 4) {
                Text(source.title)
                    .font(.headline)
                Text(store.behavior.sources[source, default: true] ? "已连接" : "已关闭")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(APCDesign.stroke))
        )
    }
}

struct EventToggle: View {
    @EnvironmentObject private var store: AppStore
    var event: AgentEventKind

    var body: some View {
        HStack {
            Button {
                store.ingestDemoEvent(event)
            } label: {
                Image(systemName: "play.fill")
                    .foregroundStyle(APCDesign.accent)
            }
            .buttonStyle(.plain)
            Text(event.title)
                .font(.headline)
            Spacer()
            Toggle("", isOn: Binding(
                get: { store.behavior.events[event, default: true] },
                set: { store.setEvent(event, enabled: $0) }
            ))
            .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(APCDesign.stroke))
        )
    }
}
