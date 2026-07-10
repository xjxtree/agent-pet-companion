# Validation Profiles / 验证层级

This repository uses several validation layers. `script/test_all.sh` labels each step so simulated or fake-input checks are not mistaken for real end-to-end acceptance, and real runtime gates either run when enabled/available or print explicit skip reasons.

本仓库按层级组织验证。`script/test_all.sh` 会给每一步标注层级，避免把 simulated/fake 验证误认为真实端到端验收；真实运行时 gate 会在启用/可用时运行，否则输出明确跳过原因。

| Profile / 层级 | Scripts / 脚本 | Proves / 覆盖内容 | Does not prove / 不代表 |
|---|---|---|---|
| `fast/core` | `validate_m0.sh`, `validate_m1.sh`, `validate_m2.sh`, `validate_m6.sh`, `validate_security_boundaries.sh` | Deterministic Rust/PetCore/CLI/schema/Swift-core checks, local daemon smoke, petpack validation, renderer budget calculations, and fake sentinel secret redaction. / 确定性的 Rust、PetCore、CLI、schema、Swift core、本地 daemon、petpack、renderer budget 和 fake sentinel 密钥脱敏检查。 | Real macOS overlay rendering, real third-party agents, or a real Codex App Server session. / 不代表真实 macOS 悬浮层、真实第三方 Agent 或真实 Codex App Server 会话。 |
| `simulated integration` | `validate_m3.sh`, `validate_m4.sh`, `validate_m5.sh`, `validate_connectors_runtime.sh`, `validate_v1.sh` | Integration behavior in temporary `APC_HOME`/`APC_AGENT_CONFIG_HOME`, local Pet Studio fallback, generated connector hooks/plugins, event normalization, filtering, and library flows. / 临时 home 中的集成行为、本地 Pet Studio fallback、生成的 connector hooks/plugins、事件归一化、过滤和宠物库流程。 | Real user agent CLIs, trusted user hooks, real App Server generation, or visible desktop overlay acceptance. / 不代表真实用户 Agent CLI、已信任 hooks、真实 App Server 生成或可见桌面悬浮层验收。 |
| `macos runtime` | `build_and_run.sh --verify`, `validate_app_bundle.sh`, `validate_overlay_runtime.sh`, `validate_main_window_ui.sh`, `validate_overlay_non_mouse.sh`, `validate_overlay_interaction.sh`, `validate_overlay_scale_persistence.sh`, `validate_renderer_runtime_budget.sh`, `validate_app_recovery.sh` | Packaged `.app` launch, bundled `petcore`/`petcore-cli`, real main-window UI structure without mouse events, real overlay runtime checks, multi-agent bubble layout without mouse events, mouse drag/resize/bubble interactions, scale persistence, renderer cache strategy telemetry for ultra/original pets, and recovery. / `.app` 打包启动、内置 `petcore`/`petcore-cli`、真实主窗口 UI 结构无鼠标验证、真实悬浮层运行时、无鼠标真实多 Agent 气泡布局、鼠标拖动/缩放/气泡交互、缩放持久化、超清/原画宠物的 renderer 缓存策略 telemetry 和恢复。 | Real Codex App Server generation, third-party agent trust state, or full Instruments CPU/GPU profiling. / 不代表真实 Codex App Server 生成、第三方 Agent 信任状态或完整 Instruments CPU/GPU profiling。 |
| `real agent connectors` | `validate_real_agent_connectors.sh` | Current user Codex/Claude/Pi/OpenCode connector files and hook/plugin commands can send diagnostic events into the currently running app through the real local event socket. / 当前用户目录中的 Codex/Claude/Pi/OpenCode connector 文件和 hook/plugin 命令可以通过真实本地事件 socket 向当前运行的 app 写入诊断事件。 | A full interactive third-party agent session, provider authentication, or real model/tool execution. The script does not read auth/token/cookie files. / 不代表完整交互式第三方 Agent 会话、供应商认证或真实模型/工具执行；脚本不读取 auth/token/cookie 文件。 |
| `real app server` | `validate_real_app_server.sh` | Real Codex App Server stdio session through PetCore when `CODEX_APP_SERVER_CMD` is set or `codex app-server` is available, and by default `APC_REQUIRE_EXTERNAL_SKILL_SOURCE=1` proves the App Server invoked the Pet Studio helper to write a validated `petpack-source` rather than relying on PetCore's built-in materializer. / 在 `CODEX_APP_SERVER_CMD` 已配置或 `codex app-server` 可用时，通过 PetCore 验证真实 Codex App Server stdio 会话；默认 `APC_REQUIRE_EXTERNAL_SKILL_SOURCE=1` 会证明 App Server 调用了 Pet Studio helper 并实际写出了可校验的 `petpack-source`，而不是依赖 PetCore 内置 materializer。 | Overlay rendering, real third-party agent events, or unrestricted AI asset production. The validation prompt asks for a small safe brief and no secret reads. / 不代表悬浮层渲染、真实第三方 Agent 事件或无限制 AI 素材生产；验证 prompt 要求小型安全 brief 且不读取秘密。 |
| `perf/nightly` | `validate_event_storm.sh`, renderer budget assertions inside core/V1 scripts | Bounded event storm and budget-regression checks. `test_all.sh` includes the default-size event storm. / 有界事件风暴和预算回归检查；`test_all.sh` 包含默认规模事件风暴。 | Full Instruments-style CPU/GPU profiling. Increase `APC_EVENT_STORM_COUNT` or add external profiling for nightly runs. / 不代表完整 Instruments CPU/GPU profiling；夜间验证应提高 `APC_EVENT_STORM_COUNT` 或增加外部 profiling。 |

