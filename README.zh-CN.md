# Agent Pet Companion

中文 | [English](README.md)

Agent Pet Companion 是一款面向编码 Agent 用户的 macOS 原生桌宠 App。你可以通过 AI 辅助 Studio 设计本地桌宠，把它放在桌面上，并让它响应 Agent 的工作状态。

本项目已开源，目前处于本地 V1 开发阶段，暂未提供可安装的公开版本。仓库中已经包含可运行的 SwiftPM macOS App、Rust PetCore daemon、CLI、schema 和阶段验证脚本。准确的验证结果与发布阻塞项以带日期的[项目状态](docs/PROJECT_STATUS.md)为准。

> **App 内 AI 宠物制作前置要求：** macOS App 内置 Studio 当前**仅使用 Codex**。普通用户需要在本机安装并登录 ChatGPT 桌面 App，且当前账号可正常使用 Codex。PetCore 会启动 ChatGPT 内置的 Codex App Server，以创建、修改和恢复 Studio 会话。具备真实图像理解与图像生成/编辑能力的 Claude Code、Pi、Hermes、OpenCode 等 Agent Skills 宿主，可以在 App 外使用可移植 `agent-pet-maker` 技能创建或修改 `.petpack`，再导入 App；它们仍不是 App 内 Studio 后端。

## 产品简介

- 根据描述、风格偏好、图像画质和可选参考图创建个性化桌宠。
- 在 macOS 桌面上显示高画质悬浮桌宠。
- 让桌宠响应 Agent 的思考、执行工具、等待确认、待查看、完成、失败等状态。
- 每个 Agent 使用一个原生消息气泡，同一 Agent 的活跃会话按标题、最多两行的当前活动或回复、状态和「打开」操作分行展示。
- 本地保存宠物库，支持启用、删除、查看资源信息、原子导出、重新导入和通过 Codex 修改。
- 提供 Codex、Claude Code、Pi Coding Agent、OpenCode 的连接检查。

## 功能与能力

### 宠物 Studio

从一个简单表单开始，通过 Codex App Server 会话继续调整宠物的外观、动作和行为。App 也可以为任意库内宠物（包括外部导入宠物）新建 Codex 修改会话：以当前包作为不可信但已校验的基线，保持同一宠物 ID，以不可变 revision 原子提交；若 Codex 工作期间基线已变化，会拒绝覆盖。这是 App 内 Codex 链路；仅连接其他 Agent 不会把它们变成 App 内 Studio 后端。正式 Studio 默认要求图像能力工具产出完整 `skill-full-source`；只有 provenance、透明资源、七状态、每状态帧差异、manifest、预览和构建校验全部通过后，PetCore 才允许入库。确定性 materializer 仅用于显式 simulated 验证，不会冒充 AI 图像生成。

### 桌面悬浮层

桌宠会以 macOS 悬浮层形式出现在桌面。你可以按住左键拖动它的位置，通过右下角缩放手柄调整大小；普通左键单击不触发额外界面，仅右击宠物打开快捷菜单。

### Agent 状态响应

Agent Pet Companion 会监听受支持的本地 Agent 事件通道，并把 Agent 状态映射为桌宠动作：

- 开始处理：start
- 执行工具：tool
- 等待确认：waiting
- 待查看：review
- 完成：done
- 失败：failed

macOS App 是一个轻量单实例 UI Host，统一承载控制中心、状态栏入口、桌宠和消息气泡。关闭控制中心窗口不会停止 UI Host 和桌宠；执行标准「退出」会退出全部 UI，但独立的 PetCore LaunchAgent 继续承担事件和数据连续性。

### 本地宠物库

你创建的宠物会保存在本机。所有导入包都经过同一套 PetCore 校验。宠物库支持启用、查看、删除、原子导出 `.petpack`、无损重新导入，并可对 App 创建或外部导入的宠物发起同 ID Codex 修订。

### 可移植 `.petpack` 工作流

完整 v1 格式与兼容策略见 [Petpack v1 白皮书](docs/specifications/AgentPetCompanion_Petpack_Whitepaper_V1.md)。任何工具只要产出符合该契约的包，都可以被 App 导入和运行。

