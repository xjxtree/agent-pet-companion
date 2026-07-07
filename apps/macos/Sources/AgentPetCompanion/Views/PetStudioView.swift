import AgentPetCompanionCore
import SwiftUI

struct PetStudioView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderView(
                title: "宠物 Studio",
                subtitle: store.studioTab == .new ? (store.isGenerating ? "AI 会话生成中" : "新建高画质桌面宠物") : "历史创建的宠物"
            ) {
                Picker("", selection: $store.studioTab) {
                    ForEach(StudioTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 206)
            }

            if store.studioTab == .new {
                HStack(alignment: .top, spacing: 18) {
                    NewPetFormView()
                        .frame(minWidth: 460)
                    AISessionPanel()
                        .frame(minWidth: 420)
                }
            } else {
                PetLibraryView()
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 28)
    }
}

struct HeaderView<Trailing: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

struct NewPetFormView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 18) {
                Text("新建宠物")
                    .font(.title3.bold())

                VStack(alignment: .leading, spacing: 7) {
                    Text("描述")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $store.descriptionText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(height: 112)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor).opacity(0.75))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(APCDesign.stroke))
                        )
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("风格预设")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 9) {
                        ForEach(StylePreset.allCases) { style in
                            PillButton(title: style.rawValue, selected: style == store.selectedStyle) {
                                store.selectedStyle = style
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("图像画质 · 实机渲染分辨率")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(QualityLevel.allCases) { quality in
                            Button {
                                store.selectedQuality = quality
                            } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(quality.title)
                                        .font(.headline)
                                    Text(quality.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(quality == store.selectedQuality ? APCDesign.accentSoft : Color(nsColor: .controlBackgroundColor))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14)
                                                .stroke(quality == store.selectedQuality ? APCDesign.accent.opacity(0.55) : APCDesign.stroke)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("参考图")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Button {
                        store.referenceImages.append("reference-\(store.referenceImages.count + 1).png")
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                            Text(store.referenceImages.isEmpty ? "拖入图片或点击选择" : "已选择 \(store.referenceImages.count) 张，继续添加")
                        }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 76)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                .foregroundStyle(APCDesign.stroke)
                        )
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Spacer()
                    SecondaryActionButton(title: "清空", systemImage: "xmark") {
                        store.descriptionText = ""
                        store.referenceImages.removeAll()
                    }
                    PrimaryActionButton(title: "发起 AI 会话", systemImage: "sparkles") {
                        store.startGeneration()
                    }
                }
            }
        }
    }
}

struct AISessionPanel: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 18) {
                Text("AI 会话")
                    .font(.title3.bold())

                VStack(alignment: .leading, spacing: 12) {
                    if store.isGenerating || store.generationProgress > 0 {
                        FormSummary()
                    }
                    GenerationSteps()
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 480, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.48))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(APCDesign.stroke))
                )

                HStack(spacing: 10) {
                    TextField("继续描述或输入调整意见", text: .constant(""))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(APCDesign.stroke))
                        )
                    Button {
                        store.generationMessages.append(GenerationMessage(role: "user", content: "裙摆更轻一点，等待确认动作更明显。", progress: store.generationProgress, createdAt: ""))
                    } label: {
                        Text("发送")
                            .font(.callout.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.black))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct FormSummary: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            SummaryTile(title: "风格", value: store.selectedStyle.rawValue)
            SummaryTile(title: "画质", value: "\(store.selectedQuality.title) · \(store.selectedQuality.renderSize.width)×\(store.selectedQuality.renderSize.height)")
            SummaryTile(title: "参考图", value: "\(store.referenceImages.count) 张")
            SummaryTile(title: "状态", value: "7 个动作")
        }
    }
}

struct SummaryTile: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout.weight(.bold))
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(APCDesign.stroke))
        )
    }
}

struct GenerationSteps: View {
    @EnvironmentObject private var store: AppStore

    private let steps = ["读取表单", "补充需求", "生成宠物", "保存入库"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                let active = activeIndex >= index
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.headline.bold())
                        .foregroundStyle(active ? .white : .secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(active ? APCDesign.accent : Color(nsColor: .quaternaryLabelColor).opacity(0.25)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)
                        Text(stepDetail(index))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(active ? APCDesign.accentSoft.opacity(0.75) : Color(nsColor: .controlBackgroundColor).opacity(0.55))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(active ? APCDesign.accent.opacity(0.35) : APCDesign.stroke))
                )
            }

            if !store.generationMessages.isEmpty {
                Divider()
                ForEach(store.generationMessages) { message in
                    MessageBubble(message: message)
                }
            }
        }
    }

    private var activeIndex: Int {
        switch store.generationProgress {
        case 0..<0.25: 0
        case 0.25..<0.60: 1
        case 0.60..<0.96: 2
        default: 3
        }
    }

    private func stepDetail(_ index: Int) -> String {
        switch index {
        case 0: "描述、风格、画质、参考图。"
        case 1: "信息不足时在会话中追问。"
        case 2: "主形象与状态动作。"
        default: "完成后进入宠物库。"
        }
    }
}

struct MessageBubble: View {
    var message: GenerationMessage

    var body: some View {
        Text(message.content)
            .font(.callout)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(message.role == "user" ? APCDesign.accent : Color(nsColor: .controlBackgroundColor))
            )
            .foregroundStyle(message.role == "user" ? .white : .primary)
            .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
    }
}

struct FlowLayout<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: spacing) {
            content
        }
    }
}