## Skip Gates / 跳过条件

- `APC_VALIDATE_OVERLAY_RUNTIME=0` skips `macos runtime`; `1` forces it; `auto` runs it on Darwin only.
- `APC_VALIDATE_REAL_AGENT_CONNECTORS=0` keeps real user connector validation out of default `test_all`; `1` forces it; `auto` lets `validate_real_agent_connectors.sh` run only when the current app, user connector files, and agent CLIs are present.
- `APC_VALIDATE_REAL_APP_SERVER=0` skips `real app server`; `1` forces it; `auto` runs it only when `CODEX_APP_SERVER_CMD` is set or `codex app-server --help` succeeds.
- `APC_REQUIRE_EXTERNAL_SKILL_SOURCE=0` allows the real App Server validation to accept PetCore's built-in full-source materializer; the default is `1`, which requires an App Server-invoked Pet Studio helper `petpack-source`.
- `APC_VALIDATE_OVERLAY_INTERACTION=0` skips overlay mouse interaction validation; `1` forces it and fails when Accessibility permission is missing; `auto` skips only when the current automation host is not trusted for Accessibility.
- `APC_EVENT_STORM_COUNT` changes the bounded event storm size; default is `180`.

- `APC_VALIDATE_OVERLAY_RUNTIME=0` 会跳过 `macos runtime`；`1` 强制运行；`auto` 只在 Darwin 上运行。
- `APC_VALIDATE_REAL_AGENT_CONNECTORS=0` 会把真实用户 connector 验证排除在默认 `test_all` 之外；`1` 强制运行；`auto` 由 `validate_real_agent_connectors.sh` 在当前 app、用户 connector 文件和 agent CLI 都存在时运行。
- `APC_VALIDATE_REAL_APP_SERVER=0` 会跳过 `real app server`；`1` 强制运行；`auto` 只在 `CODEX_APP_SERVER_CMD` 已配置或 `codex app-server --help` 成功时运行。
- `APC_REQUIRE_EXTERNAL_SKILL_SOURCE=0` 允许 real App Server 验证接受 PetCore 内置 full-source materializer；默认是 `1`，要求由 App Server 调用 Pet Studio helper 写出的 `petpack-source`。
- `APC_VALIDATE_OVERLAY_INTERACTION=0` 会跳过桌宠鼠标交互验证；`1` 强制运行，缺少辅助功能权限时失败；`auto` 仅在当前自动化宿主没有辅助功能信任时跳过。
- `APC_EVENT_STORM_COUNT` 控制有界事件风暴规模；默认是 `180`。

## Batch 1 Recommended Commands / 第 1 批推荐命令

Run these in order when separating deterministic/simulated checks from real runtime acceptance:

当需要把确定性/模拟验证和真实运行时验收分开时，建议按顺序运行：

```bash
APC_VALIDATE_OVERLAY_RUNTIME=0 APC_VALIDATE_REAL_AGENT_CONNECTORS=0 APC_VALIDATE_REAL_APP_SERVER=0 ./script/test_all.sh
./script/build_and_run.sh --verify
APC_VALIDATE_REAL_AGENT_CONNECTORS=1 ./script/validate_real_agent_connectors.sh
APC_VALIDATE_REAL_APP_SERVER=1 ./script/validate_real_app_server.sh
APC_EVENT_STORM_COUNT=1000 ./script/validate_event_storm.sh
```

Use the first command for CI-friendly default coverage with real runtime gates explicitly skipped. Use the second on macOS desktop sessions for overlay runtime. Use the third after the packaged app is running and user connector files are installed. Use the fourth only when a real Codex App Server is configured. Use the fifth as an expanded nightly stress run.

第一条适合 CI 友好的默认覆盖，并显式跳过真实运行时 gate。第二条适合 macOS 桌面会话中的悬浮层运行时验收。第三条适合 packaged app 已运行且用户 connector 文件已安装后执行。第四条只在真实 Codex App Server 已配置时运行。第五条作为扩大规模的夜间压力验证。
