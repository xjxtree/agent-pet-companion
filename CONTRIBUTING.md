# Contributing / 参与贡献

Agent Pet Companion is a local-first native macOS project. Keep changes focused on the current product surface and synchronize behavior, typed contracts, tests, and the owning document. / 本项目是本地优先的 macOS 原生应用。改动应聚焦当前产品范围，并同步行为、类型契约、测试与负责该主题的文档。

## Prerequisites / 开发环境

- macOS 14+
- Apple Command Line Tools with Swift 6 and a macOS SDK; full Xcode is optional / 包含 Swift 6 与 macOS SDK 的 Apple Command Line Tools；完整 Xcode 可选
- Rust toolchain pinned by `rust-toolchain.toml`, including `rustfmt` and `clippy`
- Python 3; release visual validation also uses the pinned Pillow dependency / Python 3；发布视觉校验还会使用固定版本的 Pillow

## Workflow / 开发流程

1. Read [AGENTS.md](AGENTS.md), then inspect the implementation, schemas, manifests, tests, and the owning document listed in [docs/README.md](docs/README.md). / 先阅读 `AGENTS.md`，再检查相关实现、schema、manifest、测试和负责该主题的文档。
2. Use a focused branch (`xjx-` prefix for Codex work) and preserve unrelated worktree changes. / 使用聚焦分支；Codex 分支使用 `xjx-` 前缀，并保留工作区中无关改动。
3. Add the smallest useful regression test and update the owning contract when behavior changes. / 行为变化时补充最小有效回归测试，并更新对应契约。
4. Record user-visible changes under `[Unreleased]` in [CHANGELOG.md](CHANGELOG.md). / 用户可见变化写入 `CHANGELOG.md` 的 `[Unreleased]`。

## Validation / 验证

The default gate is isolated and does not launch the GUI, modify user LaunchAgents, invoke real Agents, or read credentials:

```bash
APC_VALIDATE_HOST_UI=0 \
APC_VALIDATE_REAL_AGENT_CONNECTORS=0 \
APC_VALIDATE_REAL_APP_SERVER=0 \
./script/test_all.sh
```

Run the smallest relevant check first, then the broader gate appropriate to the change. Real UI, connector, App Server, performance, and release checks are environment-dependent; report an unrun gate as skipped, never passed. [Validation profiles](docs/development/validation.md) define proof boundaries, and [macOS release](docs/release/macos-release.md) owns official distribution steps. / 先运行最小相关检查，再运行与改动相称的完整门禁。真实 UI、连接器、App Server、性能和发布检查依赖环境；未运行只能标记为 skipped。证明边界与正式发布步骤分别见对应文档。

Computer Use is recommended for live macOS UI work when available and useful, but the executing Agent may choose another suitable method. Launch verification builds through `script/build_and_run.sh`, scope host-affecting checks to the intended App or an owned validation runtime, and state what was directly observed. / Computer Use 在可用且适合任务时建议使用；执行 Agent 也可选择其他合适方法。验证构建通过 `script/build_and_run.sh` 启动，影响宿主的检查应限定在目标 App 或自有验证实例，并说明哪些行为经过直接观察。

## Pull requests / 合并请求

Include: what changed, tests run, skipped environment gates, and any migration, privacy, performance, or accessibility impact. Add comparable before/after captures for visible UI changes. / 请说明改动、已运行测试、跳过的环境门禁，以及迁移、隐私、性能或无障碍影响；可见 UI 改动附同条件前后对比。

Do not commit build caches or output, `.env` files, credentials, generated jobs, exported diagnostics, `.petpack` files, or temporary pet assets. Plans, progress logs, audits, and command output belong in issues, commits, PRs, CI, or Release notes rather than durable documentation. / 不要提交构建缓存或产物、`.env`、凭据、生成任务、导出诊断、`.petpack` 或临时宠物素材。计划、进度、审计和命令输出不进入长期文档。
