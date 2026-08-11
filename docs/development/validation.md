# Validation Profiles / 验证层级

Commands listed here define proof boundaries; they do not prove that a commit passed. Use fresh command output, CI artifacts, or Release evidence for the exact commit and artifact. / 本文只定义证明范围；具体 commit 是否通过必须以新鲜命令输出、CI artifact 或 Release 证据为准。

## Profiles / 层级

| Profile / 层级 | Main entrypoints / 入口 | Proves / 能证明 | Does not prove / 不能证明 |
|---|---|---|---|
| Fast/core | Rust fmt/Clippy/tests, `validate_swift_tests.sh`, schema/security/overlay validators | Deterministic logic, schemas, Swift models, native overlay interaction contracts / 确定性逻辑、schema、Swift 模型与悬浮层交互契约 | Visible UI, real Agents, real App Server generation / 可见 UI、真实 Agent、真实 App Server 制作 |
| Simulated integration | `validate_portable_pet_maker.sh`, `validate_connectors_runtime.sh` | Isolated package production, QA freshness, connector generation/normalization, library flows / 隔离宠物制作、QA 新鲜度、连接器与宠物库流程 | Artistic quality or a real provider task / 艺术质量或真实服务任务 |
| macOS runtime | `build_and_run.sh --verify`, bundle/overlay/window/renderer/recovery validators | The packaged App/runtime, clean-home bundled pets, persistence, rendering, and exercised recovery / 打包 App、运行时、内置宠物、持久化、渲染与恢复 | Unobserved UI behavior, real provider behavior, full profiling / 未直接观察的 UI、真实服务与完整性能结论 |
| Real connectors | `validate_real_agent_connectors.sh` | Current managed adapters can emit through the local runtime without reading credentials / 当前受管适配器可通过本地运行时发送事件 | Authentication, model execution, complete user task / 认证、模型执行、完整任务 |
| Real App Server | `validate_real_app_server.sh`, optional `soak_ai_pet_maker_six_hours.sh` | Native input, generation/import, PetCore restart, same-job resume, exact-turn interrupt, worker stop, and thread archive; the soak additionally proves a real task duration above six hours / 原生输入、制作导入、PetCore 重启、同任务继续、精确 turn 中断、worker 停止与 thread 归档；soak 额外证明真实任务时长超过六小时 | Visible rendering of the same artifact or unattended system sleep unless the matching host-UI step is also observed / 同一产物的可见渲染；未配合主机 UI 验收时也不能证明无人值守系统睡眠 |
| Performance | `validate_event_storm.sh`, renderer summaries, external profiling | Measured bounded workload and renderer budgets / 已测量负载与渲染预算 | CPU/GPU conclusions without matching profiler evidence / 未采集 profiler 时的完整性能结论 |
| GitHub Release | `build_release.sh --github-release --arch all` and release artifact/API validators | Exact assets, identity, checksums, ZIP safety, ad-hoc signatures, thin architectures, native packaged acceptance, downloaded-asset equality / 资产、身份、校验和、安全、签名、架构、原生验收与下载一致性 | Developer identity, notarization, stapling, default Gatekeeper trust, untested hardware / 开发者身份、公证、stapling、默认 Gatekeeper 信任与未测硬件 |

Build and validation are separate profiles. `build_and_run.sh --run` and the environment Run button assemble, statically inspect, and launch a development App; they do not execute the packaged runtime acceptance suite first. Development build identity is a stable fingerprint of runtime inputs and build variant, so an unchanged second Run keeps Cargo/Swift incremental products instead of recompiling because of a timestamp-only ID. Use `build_and_run.sh --verify` for full packaged runtime proof. `build_app_bundle.sh --validation static|full` exposes the same boundary for automation. / 构建与验证是两个层级。日常 Run 只组装并静态检查开发 App 后启动；开发 build ID 绑定运行时源码与构建变体，源码不变的再次 Run 不会因时间戳变化重编译。完整打包运行时证明使用 `--verify`。

## Default gate / 默认门禁

```bash
APC_VALIDATE_HOST_UI=0 \
APC_VALIDATE_REAL_AGENT_CONNECTORS=0 \
APC_VALIDATE_REAL_APP_SERVER=0 \
./script/test_all.sh
```

The default gate uses isolated homes and must not launch the GUI, mutate user LaunchAgents, invoke real Agents, or read credentials. Bounded event-storm stress is opt-in with `--include-stress`; Release always enables it. Run a focused component check first when diagnosing a failure. / 默认门禁使用隔离 home，不启动 GUI、不修改用户 LaunchAgent、不调用真实 Agent，也不读取凭据。事件风暴压力测试通过 `--include-stress` 按需启用，Release 必须启用；排错时先运行最小相关检查。

