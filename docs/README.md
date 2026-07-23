# Project Documentation / 项目文档

`README.md` and `README.zh-CN.md` are the human-facing product entrypoints. This directory contains the target product experience, its dependency-ordered implementation tasks, and durable current-state knowledge for maintainers and AI agents: architecture, data contracts, integration boundaries, validation semantics, specifications, and release operations.

`README.md` 与 `README.zh-CN.md` 面向普通用户；本目录保存目标产品体验、按依赖排序的实施任务，以及供维护者与 AI Agent 使用的当前架构、数据契约、集成边界、验证语义、格式规范和发布操作。

## Source order / 信息优先级

When sources disagree, use this order:

1. the current user request;
2. implementation, typed schemas, runtime manifests, and tests in the changed area;
3. the product experience contract and ordered refactor task when implementing the approved redesign;
4. the durable current-state document that owns the contract;
5. the public README for user-facing behavior.

发现冲突时，以当前用户要求为最高优先级，其次是相关代码、类型化 schema、runtime manifest 与测试；执行已批准的产品重构时再遵循产品体验合同与任务顺序，随后是负责当前契约的长期文档，最后才是面向用户的 README。修复冲突时同步更新唯一的长期入口，不要新增“当前状态”副本。

## Navigation / 导航

| Area / 目录 | Document / 文档 | Purpose / 用途 |
|---|---|---|
| Product | [Product experience contract](product/experience-contract.md) | Target product promise, information hierarchy, page contracts, overlay, accessibility, and distribution acceptance / 目标产品承诺、信息层级、页面合同、桌宠、无障碍与分发验收 |
| Architecture | [System overview](architecture/overview.md) | Components, ownership, main flows, and repository map / 组件、所有权、主流程与仓库结构 |
| Architecture | [Runtime and IPC](architecture/runtime-and-ipc.md) | Processes, startup/update lifecycle, transports, RPC, and diagnostics / 进程、启动与更新、传输、RPC 和诊断 |
| Architecture | [Data model](architecture/data-model.md) | SQLite, file-backed revisions, typed contracts, retention, and invariants / SQLite、文件 revision、类型契约、保留与不变量 |
| Integrations | [Agent connectors](integrations/agent-connectors.md) | Codex, Claude Code, Pi, and OpenCode event boundaries / 四类 Agent 的连接与事件边界 |
| Specifications | [`.petpack` V1](specifications/AgentPetCompanion_Petpack_Whitepaper_V1.md) | Portable pet package and producer contract / 可移植宠物包与生产者契约 |
| Development | [Product refactor execution](development/product-refactor-execution.md) | Dependency-ordered implementation tasks and acceptance contracts, without schedule or status / 无排期、无状态的依赖顺序实施任务与验收合同 |
| Development | [Validation profiles](development/validation.md) | What each gate proves and when it may run / 各门禁的证明范围与运行条件 |
| Release | [macOS release procedure](release/macos-release.md) | Versioning, architecture-specific packaging, checksums, and functional acceptance / 版本、分架构打包、校验和与功能验收 |
| Repository root | [CHANGELOG](../CHANGELOG.md) | One versioned user-visible change record per GitHub Release / 每个 GitHub Release 对应的版本变更记录 |

## Maintenance rules / 维护规则

- Keep one durable document per topic and link to source instead of copying large code or schema blocks.
- Keep exactly one target product contract and one ordered refactor task document while the approved refactor is active. They contain no schedule, milestone, status, percentage, or validation history.
- All other documents describe current behavior and invariants. Do not add roadmaps, rolling status, dated audits, screenshots used as evidence, implementation diaries, duplicate pending-work lists, or test logs.
- Put task execution state in issues, commits, pull requests, and CI. Put commit/build evidence in CI artifacts and the matching GitHub Release notes.
- Record every user-visible change under `[Unreleased]` in the root [CHANGELOG](../CHANGELOG.md); each published release converts it into one version section.
- Never commit exported diagnostics, user data, credentials, generated release output, build caches, or temporary pet assets as documentation.

- 每个主题只保留一份长期文档，优先链接源码，不复制大段实现或 schema。
- 已批准的重构期间仅保留一份目标产品合同与一份顺序化实施任务文档；其中不记录排期、里程碑、状态、百分比或验证历史。
- 其他文档只描述当前行为与不变量；不新增路线图、滚动状态、按日期审计、证据截图、实现过程、重复待办或测试日志。
- 任务执行状态进入 issue、commit、PR 与 CI；某次提交或构建的证据进入 CI artifact 与对应 GitHub Release notes。
- 所有用户可见变化先写入根目录 [CHANGELOG](../CHANGELOG.md) 的 `[Unreleased]`，发布时转换为唯一版本段。
- 不得将导出的诊断包、用户数据、凭据、生成的发布产物、构建缓存或临时宠物素材作为文档提交。
