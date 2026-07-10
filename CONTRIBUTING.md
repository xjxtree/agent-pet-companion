# Contributing to Agent Pet Companion / 参与贡献

Thanks for helping improve Agent Pet Companion. The project is a local-first macOS V1; please keep changes inside the scope documented in the product and technical plans.

感谢你参与 Agent Pet Companion。项目当前聚焦本地优先的 macOS V1；提交改动前，请遵循产品方案与技术方案中已经冻结的范围。

## Prerequisites / 开发环境

- macOS 14 or newer / macOS 14 或更高版本
- Xcode 16 or newer with Swift 6 / Xcode 16 或更高版本，包含 Swift 6
- Rust 1.96.0 with `rustfmt` and `clippy` (pinned by `rust-toolchain.toml`)
- Python 3 for validation helpers

The primary V1 performance target is Apple silicon. Release builds must also compile and validate an `x86_64` slice before they are described as universal.

V1 的主要性能目标是 Apple Silicon。发布构建只有在同时编译并验证 `x86_64` slice 后，才能称为 universal。

## Before changing behavior / 修改行为前

Read these sources of truth:

- [Product plan V5](docs/design/product-plan-v5/AgentPetCompanion_ProductPlan_V5.md)
- [Technical plan V1.1](docs/design/AgentPetCompanion_TechnicalPlan_V1_1.md)
- [Design index](docs/design/README.md)

Do not add cloud accounts, public galleries, sharing/community features, Petdex import, Codex built-in pet export, Windows UI, or a mission-control platform unless the project scope is explicitly changed.

除非项目范围被明确调整，否则不要加入云账号、公共素材库、分享/社区、Petdex 导入、Codex 内置宠物导出、Windows UI 或完整 Agent 任务控制台。

## Development workflow / 开发流程

Create a branch with the `codex/` prefix when working through Codex, keep changes focused, and add the smallest useful regression test.

通过 Codex 开发时使用 `codex/` 分支前缀；保持改动聚焦，并为行为变更补充最小有效回归测试。

The default validation gate is deliberately host-safe: it uses isolated temporary homes and does not launch the GUI, modify LaunchAgents, invoke real agents, or read credentials.

默认验证门禁必须对宿主安全：使用隔离临时目录，不启动 GUI、不修改 LaunchAgent、不调用真实 Agent，也不读取凭据。

```bash
./script/validate_test_isolation.sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace --locked
(cd apps/macos && swift test)
./script/validate_schema_fixtures.sh
./script/build_app_bundle.sh
./script/validate_app_bundle.sh
```

Real UI, real connector, and real App Server checks are separate opt-in gates. Use only the documented environment flags and never inspect auth, token, cookie, API key, or secret files.

真实 UI、真实 connector 与真实 App Server 检查均为独立 opt-in 门禁。只能使用文档规定的环境变量，并且不得检查 auth、token、cookie、API Key 或其他密钥文件。

## Pull requests / 合并请求

Include:

- what changed and which V1 requirement it satisfies;
- tests run and any environment-gated checks not run;
- migration, privacy, performance, or accessibility impact;
- before/after captures for visible UI changes at the same viewport and state.

请说明：改动内容及对应 V1 需求、已运行的测试及未运行的环境门禁、迁移/隐私/性能/无障碍影响；可见 UI 改动还需提供同一视口和状态下的前后对比。

Do not commit `target/`, `.build/`, `DerivedData/`, `.env` files, generated jobs, `.petpack` files, Python caches, credentials, or temporary pet assets.

不要提交 `target/`、`.build/`、`DerivedData/`、`.env`、生成任务、`.petpack`、Python cache、凭据或临时宠物素材。
