# Contributing / 参与贡献

Agent Pet Companion is a local-first native macOS project. Keep changes focused on the current product surface and synchronize behavior, typed contracts, tests, and the owning document. / 本项目是本地优先的 macOS 原生应用。改动应聚焦当前产品范围，并同步行为、类型契约、测试与负责该主题的文档。

## Prerequisites / 开发环境

- macOS 14+
- Apple Command Line Tools with Swift 6 and a macOS SDK; full Xcode is optional / 包含 Swift 6 与 macOS SDK 的 Apple Command Line Tools；完整 Xcode 可选
- Rust toolchain pinned by `rust-toolchain.toml`, including `rustfmt` and `clippy`
- Python 3; release visual validation also uses the pinned Pillow dependency / Python 3；发布视觉校验还会使用固定版本的 Pillow

## Workflow / 开发流程

1. Read [AGENTS.md](AGENTS.md), then inspect the implementation, schemas, manifests, tests, and the owning document listed in [docs/README.md](docs/README.md). / 先阅读 `AGENTS.md`，再检查相关实现、schema、manifest、测试和负责该主题的文档。
2. Keep local `main` read-only. The Agent chooses a direct `gd-ops/task/*` or `gd-ops/fix/*` PR to `main` for hotfix/small isolated work, or joins the main Agent's shared `gd-ops/train/*` for parallel/cross-component work. / 本地 `main` 只读；热修复或小型独立任务直接 PR 至 `main`，并行或跨组件任务加入主 Agent 的共享 train。
3. Give each Agent/session an independent branch and worktree, preserve unrelated changes, and hand sub-Agent work to the train only through task PRs. / 每个 Agent/会话使用独立分支与 worktree，保留无关改动，并仅通过任务 PR 将子 Agent 工作交给 train。
4. Add the smallest useful regression test and update the owning contract when behavior changes. / 行为变化时补充最小有效回归测试，并更新对应契约。
5. Direct PRs update `[Unreleased]`; train task PRs add `changes/unreleased/*.json`, which the coordinator consumes before the final train PR becomes ready. / direct PR 更新 `[Unreleased]`；train 任务 PR 写入变更片段，最终 train PR ready 前由协调者汇总。

The complete branch, worktree, ownership, auto-merge, and coordinator commands are defined in [Parallel development](docs/development/parallel-development.md). / 完整分支、worktree、所有权、自动合并与协调命令见并行开发文档。

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

Ready PRs from repository-owned `gd-ops/*` branches enroll in squash auto-merge only after the base branch exposes active PR and `Required CI` rules. Every ready PR to `main` runs the complete gate; train task PRs run scoped CI, and the exact merged `main` commit produces the Release source proof. / 仓库内 `gd-ops/*` 的 ready PR 仅在目标分支已启用 PR 与 `Required CI` 规则后进入 squash 自动合并。所有面向 `main` 的 ready PR 均运行完整门禁；train 任务 PR 运行范围化 CI，精确的已合并 `main` commit 生成 Release 源码证明。

Do not commit build caches or output, `.env` files, credentials, generated jobs, exported diagnostics, `.petpack` files, or temporary pet assets. Plans, progress logs, audits, and command output belong in issues, commits, PRs, CI, or Release notes rather than durable documentation. / 不要提交构建缓存或产物、`.env`、凭据、生成任务、导出诊断、`.petpack` 或临时宠物素材。计划、进度、审计和命令输出不进入长期文档。
