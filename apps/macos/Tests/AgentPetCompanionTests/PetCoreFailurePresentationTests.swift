import Testing
@testable import AgentPetCompanion

@Suite("PetCore failure presentation")
struct PetCoreFailurePresentationTests {
    @Test
    func failureBannerUsesLocalizedTypedCopyInsteadOfRawRuntimeReasons() {
        #expect(PetCoreFailurePresentation.detail(for: .offline, localeIdentifier: "en")
            == "PetCore cannot currently be reached on the local transport.")
        #expect(PetCoreFailurePresentation.detail(for: .runtimeMismatch, localeIdentifier: "zh-Hans")
            == "正在运行的 PetCore 与当前 App 构建不兼容。")
        #expect(!PetCoreFailurePresentation.detail(for: .error, localeIdentifier: "en")
            .contains("本地服务"))
    }
}
