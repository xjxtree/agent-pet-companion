import AgentPetCompanionCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PetStudioView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        PageScroll {
            HeaderView(
                title: "宠物 Studio",
                subtitle: store.studioTab == .new
                    ? (store.generationSession.isActive ? store.generationStateTitle : "新建桌面宠物预览")
                    : "历史创建的宠物"
            ) {
                Picker(APCLocalization.text(.studioPickerLabel), selection: $store.studioTab) {
                    ForEach(StudioTab.allCases) { tab in
                        Text(tabTitle(tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(APCLocalization.text(.studioPickerLabel))
                .frame(width: 206)
            }

            if store.studioTab == .new {
                AdaptiveTwoColumnLayout(minimumColumnWidth: 300, spacing: 18) {
                    NewPetFormView()
                    AISessionPanel()
                }
            } else {
                PetLibraryView()
            }
        }
    }

    private func tabTitle(_ tab: StudioTab) -> String {
        APCLocalization.text(tab == .new ? .studioTabNew : .studioTabLibrary)
    }
}

struct HeaderView<Trailing: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) {
                titleBlock
                Spacer(minLength: 16)
                trailing
            }

            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                trailing
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
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

                if store.generationSession.isActive {
                    Label("活动任务使用已提交表单；完成或取消前草稿已冻结", systemImage: "lock.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("已提交表单已冻结")
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("描述")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: Binding(
                            get: { store.descriptionText },
                            set: { store.updateGenerationDescription($0) }
                        ))
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(height: 112)
                            .accessibilityLabel("宠物描述")
                            .disabled(store.generationSession.isActive)

                        if store.descriptionText.isEmpty {
                            Text("描述宠物外观、气质和动作")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }
                    .apcLiquidGlass(
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                        interactive: true
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("风格预设")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 9) {
                        ForEach(StylePreset.allCases) { style in
                            PillButton(
                                title: style.rawValue,
                                selected: style == store.selectedStyle,
                                semanticLabel: UIControlSemantics.styleLabel(style)
                            ) {
                                store.selectGenerationStyle(style)
                            }
                            .disabled(store.generationSession.isActive)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("图像画质 · 实机渲染分辨率")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 12)], spacing: 12) {
                        ForEach(QualityLevel.allCases) { quality in
                            Button {
                                store.selectGenerationQuality(quality)
                            } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text(quality.title)
                                            .font(.headline)
                                        Spacer()
                                        if quality == store.selectedQuality {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(APCDesign.accent)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    Text(quality.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                                .padding(12)
                                .apcLiquidGlass(
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                    interactive: true
                                )
                                .overlay {
                                    if quality == store.selectedQuality {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(APCDesign.accent.opacity(0.62), lineWidth: 1.25)
                                            .allowsHitTesting(false)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(UIControlSemantics.qualityLabel(quality))
                            .accessibilityValue(
                                "\(quality.detail)，\(UIControlSemantics.selectionValue(isSelected: quality == store.selectedQuality))"
                            )
                            .accessibilityAddTraits(quality == store.selectedQuality ? .isSelected : [])
                            .disabled(store.generationSession.isActive)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("参考图")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ReferenceImageDropZone()
                }

                if store.generationSession.isActive {
                    Divider()
                    SubmittedFormSummary(form: store.generationSession.submittedForm)
                }

                HStack {
                    Spacer()
                    SecondaryActionButton(title: "清空", systemImage: "xmark") {
                        store.clearStudioForm()
                    }
                    .disabled(store.generationSession.isActive)
                    PrimaryActionButton(
                        title: store.generationSession.isActive ? store.generationStateTitle : "发起 AI 辅助会话",
                        systemImage: "sparkles"
                    ) {
                        store.startGeneration()
                    }
                    .disabled(!store.canStartGeneration)
                }
            }
        }
    }
}

struct ReferenceImageDropZone: View {
    @EnvironmentObject private var store: AppStore
    @State private var isDropTargeted = false

    var body: some View {
        Button {
            store.chooseReferenceImages()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text(title)
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(isDropTargeted ? APCDesign.accent : .secondary)
            .frame(maxWidth: .infinity, minHeight: 76)
            .apcLiquidGlass(
                in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                interactive: true
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isDropTargeted ? APCDesign.accent.opacity(0.65) : APCDesign.stroke,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                    )
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .disabled(store.generationSession.isActive)
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isDropTargeted,
            perform: handleDrop(providers:)
        )
        if !store.referenceImages.isEmpty {
            ReferenceImageStrip(paths: store.referenceImages)
                .disabled(store.generationSession.isActive)
        }
    }

    private var title: String {
        if store.referenceImages.isEmpty {
            return "拖入图片或点击选择"
        }
        return "已选择 \(store.referenceImages.count) 张，继续添加"
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !store.generationSession.isActive else { return false }
        var acceptedDrop = false

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            acceptedDrop = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = ReferenceImageDropItem.fileURL(from: item) else { return }
                Task { @MainActor in
                    store.addReferenceImageURLs([url])
                }
            }
        }

        return acceptedDrop
    }
}