For an ordinary local commit, start with the change-scoped pre-push gate. It always checks the diff and source syntax, then selects localization parity, Rust packages, Swift tests, connector smoke, or pet-production checks from the changed paths. `--plan-only` shows the selection without running it, and `--full` moves to the complete local gate. / 普通本地提交应先运行变更范围预推送门禁。它始终检查 diff 与源码语法，再根据变更路径选择本地化一致性、Rust package、Swift 测试、连接器 smoke 或宠物制作检查；`--plan-only` 仅显示计划，`--full` 转入完整本地门禁。

```bash
./script/validate_pre_push.sh --plan-only
./script/validate_pre_push.sh
```

`validation_scope.py` is the single path classifier used by local pre-push and CI. The routing contract is: / 本地预推送与 CI 共用 `validation_scope.py`，范围合同如下：

| Change / 变更 | Automatic proof / 自动证明 | Not automatic / 不自动执行 |
|---|---|---|
| Documentation only / 仅文档 | links, syntax, diff hygiene / 链接、语法、diff | Rust, Swift, App build, Computer Use |
| Localization resources / 本地化资源 | localization parity / 本地化一致性 | full Swift, App build, Computer Use |
| Overlay-only Swift / 仅悬浮层 Swift | seven focused overlay/frame suites plus CI bundle proof / 7 组聚焦测试与 CI bundle | unrelated Swift suites; live UI is only recommended |
| Other Swift / 其他 Swift | full Swift plus CI bundle proof / 全量 Swift 与 CI bundle | Computer Use unless visible behavior needs observation |
| Rust package / Rust package | affected package or workspace boundary, plus CI bundle when runtime inputs changed / 对应 package 或 workspace，运行时输入变化时再构建 bundle | unrelated component tests |
| Scripts/workflows / 脚本与 workflow | syntax and release-contract tests; bundle only for bundle-owning scripts / 语法与发布契约；仅 bundle 相关脚本触发 bundle | product UI acceptance |
| Release / 发布 | Swift 6.2+/SDK 26+ source gate, explicit stress, parallel thin builds, SDK 26 + macOS 14 deployment + weak-link inspection, native macOS 15 acceptance for both architectures, and packaged macOS 26 acceptance / Swift 6.2+/SDK 26+ 源码门禁、显式压力测试、双架构并行构建、SDK 26 + macOS 14 部署目标 + 弱链接检查、双架构 macOS 15 原生验收及 macOS 26 打包验收 | repeated package execution after trusted digest equality |

During local full-gate diagnosis, `test_all.sh --resume` stores successful step checkpoints under this worktree's Git directory, and every executed step reports its wall-clock duration. Every checkpoint includes a source-scope fingerprint, command, workload settings, and local toolchain identity; a relevant source or toolchain change reruns that step, while unrelated successful steps can be reused. Interaction evidence is content-bound to `interaction-contract-files.txt`; the same proven suites may be rebound to the current validation build and reused by offline overlay and App assembly only after the source digest is rechecked. App assembly itself always reruns because it produces the final bundle. Clear local checkpoints explicitly with `test_all.sh --clear-cache`. / 本地完整门禁排错时，`test_all.sh --resume` 会把成功步骤的检查点写入当前 worktree 的 Git 目录，每个实际执行的步骤也会报告墙钟耗时。每个检查点都绑定源码作用域指纹、命令、负载设置与本机工具链；相关源码或工具链变化会重跑该步骤，无关的已通过步骤可以复用。交互证据按 `interaction-contract-files.txt` 内容绑定；只有重新核对源码摘要后，已证明的同组测试才能绑定到当前验证 build，并供离线悬浮层与 App 组装复用。最终 App 组装始终重跑，因为它负责产出最终 bundle。可用 `test_all.sh --clear-cache` 显式清除本地检查点。

```bash
./script/test_all.sh --resume
./script/test_all.sh --clear-cache
```

Authoritative CI never consumes local checkpoints. Ordinary CI runs `validate_pre_push.sh --ci` with the shared classifier and builds a fully validated App only when runtime inputs changed. Release runs `test_all.sh --source-only --include-stress`, emits one source-bound interaction proof, and validates the exact packaged artifacts separately. Its complete Swift run also produces the interaction proof, so the five interaction suites are not run a second time. The String Catalog/`.strings` parity check remains ahead of expensive suites. / 权威 CI 不消费本地检查点。普通 CI 按变更范围运行，并只在运行时输入变化时构建完整验证的 App；Release 使用 `--source-only --include-stress`，一次完整 Swift 运行同时生成交互证明，再单独验证精确发布产物，避免重复运行 5 组交互测试。

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
