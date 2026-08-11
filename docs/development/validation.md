# Validation Profiles / 验证层级

Commands listed here define proof boundaries; they do not prove that a commit passed. Use fresh command output, CI artifacts, or Release evidence for the exact commit and artifact. / 本文只定义证明范围；具体 commit 是否通过必须以新鲜命令输出、CI artifact 或 Release 证据为准。

## Profiles / 层级

| Profile / 层级 | Main entrypoints / 入口 | Proves / 能证明 | Does not prove / 不能证明 |
|---|---|---|---|
| Local fast | `validate_pre_push.sh` | Diff hygiene, source syntax, lightweight contracts, formatting, and compilation of touched Rust/Swift inputs / diff、语法、轻量合同、格式与受影响 Rust/Swift 编译 | Complete tests, App assembly, visible UI, real Agents / 全量测试、App 组装、可见 UI 与真实 Agent |
| CI fast/core | parallel Rust lint/test shards, complete Swift interaction proof, schema/security/overlay validators | Deterministic logic, schemas, Swift models, native overlay interaction contracts, and packaged development App / 确定性逻辑、schema、Swift 模型、悬浮层交互合同与开发版 App | Visible UI, real Agents, real App Server generation / 可见 UI、真实 Agent、真实 App Server 制作 |
| Simulated integration | `validate_portable_pet_maker.sh`, `validate_connectors_runtime.sh` | Isolated package production, QA freshness, connector generation/normalization, library flows / 隔离宠物制作、QA 新鲜度、连接器与宠物库流程 | Artistic quality or a real provider task / 艺术质量或真实服务任务 |
| macOS runtime | `build_and_run.sh --verify`, bundle/overlay/window/renderer/recovery validators | The packaged App/runtime, clean-home bundled pets, persistence, rendering, and exercised recovery / 打包 App、运行时、内置宠物、持久化、渲染与恢复 | Unobserved UI behavior, real provider behavior, full profiling / 未直接观察的 UI、真实服务与完整性能结论 |
| Real connectors | `validate_real_agent_connectors.sh` | Current managed adapters can emit through the local runtime without reading credentials / 当前受管适配器可通过本地运行时发送事件 | Authentication, model execution, complete user task / 认证、模型执行、完整任务 |
| Real App Server | `validate_real_app_server.sh`, optional `soak_ai_pet_maker_six_hours.sh` | Native input, generation/import, PetCore restart, same-job resume, exact-turn interrupt, worker stop, and thread archive; the soak additionally proves a real task duration above six hours / 原生输入、制作导入、PetCore 重启、同任务继续、精确 turn 中断、worker 停止与 thread 归档；soak 额外证明真实任务时长超过六小时 | Visible rendering of the same artifact or unattended system sleep unless the matching host-UI step is also observed / 同一产物的可见渲染；未配合主机 UI 验收时也不能证明无人值守系统睡眠 |
| Performance | `validate_event_storm.sh`, renderer summaries, external profiling | Measured bounded workload and renderer budgets / 已测量负载与渲染预算 | CPU/GPU conclusions without matching profiler evidence / 未采集 profiler 时的完整性能结论 |
| GitHub Release | `build_release.sh --github-release --arch all` and release artifact/API validators | Exact assets, identity, checksums, ZIP safety, ad-hoc signatures, thin architectures, native packaged acceptance, downloaded-asset equality / 资产、身份、校验和、安全、签名、架构、原生验收与下载一致性 | Developer identity, notarization, stapling, default Gatekeeper trust, untested hardware / 开发者身份、公证、stapling、默认 Gatekeeper 信任与未测硬件 |

Build and validation are separate profiles. `build_and_run.sh --run` and the environment Run button assemble, statically inspect, and launch a development App; they do not execute the packaged runtime acceptance suite first. Development build identity is a stable fingerprint of runtime inputs and build variant, so an unchanged second Run keeps Cargo/Swift incremental products instead of recompiling because of a timestamp-only ID. Use `build_and_run.sh --verify` for full packaged runtime proof. `build_app_bundle.sh --validation static|full` exposes the same boundary for automation. / 构建与验证是两个层级。日常 Run 只组装并静态检查开发 App 后启动；开发 build ID 绑定运行时源码与构建变体，源码不变的再次 Run 不会因时间戳变化重编译。完整打包运行时证明使用 `--verify`。

