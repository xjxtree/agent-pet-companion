<p align="center">
  <img src="logo/transparent/agent-pet-mark-transparent-1024.png" width="160" alt="Agent Pet Companion 图标">
</p>

# Agent Pet Companion

简体中文 | [English](README.md)

Agent Pet Companion 是一款面向编码 Agent 用户的 macOS 原生桌宠 App。本地桌宠会提示 Agent 正在工作、等待你处理或已经完成；存在已校验路由时，还可以从消息气泡回到相关会话。

## 核心亮点

- **开箱即用**：内置 `星雾团子`、`Bytebud 字节芽` 和 `桃蕾`，均包含完整的制作动画。
- **AI 宠物制作**：通过 Codex 创建或修改标清 192×208、标准 384×416 宠物；可移植 V3 格式还支持由外部高分辨率流程制作的高清 576×624 宠物包。
- **多 Agent 会话**：支持 Codex、Claude Code、Pi Coding Agent 和 OpenCode 的跨项目会话。气泡可以按 Agent 聚合，也可以显示为稳定的跨 Agent 会话卡列表，不会因每次思考或工具事件频繁重排。
- **原生桌面体验**：桌宠、菜单和液态玻璃会话气泡作为一个悬浮组合移动；桌宠尺寸、气泡字号、提醒行为和聚合方式统一在“宠物配置”中调整。
- **本地优先**：宠物、设置、有界会话上下文与诊断信息留在 Mac 上，只有明确导出时才生成外部文件；App 不读取 Agent 凭据、Token、Cookie 或 API Key。

## 产品入口

控制中心包含五个页面：宠物库、AI 宠物制作、宠物配置、Agent 连接、服务与诊断。首次启动使用可恢复的三幕设置流程，不会增加第六个导航页面。

关闭控制中心后，桌宠仍可继续运行。点击桌宠可展开或收起气泡，拖动会移动整个悬浮组合，点击具体会话行才会打开已校验的目标。内置宠物是只读资源；自定义和导入宠物按 V3 能力在宠物库中管理。

## 安装正式版本

1. 打开 [GitHub Releases](https://github.com/xjxtree/agent-pet-companion/releases)。
2. 下载适合 Mac 的 ZIP（Apple 芯片选择 `macos-arm64`，Intel 选择 `macos-x86_64`）以及同版本的 `SHA256SUMS.txt`。
3. 校验 ZIP，例如：

   ```bash
   grep 'macos-arm64.zip' AgentPetCompanion-*-SHA256SUMS.txt | shasum -a 256 -c -
   ```

4. 解压并将 App 移入 `/Applications`。
5. 首次启动时，在 Finder 中按住 Control 点击或右键选择**打开**；也可以前往**系统设置 → 隐私与安全性 → 仍要打开**。

正式归档采用 ad-hoc 签名，没有 Developer ID 签名或 Apple 公证，因此 macOS 会要求上述首次打开确认。安装不需要源码工具链，也不需要关闭 Gatekeeper 或通过命令行移除 quarantine。

App 会在健康启动后检查 latest stable GitHub Release，每 24 小时至多一次。它只提示可用更新，不会自动下载或安装；请校验新 ZIP、退出旧版、替换 `/Applications` 中的 App，再打开新版。

## 从源码构建

需要 macOS 14+、包含 Swift 6 与 macOS SDK 的 Apple Command Line Tools、`rust-toolchain.toml` 固定的 Rust 工具链，以及 Python 3。完整 Xcode 可选。

```bash
git clone https://github.com/xjxtree/agent-pet-companion.git
cd agent-pet-companion
./script/build_app_bundle.sh
```

开发 App 会写入 `dist/`。开发过程中需要重新构建、启动并核对 App/PetCore 构建身份时使用：

```bash
./script/build_and_run.sh --run
```

## 架构与文档

SwiftUI/AppKit App 负责控制中心、菜单栏、悬浮层与渲染；Rust PetCore 是宠物、设置、归一化 Agent 事件、连接器、制作任务和诊断的状态权威。两者通过本地 JSON-RPC 通信，受管 Agent 集成通过 `petcore-cli` 或令牌保护的本地入口提交有界事件。

- [文档索引](docs/README.md)
- [`.petpack` V3 规范](docs/specifications/AgentPetCompanion_Petpack_Whitepaper_V3.md)
- [参与贡献](CONTRIBUTING.md)
- [版本变更记录](CHANGELOG.md)

## License

Agent Pet Companion 使用 [MIT License](LICENSE)。