struct ReferenceImageStrip: View {
    @EnvironmentObject private var store: AppStore
    var paths: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(paths, id: \.self) { path in
                    ReferenceImageChip(path: path) {
                        store.removeReferenceImage(path)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct ReferenceImageChip: View {
    var path: String
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(APCDesign.stroke))

            Text(fileName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 122, alignment: .leading)

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .apcLiquidGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 6)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .apcLiquidGlass(
            in: RoundedRectangle(cornerRadius: 12, style: .continuous),
            interactive: true
        )
    }

    private var image: NSImage? {
        NSImage(contentsOfFile: path)
    }

    private var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

private enum ReferenceImageDropItem {
    static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let nsURL = item as? NSURL {
            return nsURL as URL
        }

        if let data = item as? Data,
           let string = String(data: data, encoding: .utf8),
           let url = URL(string: string) {
            return url
        }

        if let string = item as? String {
            return URL(string: string)
        }

        return nil
    }
}

struct AISessionPanel: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 18) {
                Text("AI 辅助会话")
                    .font(.title3.bold())

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        if store.generationSession.state != .idle {
                            FormSummary()
                        }
                        GenerationSteps()
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.visible)
                .frame(maxWidth: .infinity, minHeight: 360, maxHeight: 520, alignment: .topLeading)
                .apcLiquidGlass(
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        replyField
                        sessionActions
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        replyField
                        HStack(spacing: 10) {
                            sessionActions
                        }
                    }
                }
            }
        }
    }

    private var replyField: some View {
        TextField(replyPlaceholder, text: $store.generationReplyText)
            .textFieldStyle(.plain)
            .onSubmit {
                store.sendGenerationReply()
            }
            .disabled(!replyInputEnabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .apcLiquidGlass(
                in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                interactive: true
            )
    }

    @ViewBuilder
    private var sessionActions: some View {
        if store.generationSession.isActive {
            SecondaryActionButton(
                title: store.generationSession.state == .cancelling ? "正在取消" : "取消",
                systemImage: "xmark.circle"
            ) {
                store.cancelGeneration()
            }
            .disabled(!store.generationSession.canCancel)
        }
        if store.canRetryGeneration {
            SecondaryActionButton(title: "重试", systemImage: "arrow.clockwise") {
                store.retryGeneration()
            }
        }
        Button {
            store.sendGenerationReply()
        } label: {
            Label("发送", systemImage: "arrow.up")
                .font(.callout.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canSend)
    }

    private var canSend: Bool {
        replyInputEnabled && !store.generationReplyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var replyInputEnabled: Bool {
        store.canSendGenerationReply
    }

    private var replyPlaceholder: String {
        if store.isWaitingForGenerationInput {
            return "回复 AI 的追问后继续生成"
        }
        if store.generationSession.state == .cancelling {
            return "正在取消当前任务"
        }
        if store.generationSession.isActive {
            return "生成完成后可继续调整"
        }
        if store.generationSession.jobID == nil {
            return "发起 AI 辅助会话后可继续调整"
        }
        if !store.canSendGenerationReply {
            return "生成成功后可继续调整"
        }
        return "继续描述或输入调整意见"
    }

}

struct FormSummary: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        SubmittedFormSummary(form: store.generationSession.submittedForm)
    }
}