## Local default gate / 本地默认门禁

```bash
./script/validate_pre_push.sh --plan-only
./script/validate_pre_push.sh
```

The local default is deliberately bounded: it checks diff and source syntax, localization and lightweight Skill/workflow contracts when touched, Rust formatting plus `cargo check`, and `swift build`. It does not run complete Rust or Swift tests, simulated connector/producer roundtrips, App assembly, stress, or release artifact validation. Those duplicate proofs belong to required GitHub CI. The local gate never launches the GUI, mutates user LaunchAgents, invokes real Agents, or reads credentials. / 本地默认门禁刻意保持轻量：检查 diff 与源码语法，并按改动运行本地化、轻量 Skill/workflow 合同、Rust 格式与 `cargo check`、`swift build`；它不再重复全量 Rust/Swift 测试、连接器或制作 roundtrip、App 组装、压力与发布产物验证，这些由 GitHub 必选 CI 负责。本地门禁不会启动 GUI、修改用户 LaunchAgent、调用真实 Agent 或读取凭据。

`validation_scope.py` is the single path classifier used by local pre-push and CI. The routing contract is: / 本地预推送与 CI 共用 `validation_scope.py`，范围合同如下：

| Change / 变更 | Automatic proof / 自动证明 | Not automatic / 不自动执行 |
|---|---|---|
| Documentation only / 仅文档 | links, syntax, diff hygiene / 链接、语法、diff | Rust, Swift, App build, Computer Use |
| Localization resources / 本地化资源 | localization parity / 本地化一致性 | full Swift, App build, Computer Use |
| Overlay-only Swift / 仅悬浮层 Swift | local compile; CI complete Swift interaction proof, offline overlay proof, and bundle / 本地编译；CI 全量 Swift 交互证明、离线悬浮层证明与 bundle | live UI is only recommended / 可见 UI 仅按需建议 |
| Other Swift / 其他 Swift | local compile; CI complete Swift plus bundle proof / 本地编译；CI 全量 Swift 与 bundle | Computer Use unless visible behavior needs observation |
| Rust package / Rust package | local format/compile; CI strict lint plus inventory-checked parallel core and integration shards / 本地格式与编译；CI 严格 lint 及带清单校验的并行核心/集成分片 | unrelated live UI / 无关可见 UI |
| Scripts/workflows / 脚本与 workflow | syntax and release-contract tests; bundle only for bundle-owning scripts / 语法与发布契约；仅 bundle 相关脚本触发 bundle | product UI acceptance |
| Release / 发布 | Swift 6.2+/SDK 26+ source gate, explicit stress, parallel thin builds, SDK 26 + macOS 14 deployment + weak-link inspection, native macOS 15 acceptance for both architectures, and packaged macOS 26 acceptance / Swift 6.2+/SDK 26+ 源码门禁、显式压力测试、双架构并行构建、SDK 26 + macOS 14 部署目标 + 弱链接检查、双架构 macOS 15 原生验收及 macOS 26 打包验收 | repeated package execution after trusted digest equality |

`test_all.sh --resume` remains an explicit local diagnosis tool, not a pre-push requirement. It stores successful step checkpoints under this worktree's Git directory and reports wall-clock duration. Use it only to reproduce a remote failure or investigate a complete gate locally. / `test_all.sh --resume` 仍可用于本地完整门禁排错，但不再是推送前要求；它会在当前 worktree 的 Git 目录保存成功步骤检查点并报告耗时，仅应在复现远端失败或本地排查完整门禁时使用。

```bash
./script/test_all.sh --resume
./script/test_all.sh --clear-cache
```

