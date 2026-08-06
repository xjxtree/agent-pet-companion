# Project Documentation / 项目文档

`README.md` and `README.zh-CN.md` are the product entrypoints. This directory contains the durable technical contracts used by maintainers and Agents. / 根目录 README 面向用户；本目录只保存维护者与 Agent 需要长期维护的技术契约。

## Source order / 信息优先级

1. Current user request / 当前用户要求
2. Implementation, typed schemas, manifests, and tests / 实现、类型化 schema、manifest 与测试
3. The owning document below / 下表中负责该主题的文档
4. Public README / 面向用户的 README

When prose disagrees with code, investigate the implementation and update the single owning document. / 文档与实现冲突时，应核对实现并更新唯一负责该主题的文档。

## Documents / 文档

| Document / 文档 | Owns / 负责内容 |
|---|---|
| [System architecture](architecture/overview.md) | Components, ownership, product boundaries, and main flows / 组件、所有权、产品边界与主流程 |
| [Runtime and IPC](architecture/runtime-and-ipc.md) | Processes, startup, replacement, transport, updates, and diagnostics / 进程、启动、替换、通信、更新与诊断 |
| [Data model](architecture/data-model.md) | Storage, typed projections, identity, revisions, retention, and versioned contracts / 存储、类型化投影、身份、revision、保留与版本契约 |
| [Agent connectors](integrations/agent-connectors.md) | Host adapters, event mapping, routing, managed operations, and privacy / Agent 适配、事件映射、路由、受管操作与隐私 |
| [`.petpack` V3](specifications/AgentPetCompanion_Petpack_Whitepaper_V3.md) | Portable package format and producer conformance / 可移植宠物包格式与制作合规要求 |
| [Validation profiles](development/validation.md) | What each validation layer proves / 各验证层能够证明什么 |
| [macOS release](release/macos-release.md) | Official GitHub Release procedure and installation contract / 正式 GitHub Release 流程与安装合同 |
| [CHANGELOG](../CHANGELOG.md) | Versioned user-visible changes / 按版本记录的用户可见变化 |

## Maintenance / 维护

- Keep one durable document per topic; link to code or schemas instead of copying them. / 每个主题只保留一份长期文档，优先链接源码或 schema。
- Describe current behavior and invariants only. Plans, audits, progress logs, screenshots, and command output belong in issues, commits, PRs, CI, or Release notes. / 只描述当前行为与不变量；计划、审计、进度、截图和命令输出进入 issue、commit、PR、CI 或 Release notes。
- Put user-visible changes in `[Unreleased]`; do not commit diagnostics, user data, credentials, build output, or temporary assets as documentation. / 用户可见变化写入 `[Unreleased]`；不要把诊断、用户数据、凭据、构建产物或临时素材作为文档提交。
