# Agent Pet Companion

Language: [中文](#中文) | [English](#english)

## 中文

[Switch to English](#english)

Agent Pet Companion 是一款规划中的 macOS 原生高画质桌宠 App。它让用户通过 AI 生成个性化桌宠，并让桌宠响应 Codex、Claude Code、Pi Coding Agent 和 OpenCode 的工作状态。

当前仓库处于初始化阶段，已收录产品设计、技术方案和阶段任务规划。应用代码会按规划逐步落地。

### 产品方向

- 通过「宠物 Studio」创建高自由度 AI 桌宠。
- 在桌面显示高画质、可拖拽、可缩放的悬浮桌宠。
- 让桌宠响应 Agent 的开始处理、执行工具、等待确认、待查看、完成和失败等事件。
- 在 App 内完成宠物制作、宠物库管理、启用行为配置和 Agent 连接检查。

### V1 范围

- macOS 原生 App：SwiftUI + AppKit + Metal-backed renderer。
- 本地 PetCore：Rust daemon、Unix Domain Socket JSON-RPC、SQLite。
- 自研 `.petpack` 宠物资源格式。
- AI 生成流程：Codex App Server + 内置 Pet Studio Skill。
- 多 Agent 响应：Codex、Claude Code、Pi Coding Agent、OpenCode。

V1 暂不包含公共素材库、宠物分享、Petdex 导入、Windows UI、云端账号或完整任务管理平台。

### 设计文档

- [产品设计方案 V5](docs/design/product-plan-v5/AgentPetCompanion_ProductPlan_V5.md)
- [技术方案 V1.1](docs/design/AgentPetCompanion_TechnicalPlan_V1_1.md)
- [落地任务规划 V2](docs/design/AgentPetCompanion_ImplementationPlan_V2.md)
- [产品设计 HTML 与视觉资产](docs/design/product-plan-v5/)

### 规划中的目录结构

```text
agent-pet-companion/
  apps/macos/
  crates/
    petcore/
    petcore-cli/
    petcore-types/
  plugins/
    codex/
    claude-code/
    pi/
    opencode/
  skills/agent-pet-studio/
  schemas/
  docs/
```

### 开发状态

M0 会先验证工程骨架、macOS 悬浮窗、Swift 到 Rust 的本地通信、Metal 透明帧渲染，以及 Codex App Server 基础链路。后续阶段请以任务规划文档为准。

## English

[切换到中文](#中文)

Agent Pet Companion is a planned native macOS desktop pet app. It helps users generate personalized high-quality desktop pets with AI, then lets those pets react to the work states of Codex, Claude Code, Pi Coding Agent, and OpenCode.

This repository is currently in its initialization stage. Product design, technical design, and phased implementation planning documents have been imported. Application code will be added progressively.

### Product Direction

- Create highly customizable AI pets in Pet Studio.
- Show a high-quality draggable and resizable desktop pet overlay.
- React to agent events such as start, tool execution, waiting for confirmation, review needed, done, and failed.
- Manage pet creation, local pet library, behavior settings, and agent connection checks inside the app.

### V1 Scope

- Native macOS app: SwiftUI + AppKit + Metal-backed renderer.
- Local PetCore: Rust daemon, Unix Domain Socket JSON-RPC, SQLite.
- Custom `.petpack` pet asset format.
- AI generation flow: Codex App Server + built-in Pet Studio Skill.
- Multi-agent response: Codex, Claude Code, Pi Coding Agent, OpenCode.

V1 does not include a public asset gallery, pet sharing, Petdex import, Windows UI, cloud accounts, or a full agent task management platform.

### Design Documents

- [Product Plan V5](docs/design/product-plan-v5/AgentPetCompanion_ProductPlan_V5.md)
- [Technical Plan V1.1](docs/design/AgentPetCompanion_TechnicalPlan_V1_1.md)
- [Implementation Plan V2](docs/design/AgentPetCompanion_ImplementationPlan_V2.md)
- [Product HTML and visual assets](docs/design/product-plan-v5/)

### Planned Repository Layout

```text
agent-pet-companion/
  apps/macos/
  crates/
    petcore/
    petcore-cli/
    petcore-types/
  plugins/
    codex/
    claude-code/
    pi/
    opencode/
  skills/agent-pet-studio/
  schemas/
  docs/
```

### Development Status

M0 will first validate the repository skeleton, macOS overlay window, local Swift-to-Rust communication, Metal transparent frame rendering, and the basic Codex App Server path. Later work should follow the implementation planning document.