Authoritative CI never consumes local checkpoints or calls the local fast gate. One classifier fans work out into static contracts, integration contracts, Rust lint, five inventory-checked Rust test shards, complete Swift interaction proof, bounded stress, offline overlay proof, and App assembly. Every successful PR `Required CI` emits a short-lived merge ticket bound to repository, PR, base/head refs and SHAs, tested merge parents, run/attempt, and lane. Ready direct or final train PRs to `main` also emit a candidate proof bound to the tested merge commit, exact tree, gate inventory, toolchains, and interaction bytes. Task PRs to `gd-ops/train/*` remain path-scoped, create no Release candidate, and have no duplicate train-push run. / 权威 CI 不消费本地检查点，也不调用本地快速门禁。统一分类结果会并行路由到静态合同、集成合同、Rust lint、5 个带清单校验的 Rust 测试分片、完整 Swift 交互证明、压力、离线悬浮层证明与 App 组装。每个成功的 PR `Required CI` 都会生成短期 merge ticket，绑定仓库、PR、base/head ref 与 SHA、测试合并父提交、run/attempt 和通道。ready 的 direct 或最终 train → `main` PR 还会生成绑定测试合并 commit、精确 tree、门禁清单、工具链与交互证明字节的候选证明。task → train PR 保持按路径验证、不生成 Release 候选，且合并后不重复运行 train push CI。

On a trusted `main` validation (`push` or exact-SHA `workflow_dispatch`), CI first attempts exact-tree proof promotion. The post-CI merger uses the dispatch form after its `GITHUB_TOKEN` squash merge because token-produced ordinary events do not start another workflow; the dispatch fails closed unless its required SHA is the checked-out `main` commit. Promotion requires exactly one same-repository managed PR for the squash commit, one successful pull-request workflow with a successful `Required CI`, one live bounded candidate artifact, a tested merge whose ordered parents are the previous main commit and PR head, and a tested tree identical to the new main tree. CI/Release workflows, proof resolvers, interaction-proof definitions, and their routing contracts must also be unchanged from the previous trusted main commit, so a control-plane PR—including the first rollout of this mechanism—must complete the full main CI once before later PRs can reuse it. Promotion rebinds only the already-proven interaction identity; any failed check leaves the promotion output unset and schedules the complete release-grade main gates instead. / 受信任的 `main` 验证（`push` 或精确 SHA 的 `workflow_dispatch`）会先尝试精确 tree 证明晋升。CI 后合并器使用 `GITHUB_TOKEN` 完成 squash 合并后会采用显式派发，因为 token 产生的普通事件不会再启动 workflow；若必填 SHA 与 checkout 的 `main` commit 不一致，派发会 fail closed。晋升必须存在唯一的同仓库受管 PR 对应 squash commit、唯一成功且含成功 `Required CI` 的 PR workflow、唯一未过期的有界候选 artifact；测试合并的有序父提交必须是前一 main commit 与 PR head，且测试 tree 必须与新 main tree 完全一致。CI/Release workflow、证明解析器、交互证明定义及其路由合同还必须相对前一个受信任 main commit 保持不变，因此控制面 PR（包括本机制的首次上线）必须先完整执行一次 main CI，之后的 PR 才能复用它。晋升只重绑已经证明的交互身份；任一检查失败都会保持晋升输出为空，并改为调度完整 Release 级 main 门禁。

After a successful trusted `main` validation, CI uploads exactly `source-proof.json` and `interaction-attestation.json` as `release-source-proof-FULL_COMMIT`. The v3 proof binds repository, full commit and tree, latest stable baseline, trusted main issuer event/run, gate inventory, toolchain-contract digest, observed toolchains, interaction bytes, and either the full main validation run or the promoted pull-request validation commit/run/ref plus candidate-proof digest. Release accepts only a successful `push` or `workflow_dispatch` run of `.github/workflows/ci.yml` on `main` from the same repository and exact commit; missing, expired, duplicate, malformed, or mismatched proof fails closed. The Release rebinds the proven interaction contract to its final build ID without repeating the complete source suites. / 受信任的 `main` 验证成功后，CI 会以 `release-source-proof-FULL_COMMIT` 上传且仅上传 `source-proof.json` 与 `interaction-attestation.json`。v3 证明绑定仓库、完整 commit/tree、latest stable 基线、受信任 main 签发事件/run、门禁清单、工具链合同摘要、已观察工具链、交互证明字节，以及“完整 main 验证 run”或“被晋升的 PR 验证 commit/run/ref 与候选证明摘要”。Release 只接受同仓库、同 commit、`main` 上成功的 `.github/workflows/ci.yml` `push` 或 `workflow_dispatch` run；缺失、过期、重复、格式错误或不匹配均 fail closed，并只将已证明交互合同重新绑定到最终 build ID，不再重复全量源码测试。

