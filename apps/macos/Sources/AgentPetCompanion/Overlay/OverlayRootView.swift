import AgentPetCompanionCore
import SwiftUI

struct OverlayRootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var lastResizeTranslation: CGSize = .zero

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.45)))

            VStack(spacing: 0) {
                HStack {
                    Text("Agent Pet Companion")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(store.events.first.map { "\($0.source.title) · \($0.title)" } ?? "Claude Code · 执行工具")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))

                ZStack {
                    PetMetalView(stateSeed: store.events.first?.eventType.rawValue ?? "idle")
                        .opacity(0.55)

                    if store.behavior.statusBubble {
                        StatusBubble()
                            .offset(x: -110 * store.overlayScale, y: -22 * store.overlayScale)
                    }

                    VStack(spacing: 12) {
                        Spacer()
                        SamplePetIllustration(state: store.events.first?.eventType, scale: 0.9 * store.overlayScale)
                            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: store.events.first?.eventType)
                        Spacer()
                    }

                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            ResizeHandle()
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            let delta = CGSize(
                                                width: value.translation.width - lastResizeTranslation.width,
                                                height: value.translation.height - lastResizeTranslation.height
                                            )
                                            lastResizeTranslation = value.translation
                                            store.resizeOverlay(delta: delta)
                                        }
                                        .onEnded { _ in
                                            lastResizeTranslation = .zero
                                        }
                                )
                        }
                        .padding(20)
                    }
                }
            }
        }
        .contextMenu {
            Button("开始处理") { store.ingestDemoEvent(.start) }
            Button("执行工具") { store.ingestDemoEvent(.tool) }
            Button("等待确认") { store.ingestDemoEvent(.waiting) }
            Divider()
            Button("隐藏桌宠") { store.toggleOverlay() }
        }
    }
}

struct StatusBubble: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(store.events.first?.title ?? "正在工作")
                .font(.headline)
            Text(store.events.first.map { "\($0.source.title) 正在\($0.title)" } ?? "Claude Code 正在执行工具")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.10), radius: 18, y: 9)
        )
    }
}

struct ResizeHandle: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 48, height: 48)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
        )
        .help("拖拽调整桌宠大小")
    }
}
