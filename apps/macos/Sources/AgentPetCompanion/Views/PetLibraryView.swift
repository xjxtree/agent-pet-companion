import AgentPetCompanionCore
import AppKit
import SwiftUI

struct PetLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var pendingDeletePet: PetSummary?
    @State private var selectedPetID: String?

    private var selectedPet: PetSummary? {
        if let selectedPetID,
           let pet = store.pets.first(where: { $0.id == selectedPetID }) {
            return pet
        }
        return store.activePet ?? store.pets.first
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                librarySurface
                    .frame(minWidth: 0, maxWidth: .infinity)
                detailSurface
                    .frame(minWidth: 260, idealWidth: 304, maxWidth: 330)
            }

            VStack(alignment: .leading, spacing: 18) {
                librarySurface
                detailSurface
            }
        }
        .confirmationDialog(
            pendingDeletePet.map { $0.active ? "删除当前宠物？" : "删除宠物？" } ?? "删除宠物？",
            isPresented: Binding(
                get: { pendingDeletePet != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeletePet = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletePet
        ) { pet in
            Button("删除 \(pet.name)", role: .destructive) {
                store.deletePet(pet)
                pendingDeletePet = nil
            }
            Button("取消", role: .cancel) {
                pendingDeletePet = nil
            }
        } message: { pet in
            if pet.active {
                Text("这是当前正在显示的桌宠。删除后会移除本 App 自有 .petpack 资源，并自动切换到宠物库中的下一个宠物。")
            } else {
                Text("将删除本 App 自有 .petpack 资源，此操作不会上传或保留副本。")
            }
        }
    }

    private var librarySurface: some View {
        Surface {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("宠物库")
                        .font(.title3.bold())
                    Spacer()
                    SecondaryActionButton(
                        title: APCLocalization.text(
                            store.isImportingPetpack ? .libraryImportInProgress : .libraryImportAction
                        ),
                        systemImage: "square.and.arrow.down"
                    ) {
                        store.importPetpacks()
                    }
                    .disabled(store.isImportingPetpack)
                }
                if store.pets.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(APCLocalization.text(.libraryEmptyTitle), systemImage: "pawprint")
                            .font(.headline)
                        Text(APCLocalization.text(.libraryEmptyDetail))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        PrimaryActionButton(
                            title: APCLocalization.text(.libraryEmptyAction),
                            systemImage: "plus"
                        ) {
                            store.studioTab = .new
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
                    .accessibilityElement(children: .contain)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14, alignment: .top)], spacing: 14) {
                        ForEach(store.pets) { pet in
                            PetCard(
                                pet: pet,
                                selected: selectedPet?.id == pet.id,
                                onSelect: {
                                    selectedPetID = pet.id
                                }
                            ) {
                                pendingDeletePet = pet
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var detailSurface: some View {
        Surface {
            CurrentPetDetail(pet: selectedPet) { pet in
                pendingDeletePet = pet
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct PetCard: View {
    @EnvironmentObject private var store: AppStore
    var pet: PetSummary
    var selected: Bool
    var onSelect: () -> Void
    var onRequestDelete: () -> Void

    var body: some View {
        let busy = store.petOperationIDs.contains(pet.id)
        let presentation = PetLibraryPresentation(
            pet: pet,
            assetWarning: store.petAssetWarningIndex[pet.id]
        )
        VStack(alignment: .leading, spacing: 11) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 11) {
                    ZStack(alignment: .topTrailing) {
                        PetCoverImage(pet: pet, fallbackScale: 0.32)
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(APCDesign.accent)
                                .padding(8)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(height: 68)
                    .apcLiquidGlass(
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )

                    HStack {
                        Text(pet.name)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        StatusBadge(title: pet.active ? "当前" : "可启用", tone: pet.active ? .good : .neutral)
                    }

                    Text("\(pet.style) · \(pet.quality.title) · \(pet.generationSourceTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    StatusBadge(
                        title: presentation.validationTitle,
                        tone: presentation.validationStatus == .invalid ? .warning : .neutral
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择宠物 \(pet.name)")
            .accessibilityValue(UIControlSemantics.selectionValue(isSelected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])

            HStack {
                Button(pet.active ? "已启用" : "启用") {
                    store.activatePet(pet)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(pet.active || busy)

                Spacer()

                Menu("管理") {
                    Button("查看生成会话") {
                        store.openGenerationHistory(for: pet)
                    }
                    Button("导出本 App .petpack") {
                        store.exportPet(pet)
                    }
                    Button("删除", role: .destructive) {
                        onRequestDelete()
                    }
                    .disabled(busy)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .disabled(busy)
            }
        }
        .padding(14)
        .apcLiquidGlass(
            in: RoundedRectangle(cornerRadius: 16, style: .continuous),
            interactive: true
        )
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(APCDesign.accent.opacity(0.72), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct CurrentPetDetail: View {
    @EnvironmentObject private var store: AppStore
    var pet: PetSummary?
    var onRequestDelete: (PetSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("宠物详情")
                .font(.title3.bold())

            if let pet {
                let busy = store.petOperationIDs.contains(pet.id)
                let presentation = PetLibraryPresentation(
                    pet: pet,
                    assetWarning: store.petAssetWarningIndex[pet.id]
                )
                HStack(spacing: 16) {
                    ZStack {
                        PetCoverImage(pet: pet, fallbackScale: 0.42)
                    }
                    .frame(width: 112, height: 130)
                    .apcLiquidGlass(
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text(pet.name)
                            .font(.title3.bold())
                            .lineLimit(2)
                        Text("\(pet.style) · \(pet.quality.title)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        StatusBadge(title: pet.active ? "当前宠物" : "可启用", tone: pet.active ? .accent : .neutral)
                    }
                }
                .padding()
                .apcLiquidGlass(
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )

                VStack(spacing: 0) {
                    InfoRow(title: "实机画质", value: "\(pet.renderSize.width)×\(pet.renderSize.height)")
                    InfoRow(
                        title: "当前状态",
                        value: presentation.currentStateTitle(activeEvent: store.activeOverlayEvent)
                            ?? APCLocalization.text(.libraryStateNotActive)
                    )
                    InfoRow(
                        title: "状态规格",
                        value: presentation.stateSpecification
                            ?? APCLocalization.text(.librarySpecificationUnavailable)
                    )
                    InfoRow(
                        title: "帧率规格",
                        value: presentation.fpsSpecification
                            ?? APCLocalization.text(.librarySpecificationUnavailable)
                    )
                    InfoRow(title: "生成来源", value: pet.generationSourceTitle)
                    InfoRow(title: "来源标记", value: pet.generationSourceDetail)
                    InfoRow(title: "资源校验", value: presentation.validationTitle)
                    InfoRow(title: "格式", value: APCLocalization.text(.libraryFormatAppOwned))
                }

                Label(
                    presentation.validationDetail,
                    systemImage: presentation.validationStatus == .invalid
                        ? "exclamationmark.triangle.fill"
                        : "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("资源校验详情：\(presentation.validationDetail)")

                HStack {
                    Spacer()
                    SecondaryActionButton(title: "会话", systemImage: "text.bubble") {
                        store.openGenerationHistory(for: pet)
                    }
                    .disabled(busy)
                    SecondaryActionButton(title: "删除", systemImage: "trash") {
                        onRequestDelete(pet)
                    }
                    .disabled(busy)
                    SecondaryActionButton(title: "导出", systemImage: "square.and.arrow.up") {
                        store.exportPet(pet)
                    }
                    .disabled(busy)
                    if pet.active {
                        StatusBadge(title: "已启用", tone: .good)
                    } else {
                        PrimaryActionButton(title: "启用", systemImage: "checkmark.circle") {
                            store.activatePet(pet)
                        }
                        .disabled(busy)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(APCLocalization.text(.libraryEmptyTitle))
                        .font(.headline)
                    Text(APCLocalization.text(.libraryEmptyDetail))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

private struct PetCoverImage: View {
    var pet: PetSummary
    var fallbackScale: CGFloat

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(6)
        } else {
            MissingPetCoverPlaceholder(scale: fallbackScale)
        }
    }

    private var image: NSImage? {
        guard let url = PetAssetLocator.coverURL(for: pet) else { return nil }
        return NSImage(contentsOf: url)
    }
}

private struct MissingPetCoverPlaceholder: View {
    var scale: CGFloat

    var body: some View {
        VStack(spacing: 6 * scale) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: max(14, 32 * scale), weight: .semibold))
                .foregroundStyle(.secondary)
            Text("缺少预览")
                .font(.system(size: max(9, 16 * scale), weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(8)
        .apcLiquidGlass(
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}

struct InfoRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.headline)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: 190, alignment: .trailing)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