Protected delivery is owned by the repository's idempotent ruleset applicator. `Protected default branch` requires pull requests, squash-only linear history, resolved conversations, current-base `Required CI`, and blocks force-push/deletion. `Protected integration trains` applies the PR, squash, and `Required CI` contract to `gd-ops/train/*`, but uses non-strict status checks and permits deletion after the final train PR. The trusted post-CI merger accepts only the exact CI workflow path, same repository, managed branch, successful `Required CI`, current merge ticket, and matching lane proof. It checks out only the trusted `main` verifier. PRs touching the enumerated CI/Release/merge/proof/ruleset control plane fail closed out of auto-merge and require a trusted manual squash, preventing a PR-authored workflow from proving itself. Ordinary direct/final-train merges dispatch exact-SHA main validation with bounded retries; reruns safely recover an already-merged PR and skip an existing queued/running/successful dispatch. Task-to-train merges deliberately dispatch nothing. / 受保护交付由幂等 ruleset 配置器负责。默认分支要求 PR、仅 squash 的线性历史、讨论已解决、基于最新基线的 `Required CI`，并禁止强推与删除；train 规则对 `gd-ops/train/*` 要求 PR、squash 与 `Required CI`，但采用 non-strict 检查并允许最终合并后删除。受信任的 CI 后合并器只接受精确 CI workflow 路径、同仓库、受管分支、成功 `Required CI`、当前 merge ticket 与匹配的通道证明，并只 checkout 受信任的 `main` 验证器。触及列举的 CI/Release/合并器/证明/ruleset 控制面的 PR 会 fail closed 退出自动合并并要求受信任人工 squash，防止 PR 自写 workflow 后自证。普通 direct/最终 train 合并会用有界重试派发精确 SHA 的 main 验证；重跑可安全恢复已合并 PR，并跳过已有的 queued/running/successful 派发。task→train 合并则明确不派发任何任务。

During the initial migration, reversible repository settings may be applied first. Push the workflows and wait for the new exact `main` `Required CI` to succeed before applying either ruleset. Full apply fails closed until that trusted check exists. / 首次迁移可先应用可逆仓库设置；必须先推送 workflow 并等待新的精确 `main` `Required CI` 成功，才能应用两个 ruleset。完整 apply 在该受信任检查存在前会 fail closed。

```bash
./script/configure_main_branch_ruleset.py --settings-only --apply
./script/configure_main_branch_ruleset.py
./script/configure_main_branch_ruleset.py --apply
```

Branch/worktree ownership and direct/train PR coordination are defined by [Parallel development](parallel-development.md). / 分支、worktree 所有权及 direct/train PR 协调见并行开发文档。

## Environment-dependent gates / 环境门禁

- `APC_VALIDATE_HOST_UI=1` permits repository validators that affect a packaged App runtime. It does not itself invoke Computer Use.
- `APC_VALIDATE_REAL_AGENT_CONNECTORS=1` permits checks against installed Agent CLIs and managed connector files. It never permits reading credential stores.
- `APC_VALIDATE_REAL_APP_SERVER=1` permits the real App Server lifecycle validation. It deliberately requests native input, completes one pet, interrupts and restarts its owned PetCore, resumes a second task, then strictly cancels and verifies the exact Studio thread is archived or absent from the ordinary list. `APC_REQUIRE_EXTERNAL_SKILL_SOURCE=1` keeps the strict release proof; lowering it weakens the result.
- `APC_RUN_SIX_HOUR_MAKER_SOAK=1` runs the non-default six-hour gate. It holds a real task in durable waiting-for-user state for just over six hours, verifies the backend-authoritative duration includes that interval, and then runs the same resume/cancel lifecycle checks.
- `APC_EVENT_STORM_COUNT` changes the bounded stress workload.

