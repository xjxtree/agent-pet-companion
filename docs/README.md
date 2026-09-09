# Project Documentation / 项目文档

`README.md` and `README.zh-CN.md` are the product entrypoints. This directory contains the durable technical contracts used by maintainers and Agents. / 根目录 README 面向用户；本目录只保存维护者与 Agent 需要长期维护的技术契约。

## Evidence and intended behavior / 证据与预期行为

- Establish intended behavior from the current user request and the effective product, interface, format, and release contracts in the owning documents below. Preserve explicit scope changes. / 根据当前用户要求和下列所属文档中的有效产品、接口、格式及发布契约确认预期行为，保留明确的范围变更。
- Establish current behavior from the touched implementation, typed schemas, manifests, tests, and runtime evidence. Passing tests support the cases they cover; they do not by themselves define the requirement or prove it is met in every case. / 根据相关实现、类型化 schema、manifest、测试和运行证据确认当前行为；测试通过支持其覆盖的情形，不能独立定义需求或证明所有情形符合需求。
- Use the public README for the supported user-facing surface and keep it consistent with the owning contracts. / 用公开 README 确认支持的用户功能，并与所属契约保持一致。

When evidence and a contract disagree, determine whether the implementation is defective, the document is stale, or a requirement is unresolved. Correct the responsible source and its affected references; do not rewrite a requirement merely to match current code, or describe planned behavior as implemented. Ask only when the unresolved requirement would materially change the result. / 证据与契约冲突时，核实是实现缺陷、文档过时还是需求未定，再修正负责来源及受影响的引用；不为迁就代码而改写需求，也不把计划写成已实现。仅在未定需求会实质改变结果时澄清。

## Documents / 文档

| Document / 文档 | Owns / 负责内容 |
|---|---|
| [System architecture](architecture/overview.md) | Components, ownership, product boundaries, and main flows / 组件、所有权、产品边界与主流程 |
| [Runtime and IPC](architecture/runtime-and-ipc.md) | Processes, startup, replacement, transport, updates, and diagnostics / 进程、启动、替换、通信、更新与诊断 |
| [Data model](architecture/data-model.md) | Storage, typed projections, identity, revisions, retention, and versioned contracts / 存储、类型化投影、身份、revision、保留与版本契约 |
| [Agent connectors](integrations/agent-connectors.md) | Host adapters, event mapping, routing, managed operations, and privacy / Agent 适配、事件映射、路由、受管操作与隐私 |
| [`.petpack` V3](specifications/AgentPetCompanion_Petpack_Whitepaper_V3.md) | Portable package format and producer conformance / 可移植宠物包格式与制作合规要求 |
| [Validation profiles](development/validation.md) | What each validation layer proves / 各验证层能够证明什么 |
| [Parallel development](development/parallel-development.md) | Codex project defaults, direct/train PR lanes, Agent ownership, auto-merge, and protected delivery / Codex 项目默认设置、direct/train PR 通道、Agent 所有权、自动合并与受保护交付 |
| [macOS release](release/macos-release.md) | Official GitHub Release procedure and installation contract / 正式 GitHub Release 流程与安装合同 |
| [Unreleased fragments](../changes/unreleased/README.md) | Development change records before release preparation / 发布准备前的开发变更记录 |
| [CHANGELOG](../CHANGELOG.md) | Versioned release entries / 按版本整理的发布记录 |

## Maintenance / 维护

- Keep one durable document per topic; link to code or schemas instead of copying them. / 每个主题只保留一份长期文档，优先链接源码或 schema。
- Describe current behavior and invariants only. Plans, audits, progress logs, screenshots, and command output belong in issues, commits, PRs, CI, or Release notes. / 只描述当前行为与不变量；计划、审计、进度、截图和命令输出进入 issue、commit、PR、CI 或 Release notes。
- Record user-visible development changes as [unreleased fragments](../changes/unreleased/README.md); only release preparation updates root `CHANGELOG.md`. Do not commit diagnostics, user data, credentials, build output, or temporary assets as documentation. / 用户可见的开发变更写入未发布片段，仅发布准备更新根 `CHANGELOG.md`；不要把诊断、用户数据、凭据、构建产物或临时素材作为文档提交。