struct SubmittedFormSummary: View {
    @EnvironmentObject private var store: AppStore
    var form: GenerationForm?

    var body: some View {
        if let form {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 10)], spacing: 10) {
                SummaryTile(title: "描述", value: form.description)
                SummaryTile(title: "风格", value: form.style)
                SummaryTile(
                    title: "画质",
                    value: "\(form.quality.title) · \(form.quality.renderSize.width)×\(form.quality.renderSize.height)"
                )
                SummaryTile(title: "参考图", value: "\(form.referenceImages.count) 张")
                SummaryTile(title: "会话状态", value: store.generationStateTitle)
            }
        } else {
            Label("当前会话未提供已提交表单摘要", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .apcLiquidGlass(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}

struct GenerationSteps: View {
    @EnvironmentObject private var store: AppStore

    private let steps = ["读取表单", "补充需求", "生成预览", "保存入库"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                let active = activeIndex >= index
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.headline.bold())
                        .foregroundStyle(active ? APCDesign.onAccent : .secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(active ? APCDesign.accent : Color(nsColor: .quaternaryLabelColor).opacity(0.18)))
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
                .apcLiquidGlass(
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay {
                    if active {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(APCDesign.accent.opacity(0.32), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
            }

            if !store.generationSession.messages.isEmpty {
                Divider()
                ForEach(store.generationSession.messages) { message in
                    MessageBubble(message: message)
                }
            }
        }
    }

    private var activeIndex: Int {
        GenerationConversation.activeStepIndex(
            messages: store.generationSession.messages,
            progress: store.generationSession.progress
        )
    }

    private func stepDetail(_ index: Int) -> String {
        let needsInput = store.isWaitingForGenerationInput
        let failed = store.generationSession.state == .failed
        let succeeded = store.generationSession.state == .succeeded

        return switch index {
        case 0: "描述、风格、画质、参考图。"
        case 1: needsInput ? "等待你的回复后继续生成。" : "信息不足时在会话中追问。"
        case 2: failed ? "生成未完成，查看会话消息。" : "主形象与状态动作。"
        default: succeeded ? "已进入宠物库。" : "完成后进入宠物库。"
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
            .apcLiquidGlass(
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                if message.role == "user" {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(APCDesign.accent.opacity(0.45), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
    }
}

struct FlowLayout<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        WrappingFlowLayout(spacing: spacing) {
            content
        }
    }
}

private struct WrappingFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = rows(for: subviews, maxWidth: resolvedMaxWidth(from: proposal))
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(CGFloat.zero) { partial, row in
            partial + row.height
        } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = rows(for: subviews, maxWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [FlowRow] {
        var rows: [FlowRow] = []
        var current = FlowRow()
        let wrappingWidth = maxWidth.isFinite && maxWidth > 0 ? maxWidth : .greatestFiniteMagnitude

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let nextWidth = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty && nextWidth > wrappingWidth {
                rows.append(current)
                current = FlowRow()
            }
            current.append(FlowItem(index: index, size: size), spacing: spacing)
        }

        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }

    private func resolvedMaxWidth(from proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width, width.isFinite, width > 0 else {
            return .greatestFiniteMagnitude
        }
        return width
    }

    private struct FlowItem {
        var index: Subviews.Index
        var size: CGSize
    }

    private struct FlowRow {
        var items: [FlowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func append(_ item: FlowItem, spacing: CGFloat) {
            if !items.isEmpty {
                width += spacing
            }
            items.append(item)
            width += item.size.width
            height = max(height, item.size.height)
        }
    }
}