Computer Use is evidence for visible App, menu bar, desktop pet, bubble, focus, pointer, keyboard, window lifecycle, update handoff, and multi-instance behavior. It is recommended after an automated UI-source change when that visible behavior is in scope, but no build, test, CI, or release script invokes it automatically. Documentation, localization, backend, schema, CLI, workflow, packaging-only, and release-metadata changes do not require it. A small overlay bug may run focused tests and one scoped live observation; it must not trigger a full product walkthrough. Record structural-only conclusions separately from directly observed UI behavior. / Computer Use 只用于可见 App 与真实交互证据；任何脚本都不会自动调用。文档、本地化、后端、schema、CLI、workflow、纯打包与发布元数据变更不需要它。小范围悬浮层修复只需聚焦测试与必要的一次范围内可见验收，不触发全产品巡检。

`validate_overlay_interaction.sh` runs the deterministic placement, snapshot, geometry, display-width, and telemetry suites and emits the build-bound interaction attestation. `--swift-scope all` folds that proof into one complete Swift run for Release. Real pointer, focus, keyboard, and lifecycle behavior remains a separate visible-UI acceptance step. / 悬浮层脚本验证确定性交互契约并生成 build 绑定证明；Release 使用 `--swift-scope all` 将证明合并到一次完整 Swift 运行中。真实交互仍是单独的可见 UI 验收。

Useful focused commands:

```bash
APC_VALIDATE_REAL_AGENT_CONNECTORS=1 ./script/validate_real_agent_connectors.sh
APC_VALIDATE_REAL_APP_SERVER=1 ./script/validate_real_app_server.sh
APC_RUN_SIX_HOUR_MAKER_SOAK=1 ./script/soak_ai_pet_maker_six_hours.sh
APC_EVENT_STORM_COUNT=1000 ./script/validate_event_storm.sh
./script/validate_overlay_performance_summary.sh /absolute/summary.json 60
```

Report an unavailable environment gate as skipped, never passed. / 环境不具备时标记为 skipped，不能写成 passed。

## Producer capability boundary / 制作能力边界

V3 runtime accepts `low` 192×208, `standard` 384×416, and `high` 576×624. A producer qualifies for a tier only when every untouched decoded 12:13 source crop meets or exceeds that tier before the one permitted downscale. Prompted dimensions, upscaling, padding, super-resolution, or extra batches do not establish source capacity.

The App's Codex-backed Studio and the built-in ChatGPT/Codex image path are qualified for `low` and `standard`, not `high`. Another workflow may produce `high` only after its actual decoded source passes the repository's capacity and representative-action checks. The [V3 specification](../specifications/AgentPetCompanion_Petpack_Whitepaper_V3.md) owns the normative package rule; transient measurements belong in CI or task evidence. / App 内 Studio 与内置生图只支持标清和标准；高清必须由真实来源像素满足要求的外部流程制作。实验数据不写入长期文档。

## Release boundary / 发布边界

Official V1 distribution uses the explicit fail-closed `build_release.sh --github-release` path. Local complete candidates use `--arch all`; automation uses `--arch arm64|x86_64` as parallel components and assembles the checksum only after both pass. Development Apps and handoff archives are not official artifacts. Native arm64 and x86_64 packaged validation plus exact downloaded-byte equality are mandatory publication dependencies. The [release procedure](../release/macos-release.md) owns commands and asset contracts.

Codex plugin/Skill changes also run `validate_codex_plugin_version.py` against the intended release base. It proves plugin/Skill version-marker discipline and rejects unsupported Hook-template top-level fields; it does not prove convergence of a particular user's active cache.

Do not paste validation results into this file. / 不要把某次验证结果粘贴到本文。