与供应商无关的 [`agent-pet-maker`](skills/agent-pet-maker/SKILL.md) 技能会随开发 App 包一起提供，可交给具备真实图像能力的 Codex、Claude Code、Pi、Hermes、OpenCode 或其他 Agent Skills 宿主使用。它支持 `create` 与 `modify`，最终统一调用 `petcore-cli` 校验/构建；修改时保持 ID、核对未改状态哈希；宿主没有真实图像工具时会返回 `capability_missing`，不会用样例或几何图冒充生成结果。创建和构建默认不会改动宠物库；只有用户明确要求导入时才可使用独立的在线 `install`，启用还必须再次明确指定 `--activate`，并且不会擅自打开全局桌宠开关。

安装时必须复制**完整的** `agent-pet-maker` 目录（包括 `references/`、`scripts/`、`agents/` 和 `tests/`），不能只复制 `SKILL.md`。仓库中的目录是 `skills/agent-pet-maker/`；构建后的 App 中位于 `AgentPetCompanion.app/Contents/Resources/skills/agent-pet-maker/`。各宿主当前安装位置如下：

| 宿主 | 安装位置 | 调用方式 |
|---|---|---|
| [Codex](https://developers.openai.com/codex/skills/) | 在 App 中打开**Agent 连接 → Codex → 修复**；App 管理的插件会把完整技能安装到 `~/.agents/plugins/plugins/agent-pet-companion/skills/agent-pet-maker/`。 | 使用自然语言请求，或显式提及可靠的插件限定名 `$agent-pet-companion:agent-pet-maker`。Codex 通常会自动发现修复后的插件；若已有会话未显示该技能，请重启 Codex。Codex CLI 0.144.4 中短名 `$agent-pet-maker` 虽能解析，但不会注入技能正文。 |
| [Claude Code](https://code.claude.com/docs/en/skills) | `~/.claude/skills/agent-pet-maker/` | 自然语言请求，或执行 `/agent-pet-maker`。 |
| [Pi](https://pi.dev/docs/latest/skills) | `~/.pi/agent/skills/agent-pet-maker/` 或 `~/.agents/skills/agent-pet-maker/` | 自然语言请求，或执行 `/skill:agent-pet-maker`；也支持 `--skill <path>`。 |
| [Hermes](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills) | `~/.hermes/skills/agent-pet-maker/` | 自然语言请求，或执行 `/agent-pet-maker`。 |
| [OpenCode](https://opencode.ai/docs/skills/) | `~/.config/opencode/skills/agent-pet-maker/` 或 `~/.agents/skills/agent-pet-maker/` | 自然语言请求；OpenCode 会通过原生 `skill` 工具加载。 |

各宿主官方文档列出的项目级目录同样可用。安装前应先审阅技能内容：它会执行随附的 Python helper 和 App 提供的 `petcore-cli`，但不得读取 Agent 凭据，也不得静默修改宠物库。

## 支持平台

- macOS 14 或更高版本
- V1 主要面向 Apple Silicon 优化；可分发版本还必须包含并验证 `x86_64` slice
- 使用 App 内 AI Studio 时：必须安装并登录 ChatGPT 桌面 App，且当前账号可正常使用 Codex。外部可移植技能则要求宿主 Agent 具备真实图像能力，并能使用 App 提供的 `petcore-cli`。

Windows、云端账号、公共宠物分享和公共素材库不在首个版本范围内。

## 本地开发

当前暂未发布可安装版本。

本地开发需要 Xcode 16 或更高版本（Swift 6）、`rust-toolchain.toml` 固定的 Rust 1.96.0，以及用于验证辅助脚本的 Python 3。然后运行：

```bash
./script/test_all.sh
./script/build_and_run.sh --build-only
./script/build_app_bundle.sh
```

截至 2026-07-16，默认验证、Rust fmt/clippy/tests 与 10 个 suites 中的 95 个 Swift tests 均为绿色；真实连接器、真实 App Server、Renderer 预算、packaged App Studio 和 Computer Use 七状态桌宠渲染检查也已完成。准确证据和外部用户确认项仍以[项目状态](docs/PROJECT_STATUS.md)为准。

默认命令全部使用隔离环境，不会启动 GUI、修改 LaunchAgent、调用真实 Agent 或读取凭据。宿主 UI 检查要求 `APC_VALIDATE_HOST_UI=1`；真实 connector 和真实 App Server 各自使用独立的显式 opt-in gate。

`script/build_and_run.sh` 会构建 Rust workspace、构建 SwiftPM GUI App、生成 `dist/AgentPetCompanion.app`，并把 `petcore` 与 `petcore-cli` 一起打包；只有显式打开宿主 UI 验证 gate 时，才会用隔离的临时 App home 启动并管理本次验证拥有的进程。

验证已拆分为 `fast/core`、`simulated integration`、`macos runtime`、`real agent connectors`、`real app server` 和 `perf/nightly` 层级；详见 [script/validate_profiles.md](script/validate_profiles.md)。`script/test_all.sh` 会明确标注 simulated 检查，并输出真实运行时 gate 的跳过原因。

贡献规则见 [CONTRIBUTING.md](CONTRIBUTING.md)。`script/build_app_bundle.sh` 默认同时生成 ad-hoc 签名的 `dist/AgentPetCompanion-develop.zip`，用于非正式开发交接；它不是公开发布版本。universal Developer ID 签名与 notarization 的完整流程见 [docs/release/macos-release.md](docs/release/macos-release.md)。

首个签名版本完成后，将通过 GitHub Releases 提供安装包：

1. 下载签名后的 macOS 安装包。
2. 将 Agent Pet Companion 移动到 `Applications`。
3. 打开 App，并按应用内的连接检查完成配置。

当前 simulated AI 验证只会在验证脚本显式启用时使用确定性的本地 Pet Studio 预览。无法使用 `CODEX_APP_SERVER_CMD` 时，probe 会返回处理建议/跳过原因。`script/validate_real_app_server.sh` 验证真实 stdio 边界；严格外部 source 模式还会拒绝确定性 helper，并要求 image-generation/reference-derived provenance 及可见的帧间、状态间差异。

开发与验证环境可以降级使用 `PATH` 中独立的 `codex` 可执行文件，或显式设置 `CODEX_APP_SERVER_CMD`。这两项属于开发者覆盖配置；普通用户正式使用 Pet Studio 时，支持的路径仍是 ChatGPT 桌面 App 内置的 Codex App Server。

packaged App 验收还对同一个真实产物完成了完整闭环：`星雾团子` 由 Codex 图像生成，完成校验、入库、启用，并逐一渲染七种宠物状态。Pet Studio 自己的内部 Codex 生成任务不会进入普通 Agent 会话气泡。

如需验收当前机器上的真实 Agent connector，请先启动已打包 App，然后运行：

```bash
APC_VALIDATE_REAL_AGENT_CONNECTORS=1 ./script/validate_real_agent_connectors.sh
```

该脚本通过已安装的 Codex、Claude Code、Pi、OpenCode connector 文件发送诊断事件，并从当前 App 读取回执；它不会读取 Agent 的 auth、token 或 cookie 文件。

## 使用方式

1. 打开 Agent Pet Companion。
2. 进入宠物 Studio，描述你想要的桌宠。
3. 选择风格预设、图像画质，并按需上传参考图。
4. 发起 AI 辅助会话，通过对话继续调整已验证 source。
5. 在本地宠物库中启用生成好的宠物。
6. 对任意库内宠物使用「AI 修改」，或导出 `.petpack` 交给可移植 Agent Skill 修改后重新导入。
7. 进入 Agent 连接，检查 Codex、Claude Code、Pi Coding Agent 或 OpenCode 集成。
8. 在使用受支持 Agent 工作时，让桌宠停留在桌面并响应状态变化。

## 隐私与安全

Agent Pet Companion 以本地优先为设计原则。应用不应读取 Agent 的 auth、token、cookie、API Key 或其他密钥文件。Agent 响应基于明确的本地事件通道和项目自有的能力令牌。

## 开源协议

Agent Pet Companion 使用 [MIT License](LICENSE) 开源。
