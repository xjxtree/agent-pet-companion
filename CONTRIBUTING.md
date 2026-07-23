# Contributing to Agent Pet Companion / 参与贡献

Thanks for helping improve Agent Pet Companion. The project is a local-first macOS V1; keep changes aligned with the current product surface, implementation contracts, and tests.

感谢你参与 Agent Pet Companion。项目当前聚焦本地优先的 macOS V1；提交改动应与当前产品入口、实现契约和测试保持一致。

## Prerequisites / 开发环境

- macOS 14 or newer / macOS 14 或更高版本
- Apple Command Line Tools with Swift 6 and a macOS SDK; full Xcode is optional / 包含 Swift 6 与 macOS SDK 的 Apple Command Line Tools；完整 Xcode 可选
- Rust 1.96.0 with `rustfmt` and `clippy` (pinned by `rust-toolchain.toml`)
- Python 3 for validation helpers

The primary V1 performance target is Apple silicon. Release tooling has explicit preview and public modes. `--preview` produces clearly labeled, ad-hoc-signed thin `arm64` and `x86_64` archives. `--public --arch all` fails closed and requires externally provisioned signing identity, Team ID, and notary profile. Publication additionally requires native validation on both architectures and exact downloaded-asset revalidation. Missing credentials or runners means unavailable or incomplete, never passed. See the [release procedure](docs/release/macos-release.md) and [validation profiles](docs/development/validation.md).

V1 的主要性能目标是 Apple Silicon。发布工具明确区分 preview 与 public 两种模式：`--preview` 生成清楚标注、采用 ad-hoc 签名的 thin `arm64` 与 `x86_64` 归档；`--public --arch all` 采用 fail-closed 设计，要求外部配置签名身份、Team ID 与公证 profile。正式发布还必须在两种原生架构上完成验证，并重新校验实际下载的发布文件。缺少凭据或 runner 只能记为 unavailable 或 incomplete，不能记为通过。具体见[发布流程](docs/release/macos-release.md)与[验证层级](docs/development/validation.md)。

## Before changing behavior / 修改行为前

Start with [AGENTS.md](AGENTS.md). Product-refactor work also reads the [product experience contract](docs/product/experience-contract.md) and executes the matching task from [product refactor execution](docs/development/product-refactor-execution.md) in dependency order. Then inspect the implementation, schemas, manifests, tests, and current-state owning document in the area being changed. The repository does not use a rolling status document; verification claims must come from a fresh run for the exact commit or artifact.

修改前先阅读 [AGENTS.md](AGENTS.md)。产品重构还必须阅读[产品体验合同](docs/product/experience-contract.md)，并按[产品重构实施任务](docs/development/product-refactor-execution.md)的依赖顺序执行对应任务；随后检查相关实现、schema、manifest、测试和负责当前事实的文档。仓库不维护滚动状态文档；验收结论必须来自对当前 commit 或产物的实际运行。

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
- Keep the approved target design only in `docs/product/experience-contract.md` and its dependency-ordered tasks only in `docs/development/product-refactor-execution.md`.
- Do not add other rolling status, dated audits, implementation diaries, validation logs, or pending-work documents. Do not mark progress in the execution document; use issues, commits, pull requests, CI, and GitHub Release notes.
- Add every user-visible change to `[Unreleased]` in [CHANGELOG.md](CHANGELOG.md). A GitHub Release is not complete until its tag and version section match one-to-one.
- Update schemas, runtime manifests, fixtures, Swift/Rust mirrors, tests, and the owning document together when a contract changes.

- README 面向普通用户；长期实现信息进入对应 `docs/` 子目录，并通过链接指向源码。
- 已批准的目标设计只保存在 `docs/product/experience-contract.md`，其依赖顺序任务只保存在 `docs/development/product-refactor-execution.md`。
- 不新增其他滚动状态、按日期审计、实现过程、验证日志或待办文档，也不在任务文档中标记进度；执行状态使用 issue、commit、PR、CI 与 GitHub Release notes。
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
