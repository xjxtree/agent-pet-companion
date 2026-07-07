import AgentPetCompanionCore
import SwiftUI

struct PetLibraryView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Surface {
                VStack(alignment: .leading, spacing: 18) {
                    Text("宠物库")
                        .font(.title3.bold())
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                        ForEach(store.pets) { pet in
                            PetCard(pet: pet)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(minWidth: 620)

            Surface {
                CurrentPetDetail(pet: store.activePet)
            }
            .frame(width: 324)
        }
    }
}

struct PetCard: View {
    @EnvironmentObject private var store: AppStore
    var pet: PetSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [APCDesign.cyanSoft, APCDesign.accentSoft, Color.white.opacity(0.65)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                SamplePetIllustration(scale: 0.32)
            }
            .frame(height: 68)

            HStack {
                Text(pet.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                StatusBadge(title: pet.active ? "当前" : "可启用", tone: pet.active ? .good : .neutral)
            }

            Text("\(pet.style) · \(pet.quality.title)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(pet.active ? "已启用" : "启用") {
                    store.activatePet(pet)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(pet.active)

                Spacer()

                Menu("管理") {
                    Button("导出 .petpack") {}
                    Button("删除", role: .destructive) {
                        store.deletePet(pet)
                    }
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(APCDesign.stroke))
        )
    }
}

struct CurrentPetDetail: View {
    var pet: PetSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("当前宠物")
                .font(.title3.bold())

            if let pet {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(LinearGradient(colors: [APCDesign.accentSoft, APCDesign.cyanSoft], startPoint: .topLeading, endPoint: .bottomTrailing))
                        SamplePetIllustration(scale: 0.42)
                    }
                    .frame(width: 112, height: 130)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(pet.name)
                            .font(.title3.bold())
                            .lineLimit(2)
                        Text("\(pet.style) · \(pet.quality.title)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        StatusBadge(title: pet.active ? "正在启用" : "可启用", tone: pet.active ? .accent : .neutral)
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(APCDesign.accentSoft.opacity(0.55))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(APCDesign.accent.opacity(0.25)))
                )

                VStack(spacing: 0) {
                    InfoRow(title: "实机画质", value: "\(pet.renderSize.width)×\(pet.renderSize.height)")
                    InfoRow(title: "动作状态", value: "7")
                    InfoRow(title: "帧率", value: "12 / 20 fps")
                    InfoRow(title: "格式", value: ".petpack")
                }

                HStack {
                    Spacer()
                    SecondaryActionButton(title: "删除", systemImage: "trash") {}
                    PrimaryActionButton(title: "导出", systemImage: "square.and.arrow.up") {}
                }
            } else {
                Text("宠物库为空")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
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
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
