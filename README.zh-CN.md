# Agent Pet Companion

中文 | [English](README.md)

Agent Pet Companion 是一款面向编码 Agent 用户的 macOS 原生桌宠 App。你可以通过 AI 辅助 Studio 设计本地桌宠，把它放在桌面上，并让它响应 Agent 的工作状态。

本项目已开源，目前处于本地 V1 开发阶段，暂未提供可安装的公开版本。仓库中已经包含可运行的 SwiftPM macOS App、Rust PetCore daemon、CLI、schema 和阶段验证脚本。准确的验证结果与发布阻塞项以带日期的[项目状态](docs/PROJECT_STATUS.md)为准。

> **AI 宠物制作前置要求：** 当前 AI 宠物制作**仅支持 Codex**。普通用户需要在本机安装并登录 ChatGPT 桌面 App，且当前账号可正常使用 Codex。PetCore 会启动 ChatGPT 内置的 Codex App Server，以创建和恢复 Studio 生成会话。Claude Code、Pi Coding Agent、OpenCode 当前只向桌宠提供 Agent 会话活动，不是 Pet Studio 的宠物生成后端。

## 产品简介

- 根据描述、风格偏好、图像画质和可选参考图创建个性化桌宠。
- 在 macOS 桌面上显示高画质悬浮桌宠。
- 让桌宠响应 Agent 的思考、执行工具、等待确认、待查看、完成、失败等状态。
- 每个 Agent 使用一个原生消息气泡，同一 Agent 的活跃会话按标题、最多两行的当前活动或回复、状态和「打开」操作分行展示。
- 本地保存宠物库，支持启用、删除、查看资源信息和导出。
- 提供 Codex、Claude Code、Pi Coding Agent、OpenCode 的连接检查。

## 功能与能力

### 宠物 Studio

从一个简单表单开始，通过 Codex App Server 会话继续调整宠物的外观、动作和行为。这是一条仅支持 Codex 的制作链路；仅安装或连接 Claude Code、Pi Coding Agent、OpenCode，不能启用 Pet Studio 生成。正式 Studio 默认要求图像能力工具产出完整 `skill-full-source`；只有 provenance、透明资源、七状态、每状态帧差异、manifest、预览和构建校验全部通过后，PetCore 才允许入库。确定性 materializer 仅用于显式 simulated 验证，不会冒充 AI 图像生成。已验证宠物保存为本地 `.petpack`。

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

你创建的宠物会保存在本机。宠物库用于启用宠物、查看资源信息、删除本地宠物，以及导出 `.petpack` 文件。

## 支持平台

- macOS 14 或更高版本
- V1 主要面向 Apple Silicon 优化；可分发版本还必须包含并验证 `x86_64` slice
- 使用 AI 制作宠物时：必须安装并登录 ChatGPT 桌面 App，且当前账号可正常使用 Codex

Windows、云端账号、公共宠物分享和公共素材库不在首个版本范围内。

## 本地开发

当前暂未发布可安装版本。

本地开发需要 Xcode 16 或更高版本（Swift 6）、`rust-toolchain.toml` 固定的 Rust 1.96.0，以及用于验证辅助脚本的 Python 3。然后运行：

```bash
./script/test_all.sh
./script/build_and_run.sh --build-only
./script/build_app_bundle.sh
```

截至 2026-07-15，默认 `test_all.sh`、Rust fmt/clippy/tests 与 79 个 Swift tests 均为绿色；真实连接器、真实 App Server、Renderer 预算、packaged App Studio 和 Computer Use 七状态桌宠渲染检查也已完成。准确证据和外部用户确认项仍以[项目状态](docs/PROJECT_STATUS.md)为准。

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
6. 进入 Agent 连接，检查 Codex、Claude Code、Pi Coding Agent 或 OpenCode 集成。
7. 在使用受支持 Agent 工作时，让桌宠停留在桌面并响应状态变化。

## 隐私与安全

Agent Pet Companion 以本地优先为设计原则。应用不应读取 Agent 的 auth、token、cookie、API Key 或其他密钥文件。Agent 响应基于明确的本地事件通道和项目自有的能力令牌。

## 开源协议

Agent Pet Companion 使用 [MIT License](LICENSE) 开源。
