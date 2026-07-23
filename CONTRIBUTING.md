# Contributing to Agent Pet Companion / 参与贡献

Thanks for helping improve Agent Pet Companion. The project is a local-first macOS V1; keep changes aligned with the current product surface, implementation contracts, and tests.

感谢你参与 Agent Pet Companion。项目当前聚焦本地优先的 macOS V1；提交改动应与当前产品入口、实现契约和测试保持一致。

## Prerequisites / 开发环境

- macOS 14 or newer / macOS 14 或更高版本
- Xcode 16 or newer with Swift 6 / Xcode 16 或更高版本，包含 Swift 6
- Rust 1.96.0 with `rustfmt` and `clippy` (pinned by `rust-toolchain.toml`)
- Python 3 for validation helpers

The primary V1 performance target is Apple silicon. Release builds must also compile and validate an `x86_64` slice before they are described as universal.

V1 的主要性能目标是 Apple Silicon。发布构建只有在同时编译并验证 `x86_64` slice 后，才能称为 universal。

## Before changing behavior / 修改行为前

Start with [AGENTS.md](AGENTS.md), then inspect the implementation, schemas, manifests, and tests in the area being changed. Use the [documentation index](docs/README.md) to find the durable architecture, data, integration, `.petpack`, validation, or release contract that applies. The repository does not use a rolling status document; verification claims must come from a fresh run for the exact commit or artifact.

修改前先阅读 [AGENTS.md](AGENTS.md)，再检查相关实现、schema、manifest 和测试；通过[文档索引](docs/README.md)找到对应的架构、数据、集成、`.petpack`、验证或发布契约。仓库不维护滚动状态文档；验收结论必须来自对当前 commit 或产物的实际运行。

Do not add cloud accounts, public galleries, sharing/community features, Petdex import, Codex built-in pet export, Windows UI, or a mission-control platform unless the project scope is explicitly changed.

除非项目范围被明确调整，否则不要加入云账号、公共素材库、分享/社区、Petdex 导入、Codex 内置宠物导出、Windows UI 或完整 Agent 任务控制台。

## Development workflow / 开发流程

Create a focused task branch. When working through Codex in this repository, use the `xjx-` prefix. Add the smallest useful regression test for behavior changes.

为任务创建聚焦的分支；通过 Codex 开发时使用 `xjx-` 前缀。行为变更应补充最小有效回归测试。

The default validation gate is deliberately host-safe: it uses isolated temporary homes and does not launch the GUI, modify LaunchAgents, invoke real agents, or read credentials.

默认验证门禁必须对宿主安全：使用隔离临时目录，不启动 GUI、不修改 LaunchAgent、不调用真实 Agent，也不读取凭据。

```bash
APC_VALIDATE_HOST_UI=0 \
APC_VALIDATE_OVERLAY_INTERACTION=0 \
APC_VALIDATE_REAL_AGENT_CONNECTORS=0 \
APC_VALIDATE_REAL_APP_SERVER=0 \
./script/test_all.sh
```

Real UI, real connector, and real App Server checks are separate opt-in gates. Use only the documented environment flags and never inspect auth, token, cookie, API key, or secret files.

真实 UI、真实 connector 与真实 App Server 检查均为独立 opt-in 门禁。只能使用文档规定的环境变量，并且不得检查 auth、token、cookie、API Key 或其他密钥文件。

See [Validation profiles](docs/development/validation.md) for the proof boundary of each gate. A skipped environment-dependent gate must be reported as skipped, never as passed.

各门禁的证明边界见[验证层级](docs/development/validation.md)。因环境缺失而跳过的门禁必须明确报告为 skipped，不能写成 passed。

For live macOS UI verification, use Computer Use first and prefer Accessibility reads and element-based actions that do not take over the user's pointer, keyboard, or active focus. Do not default to `open -n`, AppleScript/System Events, CGEvent synthesis, `cliclick`, `pyautogui`, or equivalent direct input automation. If Computer Use cannot cover a required interaction and the fallback can interrupt the user, obtain explicit approval immediately before using it.

真实 macOS UI 验证必须优先使用 Computer Use，并优先采用 Accessibility 状态读取和元素级操作，避免接管用户的鼠标、键盘或当前输入焦点。不得默认使用 `open -n`、AppleScript/System Events、CGEvent、`cliclick`、`pyautogui` 等直接输入自动化；若 Computer Use 无法覆盖且替代方法可能打断用户，必须在执行前取得明确授权。

## Documentation and changelog / 文档与变更记录

- Keep the public READMEs human-facing. Put durable implementation knowledge in the owning `docs/` subdirectory and link to source rather than copying it.
- Do not add rolling status, dated audits, implementation diaries, validation logs, or pending-work documents. Use issues, CI, and GitHub Release notes.
- Add every user-visible change to `[Unreleased]` in [CHANGELOG.md](CHANGELOG.md). A GitHub Release is not complete until its tag and version section match one-to-one.
- Update schemas, runtime manifests, fixtures, Swift/Rust mirrors, tests, and the owning document together when a contract changes.

- README 面向普通用户；长期实现信息进入对应 `docs/` 子目录，并通过链接指向源码。
- 不新增滚动状态、按日期审计、实现过程、验证日志或待办文档；分别使用 issue、CI 与 GitHub Release notes。
- 所有用户可见变化写入 [CHANGELOG.md](CHANGELOG.md) 的 `[Unreleased]`；GitHub Release、tag 与版本段必须一一对应。
- 契约变化时同步 schema、runtime manifest、fixtures、Swift/Rust 镜像、测试与对应文档。

## Pull requests / 合并请求

Include:

- what changed and which V1 requirement it satisfies;
- tests run and any environment-gated checks not run;
- migration, privacy, performance, or accessibility impact;
- before/after captures for visible UI changes at the same viewport and state.

请说明：改动内容及对应 V1 需求、已运行的测试及未运行的环境门禁、迁移/隐私/性能/无障碍影响；可见 UI 改动还需提供同一视口和状态下的前后对比。

Do not commit `target/`, `.build/`, `DerivedData/`, `.env` files, generated jobs, `.petpack` files, Python caches, credentials, or temporary pet assets.

不要提交 `target/`、`.build/`、`DerivedData/`、`.env`、生成任务、`.petpack`、Python cache、凭据或临时宠物素材。
