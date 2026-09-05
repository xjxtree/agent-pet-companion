# Contributing / 参与贡献

Agent Pet Companion is a local-first native macOS project. Keep changes focused on the current product surface and synchronize behavior, typed contracts, tests, and the owning document. / 本项目是本地优先的 macOS 原生应用。改动应聚焦当前产品范围，并同步行为、类型契约、测试与负责该主题的文档。

## Prerequisites / 开发环境

- macOS 14+
- Apple Command Line Tools with Swift 6 and a macOS SDK; full Xcode is optional / 包含 Swift 6 与 macOS SDK 的 Apple Command Line Tools；完整 Xcode 可选
- Rust toolchain pinned by `rust-toolchain.toml`, including `rustfmt` and `clippy`
- Python 3; release visual validation also uses the pinned Pillow dependency / Python 3；发布视觉校验还会使用固定版本的 Pillow

Codex repository work uses the versioned [project configuration](.codex/config.toml) and [Agent instructions](AGENTS.md). See [Codex project defaults](docs/development/parallel-development.md#codex-project-defaults--codex-项目默认设置) for model selection, inherited reasoning effort, and the separate in-App Studio setting. / Codex 仓库开发使用受版本管理的项目配置与 Agent 指令；模型选择、继承的推理强度及独立的 App 内 Studio 设置见上述说明。

## Workflow / 开发流程

1. Read [AGENTS.md](AGENTS.md), then inspect the touched implementation, schemas, manifests, tests, and the relevant owning document in [docs/README.md](docs/README.md). / 先读 Agent 指令，再核对受影响的实现、类型契约、测试与对应文档。
2. Before editing, follow [Parallel development](docs/development/parallel-development.md) to choose the direct/train lane, create an independent branch/worktree, and register the domain claim and any shared-path authorization. Keep local `main` read-only and preserve unrelated work. / 修改前按开发流程选择通道、创建独立分支与 worktree、登记领域及共享路径授权；本地 `main` 只读，保留无关工作。
3. Validate changed behavior with the smallest useful existing checks. Add regression coverage when it protects a real behavior or failure boundary; documentation and model-default edits need contract validation rather than tests that repeat configuration values. Complete the required gates without unnecessarily repeating successful work. / 优先使用最小有效的现有检查；仅为实际行为或故障边界补充回归测试，文档和模型默认值修改不添加复述配置值的测试；完成必需门禁，避免无必要重复。
4. Add the [unreleased change fragment](changes/unreleased/README.md), then complete the development workflow's commit, PR, and post-merge audit checklists. / 添加未发布变更片段，再完成开发流程中的提交、PR 与合并后审计清单。

## Validation / 验证

The default local gate is intentionally fast and does not launch the GUI, modify user LaunchAgents, invoke real Agents, or read credentials:

```bash
./script/validate_pre_push.sh --plan-only
./script/validate_pre_push.sh
```

GitHub CI is authoritative for complete Rust and Swift tests, simulated integrations, App assembly, stress, and release source proof. Use `test_all.sh --resume` locally only to reproduce or diagnose a remote failure. Real UI, connector, and App Server checks remain environment-dependent; report an unrun gate as skipped, never passed. [Validation profiles](docs/development/validation.md) define proof boundaries, and [macOS release](docs/release/macos-release.md) owns official distribution steps. / GitHub CI 权威负责全量 Rust/Swift 测试、模拟集成、App 组装、压力与发布源码证明；本地仅在复现或排查远端失败时使用 `test_all.sh --resume`。真实 UI、连接器和 App Server 检查仍依赖环境，未运行只能标记为 skipped。证明边界与正式发布步骤分别见对应文档。

Computer Use is recommended for live macOS UI work when available and useful, but the executing Agent may choose another suitable method. Launch verification builds through `script/build_and_run.sh`, scope host-affecting checks to the intended App or an owned validation runtime, and state what was directly observed. / Computer Use 在可用且适合任务时建议使用；执行 Agent 也可选择其他合适方法。验证构建通过 `script/build_and_run.sh` 启动，影响宿主的检查应限定在目标 App 或自有验证实例，并说明哪些行为经过直接观察。

## Pull requests / 合并请求

Include: what changed, tests run, skipped environment gates, and any migration, privacy, performance, or accessibility impact. Add comparable before/after captures for visible UI changes. / 请说明改动、已运行测试、跳过的环境门禁，以及迁移、隐私、性能或无障碍影响；可见 UI 改动附同条件前后对比。

[Parallel development](docs/development/parallel-development.md#pr-lifecycle-and-ci--pr-生命周期与-ci) owns ready/draft behavior, required CI, squash auto-merge eligibility, control-plane exclusions, and post-merge delivery. / PR 的 ready/draft 状态、必需 CI、squash 自动合并条件、控制面例外与合并后交付以开发流程为准。

Do not commit build caches or output, `.env` files, credentials, generated jobs, exported diagnostics, `.petpack` files, or temporary pet assets. Plans, progress logs, audits, and command output belong in issues, commits, PRs, CI, or Release notes rather than durable documentation. / 不要提交构建缓存或产物、`.env`、凭据、生成任务、导出诊断、`.petpack` 或临时宠物素材。计划、进度、审计和命令输出不进入长期文档。
