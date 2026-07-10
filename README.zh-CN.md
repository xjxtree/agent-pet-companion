# Agent Pet Companion

中文 | [English](README.md)

Agent Pet Companion 是一款面向编码 Agent 用户的 macOS 原生桌宠 App。你可以通过 AI 辅助 Studio 设计本地桌宠，把它放在桌面上，并让它响应 Agent 的工作状态。

本项目已开源，目前处于本地 V1 开发阶段，暂未提供可安装的公开版本。仓库中已经包含可运行的 SwiftPM macOS App、Rust PetCore daemon、CLI、schema 和阶段验证脚本。

## 产品简介

- 根据描述、风格偏好、图像画质和可选参考图创建个性化桌宠。
- 在 macOS 桌面上显示高画质悬浮桌宠。
- 让桌宠响应 Agent 的思考、执行工具、等待确认、待查看、完成、失败等状态。
- 本地保存宠物库，支持启用、删除、查看资源信息和导出。
- 提供 Codex、Claude Code、Pi Coding Agent、OpenCode 的连接检查。

## 功能与能力

### 宠物 Studio

从一个简单表单开始，通过 AI 会话继续调整宠物的外观、动作和行为。当前内置 materializer 生成的是确定性动画预览，不会冒充 AI 图像生成；只有图像能力工具产出可见差异的完整帧序列并通过语义校验后，才会标记为 `skill-full-source`。预览和已验证 source 都保存为本地 `.petpack`。

### 桌面悬浮层

桌宠会以 macOS 悬浮层形式出现在桌面。你可以拖动它的位置，通过右下角缩放手柄调整大小，也可以点击桌宠打开快捷菜单。

### Agent 状态响应

Agent Pet Companion 会监听受支持的本地 Agent 事件通道，并把 Agent 状态映射为桌宠动作：

- 开始处理：start
- 执行工具：tool
- 等待确认：waiting
- 待查看：review
- 完成：done
- 失败：failed

### 本地宠物库

你创建的宠物会保存在本机。宠物库用于启用宠物、查看资源信息、删除本地宠物，以及导出 `.petpack` 文件。

## 支持平台

- macOS 14 或更高版本
- V1 主要面向 Apple Silicon 优化；可分发版本还必须包含并验证 `x86_64` slice

Windows、云端账号、公共宠物分享和公共素材库不在首个版本范围内。

## 本地开发

当前暂未发布可安装版本。

本地开发需要 Xcode 16 或更高版本（Swift 6）、`rust-toolchain.toml` 固定的 Rust 1.96.0，以及用于验证辅助脚本的 Python 3。然后运行：

```bash
./script/test_all.sh
./script/build_and_run.sh --build-only
./script/build_app_bundle.sh
```

默认命令全部使用隔离环境，不会启动 GUI、修改 LaunchAgent、调用真实 Agent 或读取凭据。宿主 UI 检查要求 `APC_VALIDATE_HOST_UI=1`；真实 connector 和真实 App Server 各自使用独立的显式 opt-in gate。

`script/build_and_run.sh` 会构建 Rust workspace、构建 SwiftPM GUI App、生成 `dist/AgentPetCompanion.app`，并把 `petcore` 与 `petcore-cli` 一起打包；只有显式打开宿主 UI 验证 gate 时，才会用隔离的临时 App home 启动并管理本次验证拥有的进程。

验证已拆分为 `fast/core`、`simulated integration`、`macos runtime`、`real agent connectors`、`real app server` 和 `perf/nightly` 层级；详见 [script/validate_profiles.md](script/validate_profiles.md)。`script/test_all.sh` 会明确标注 simulated 检查，并输出真实运行时 gate 的跳过原因。

贡献规则见 [CONTRIBUTING.md](CONTRIBUTING.md)。universal 签名与 notarization 的完整流程见 [docs/release/macos-release.md](docs/release/macos-release.md)；未签名的开发 bundle 不是可分发版本。

首个签名版本完成后，将通过 GitHub Releases 提供安装包：

1. 下载签名后的 macOS 安装包。
2. 将 Agent Pet Companion 移动到 `Applications`。
3. 打开 App，并按应用内的连接检查完成配置。

当前 simulated AI 验证只会在验证脚本显式启用时使用确定性的本地 Pet Studio 预览。无法使用 `CODEX_APP_SERVER_CMD` 时，probe 会返回处理建议/跳过原因。`script/validate_real_app_server.sh` 验证真实 stdio 边界；严格外部 source 模式还会拒绝确定性 helper，并要求 image-generation/reference-derived provenance 及可见的帧间、状态间差异。

如需验收当前机器上的真实 Agent connector，请先启动已打包 App，然后运行：

```bash
APC_VALIDATE_REAL_AGENT_CONNECTORS=1 ./script/validate_real_agent_connectors.sh
```

该脚本通过已安装的 Codex、Claude Code、Pi、OpenCode connector 文件发送诊断事件，并从当前 App 读取回执；它不会读取 Agent 的 auth、token 或 cookie 文件。

## 使用方式

1. 打开 Agent Pet Companion。
2. 进入宠物 Studio，描述你想要的桌宠。
3. 选择风格预设、图像画质，并按需上传参考图。
4. 发起 AI 辅助会话，通过对话继续调整宠物预览或已验证 source。
5. 在本地宠物库中启用生成好的宠物。
6. 进入 Agent 连接，检查 Codex、Claude Code、Pi Coding Agent 或 OpenCode 集成。
7. 在使用受支持 Agent 工作时，让桌宠停留在桌面并响应状态变化。

## 隐私与安全

Agent Pet Companion 以本地优先为设计原则。应用不应读取 Agent 的 auth、token、cookie、API Key 或其他密钥文件。Agent 响应基于明确的本地事件通道和项目自有的能力令牌。

## 开源协议

Agent Pet Companion 使用 [MIT License](LICENSE) 开源。
