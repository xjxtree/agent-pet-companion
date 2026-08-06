# Validation Profiles / 验证层级

Commands listed here define proof boundaries; they do not prove that a commit passed. Use fresh command output, CI artifacts, or Release evidence for the exact commit and artifact. / 本文只定义证明范围；具体 commit 是否通过必须以新鲜命令输出、CI artifact 或 Release 证据为准。

## Profiles / 层级

| Profile / 层级 | Main entrypoints / 入口 | Proves / 能证明 | Does not prove / 不能证明 |
|---|---|---|---|
| Fast/core | Rust fmt/Clippy/tests, `validate_swift_tests.sh`, schema/security/overlay validators | Deterministic logic, schemas, Swift models, native overlay interaction contracts / 确定性逻辑、schema、Swift 模型与悬浮层交互契约 | Visible UI, real Agents, real App Server generation / 可见 UI、真实 Agent、真实 App Server 制作 |
| Simulated integration | `validate_portable_pet_maker.sh`, `validate_connectors_runtime.sh` | Isolated package production, QA freshness, connector generation/normalization, library flows / 隔离宠物制作、QA 新鲜度、连接器与宠物库流程 | Artistic quality or a real provider task / 艺术质量或真实服务任务 |
| macOS runtime | `build_and_run.sh --verify`, bundle/overlay/window/renderer/recovery validators | The packaged App/runtime, clean-home bundled pets, persistence, rendering, and exercised recovery / 打包 App、运行时、内置宠物、持久化、渲染与恢复 | Unobserved UI behavior, real provider behavior, full profiling / 未直接观察的 UI、真实服务与完整性能结论 |
| Real connectors | `validate_real_agent_connectors.sh` | Current managed adapters can emit through the local runtime without reading credentials / 当前受管适配器可通过本地运行时发送事件 | Authentication, model execution, complete user task / 认证、模型执行、完整任务 |
| Real App Server | `validate_real_app_server.sh` | Codex App Server generation through validation, import, and activation / 真实 Codex 制作、校验、导入与启用 | Visible rendering of the same artifact / 同一产物的可见渲染 |
| Performance | `validate_event_storm.sh`, renderer summaries, external profiling | Measured bounded workload and renderer budgets / 已测量负载与渲染预算 | CPU/GPU conclusions without matching profiler evidence / 未采集 profiler 时的完整性能结论 |
| GitHub Release | `build_release.sh --github-release --arch all` and release artifact/API validators | Exact assets, identity, checksums, ZIP safety, ad-hoc signatures, thin architectures, native packaged acceptance, downloaded-asset equality / 资产、身份、校验和、安全、签名、架构、原生验收与下载一致性 | Developer identity, notarization, stapling, default Gatekeeper trust, untested hardware / 开发者身份、公证、stapling、默认 Gatekeeper 信任与未测硬件 |

## Default gate / 默认门禁

```bash
APC_VALIDATE_HOST_UI=0 \
APC_VALIDATE_REAL_AGENT_CONNECTORS=0 \
APC_VALIDATE_REAL_APP_SERVER=0 \
./script/test_all.sh
```

The default gate uses isolated homes and must not launch the GUI, mutate user LaunchAgents, invoke real Agents, or read credentials. Run a focused component check first when diagnosing a failure. / 默认门禁使用隔离 home，不启动 GUI、不修改用户 LaunchAgent、不调用真实 Agent，也不读取凭据；排错时先运行最小相关检查。

## Environment-dependent gates / 环境门禁

- `APC_VALIDATE_HOST_UI=1` permits repository validators that affect a packaged App runtime. It does not prescribe the UI inspection tool; the executing Agent selects a suitable method. Computer Use is recommended when available and useful.
- `APC_VALIDATE_REAL_AGENT_CONNECTORS=1` permits checks against installed Agent CLIs and managed connector files. It never permits reading credential stores.
- `APC_VALIDATE_REAL_APP_SERVER=1` permits a real App Server generation session. `APC_REQUIRE_EXTERNAL_SKILL_SOURCE=1` keeps the strict release proof; lowering it weakens the result.
- `APC_EVENT_STORM_COUNT` changes the bounded stress workload.

`validate_overlay_interaction.sh` always runs the deterministic placement, snapshot, geometry, display-width, and telemetry suites and emits the build-bound interaction attestation. Real pointer, focus, keyboard, and lifecycle behavior remains a separate visible-UI acceptance step whose method is selected for the task. / 悬浮层脚本始终验证确定性交互契约；真实指针、焦点、键盘和生命周期仍需按任务单独验收。

Useful focused commands:

```bash
APC_VALIDATE_REAL_AGENT_CONNECTORS=1 ./script/validate_real_agent_connectors.sh
APC_VALIDATE_REAL_APP_SERVER=1 ./script/validate_real_app_server.sh
APC_EVENT_STORM_COUNT=1000 ./script/validate_event_storm.sh
./script/validate_overlay_performance_summary.sh /absolute/summary.json 60
```

Report an unavailable environment gate as skipped, never passed. / 环境不具备时标记为 skipped，不能写成 passed。

## Producer capability boundary / 制作能力边界

V3 runtime accepts `low` 192×208, `standard` 384×416, and `high` 576×624. A producer qualifies for a tier only when every untouched decoded 12:13 source crop meets or exceeds that tier before the one permitted downscale. Prompted dimensions, upscaling, padding, super-resolution, or extra batches do not establish source capacity.

The App's Codex-backed Studio and the built-in ChatGPT/Codex image path are qualified for `low` and `standard`, not `high`. Another workflow may produce `high` only after its actual decoded source passes the repository's capacity and representative-action checks. The [V3 specification](../specifications/AgentPetCompanion_Petpack_Whitepaper_V3.md) owns the normative package rule; transient measurements belong in CI or task evidence. / App 内 Studio 与内置生图只支持标清和标准；高清必须由真实来源像素满足要求的外部流程制作。实验数据不写入长期文档。

## Release boundary / 发布边界

Official V1 distribution uses the explicit fail-closed `build_release.sh --github-release --arch all` path. Development Apps and handoff archives are not official artifacts. Native arm64 and x86_64 packaged validation plus downloaded-asset revalidation are mandatory publication dependencies. The [release procedure](../release/macos-release.md) owns commands and asset contracts.

Codex plugin/Skill changes also run `validate_codex_plugin_version.py` against the intended release base. It proves version and retired-Skill ownership discipline, not convergence of a particular user's active cache.

Do not paste validation results into this file. / 不要把某次验证结果粘贴到本文。
