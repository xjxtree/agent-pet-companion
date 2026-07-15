# Validation Profiles / 验证层级

> Current pass/fail results are recorded in [project status](../docs/PROJECT_STATUS.md). This file defines what each profile can prove; listing a script here does not mean its latest run passed.
> 当前通过/失败结果记录在[项目状态](../docs/PROJECT_STATUS.md)。本文只定义各层验证能证明什么；脚本列在表中不代表最近一次运行已经通过。

This repository uses several validation layers. `script/test_all.sh` labels each step so simulated or fake-input checks are not mistaken for real end-to-end acceptance, and real runtime gates either run when enabled/available or print explicit skip reasons.

本仓库按层级组织验证。`script/test_all.sh` 会给每一步标注层级，避免把 simulated/fake 验证误认为真实端到端验收；真实运行时 gate 会在启用/可用时运行，否则输出明确跳过原因。

| Profile / 层级 | Scripts / 脚本 | Proves / 覆盖内容 | Does not prove / 不代表 |
|---|---|---|---|
| `fast/core` | `validate_m0.sh`, `validate_m1.sh`, `validate_m2.sh`, `validate_m6.sh`, `validate_security_boundaries.sh` | Deterministic Rust/PetCore/CLI/schema/Swift-core checks, local daemon smoke, petpack validation, renderer budget calculations, and fake sentinel secret redaction. / 确定性的 Rust、PetCore、CLI、schema、Swift core、本地 daemon、petpack、renderer budget 和 fake sentinel 密钥脱敏检查。 | Real macOS overlay rendering, real third-party agents, or a real Codex App Server session. / 不代表真实 macOS 悬浮层、真实第三方 Agent 或真实 Codex App Server 会话。 |
| `simulated integration` | `validate_m3.sh`, `validate_m4.sh`, `validate_m5.sh`, `validate_connectors_runtime.sh`, `validate_v1.sh` | Integration behavior in temporary `APC_HOME`/`APC_AGENT_CONFIG_HOME`, local Pet Studio fallback, generated connector hooks/plugins, event normalization, filtering, and library flows. / 临时 home 中的集成行为、本地 Pet Studio fallback、生成的 connector hooks/plugins、事件归一化、过滤和宠物库流程。 | Real user agent CLIs, trusted user hooks, real App Server generation, or visible desktop overlay acceptance. / 不代表真实用户 Agent CLI、已信任 hooks、真实 App Server 生成或可见桌面悬浮层验收。 |
| `macos runtime` | `build_and_run.sh --verify`, `validate_app_bundle.sh`, `validate_overlay_runtime.sh`, `validate_main_window_ui.sh`, `validate_overlay_non_mouse.sh`, `validate_overlay_interaction.sh`, `validate_overlay_scale_persistence.sh`, `validate_renderer_runtime_budget.sh`, `validate_app_recovery.sh` | Packaged `.app` launch, bundled `petcore`/`petcore-cli`, main-window/overlay structure, multi-agent bubble layout, interaction, scale persistence, renderer telemetry, and recovery—only for the exact scripts and environment that ran. Live UI execution must be orchestrated Computer Use first. / 覆盖已打包 App、内置二进制、主窗口/悬浮层结构、消息气泡、交互、缩放、renderer telemetry 与恢复，但只证明实际运行的脚本和环境；真实 UI 必须优先由 Computer Use 编排。 | Real Codex App Server generation, third-party agent trust state, full Instruments profiling, or user-safe input behavior when a legacy direct-input script is run. / 不代表真实 App Server、第三方 Agent 信任、完整 Instruments profiling，也不代表直接输入脚本不会打断用户。 |
| `real agent connectors` | `validate_real_agent_connectors.sh` | Current user Codex/Claude/Pi/OpenCode connector files and hook/plugin commands can send diagnostic events into the currently running app through the real local event socket. / 当前用户目录中的 Codex/Claude/Pi/OpenCode connector 文件和 hook/plugin 命令可以通过真实本地事件 socket 向当前运行的 app 写入诊断事件。 | A full interactive third-party agent session, provider authentication, or real model/tool execution. The script does not read auth/token/cookie files. / 不代表完整交互式第三方 Agent 会话、供应商认证或真实模型/工具执行；脚本不读取 auth/token/cookie 文件。 |
| `real app server` | `validate_real_app_server.sh` | Real Codex App Server stdio session through PetCore when `CODEX_APP_SERVER_CMD` is set or `codex app-server` is available. By default `APC_REQUIRE_EXTERNAL_SKILL_SOURCE=1` requires image-generated or user-reference-derived `skill-full-source`, visible frame differences, validation, build, import, and activation; preview helpers and PetCore materializers are rejected. / 在 `CODEX_APP_SERVER_CMD` 已配置或 `codex app-server` 可用时，通过 PetCore 验证真实 Codex App Server stdio 会话。默认 `APC_REQUIRE_EXTERNAL_SKILL_SOURCE=1` 要求 image-generated 或 user-reference-derived 的 `skill-full-source`、可见帧差异、校验、构建、入库和启用；预览 helper 与 PetCore materializer 均会被拒绝。 | Visible packaged-App Studio interaction and desktop rendering of that exact artifact are separate macOS runtime acceptance steps. / 已打包 App 中可见的 Studio 交互和该确切产物的桌面渲染仍属于独立的 macOS runtime 验收。 |
| `perf/nightly` | `validate_event_storm.sh`, renderer budget assertions inside core/V1 scripts | Bounded event storm and budget-regression checks. `test_all.sh` includes the default-size event storm. / 有界事件风暴和预算回归检查；`test_all.sh` 包含默认规模事件风暴。 | Full Instruments-style CPU/GPU profiling. Increase `APC_EVENT_STORM_COUNT` or add external profiling for nightly runs. / 不代表完整 Instruments CPU/GPU profiling；夜间验证应提高 `APC_EVENT_STORM_COUNT` 或增加外部 profiling。 |

## Skip Gates / 跳过条件

- `APC_VALIDATE_OVERLAY_RUNTIME=0` skips `macos runtime`; `1` forces it; `auto` runs it on Darwin only.
- `APC_VALIDATE_REAL_AGENT_CONNECTORS=0` keeps real user connector validation out of default `test_all`; `1` forces it; `auto` lets `validate_real_agent_connectors.sh` run only when the current app, user connector files, and agent CLIs are present.
- `APC_VALIDATE_REAL_APP_SERVER=0` skips `real app server`; `1` forces it; `auto` runs it only when `CODEX_APP_SERVER_CMD` is set or `codex app-server --help` succeeds.
- `APC_REQUIRE_EXTERNAL_SKILL_SOURCE=0` explicitly downgrades the real App Server validation to accept PetCore's deterministic preview materializer; the default is `1`, which requires externally image-generated or user-reference-derived full source.
- `APC_VALIDATE_OVERLAY_INTERACTION=0` skips legacy direct mouse interaction validation. Setting it to `1` is a technical gate only and is not authorization to take over user input: use Computer Use first; if an uncovered fallback can move the pointer, inject keys, activate apps, or steal focus, obtain explicit approval immediately before running it.
- `APC_EVENT_STORM_COUNT` changes the bounded event storm size; default is `180`.

- `APC_VALIDATE_OVERLAY_RUNTIME=0` 会跳过 `macos runtime`；`1` 强制运行；`auto` 只在 Darwin 上运行。
- `APC_VALIDATE_REAL_AGENT_CONNECTORS=0` 会把真实用户 connector 验证排除在默认 `test_all` 之外；`1` 强制运行；`auto` 由 `validate_real_agent_connectors.sh` 在当前 app、用户 connector 文件和 agent CLI 都存在时运行。
- `APC_VALIDATE_REAL_APP_SERVER=0` 会跳过 `real app server`；`1` 强制运行；`auto` 只在 `CODEX_APP_SERVER_CMD` 已配置或 `codex app-server --help` 成功时运行。
- `APC_REQUIRE_EXTERNAL_SKILL_SOURCE=0` 会显式降级 real App Server 验证并允许 PetCore 的确定性预览 materializer；默认是 `1`，要求外部图像生成或用户参考图派生的完整 source。
- `APC_VALIDATE_OVERLAY_INTERACTION=0` 会跳过旧的直接鼠标交互验证。设为 `1` 只是技术 gate，不代表已获授权接管用户输入；必须优先使用 Computer Use。只有在其无法覆盖且已于执行前取得明确授权时，才能使用会移动鼠标、注入按键、激活 App 或抢焦点的替代方法。
- `APC_EVENT_STORM_COUNT` 控制有界事件风暴规模；默认是 `180`。

## Batch 1 Recommended Commands / 第 1 批推荐命令

Run these in order when separating deterministic/simulated checks from real runtime acceptance:

当需要把确定性/模拟验证和真实运行时验收分开时，建议按顺序运行：

```bash
APC_VALIDATE_OVERLAY_RUNTIME=0 APC_VALIDATE_REAL_AGENT_CONNECTORS=0 APC_VALIDATE_REAL_APP_SERVER=0 ./script/test_all.sh
# Run live macOS UI acceptance through Computer Use first; invoke a host script
# only when it is non-interrupting or the user explicitly approved the fallback.
APC_VALIDATE_REAL_AGENT_CONNECTORS=1 ./script/validate_real_agent_connectors.sh
APC_VALIDATE_REAL_APP_SERVER=1 ./script/validate_real_app_server.sh
APC_EVENT_STORM_COUNT=1000 ./script/validate_event_storm.sh
```

Use the first command for CI-friendly default coverage with real runtime gates explicitly skipped. Perform macOS host acceptance through Computer Use first. Run real connectors only after the packaged app and user connectors are present, run the App Server gate only when a real server is configured, and use the event-storm command as an expanded nightly check. These are intended commands, not a statement that the current default gate is green.

第一条适合 CI 友好的默认覆盖，并显式跳过真实运行时 gate。macOS 宿主验收必须优先通过 Computer Use 执行；packaged app 与用户 connector 已存在后再运行真实连接器，真实 Codex App Server 配置完成后再运行对应 gate，事件风暴命令用于扩大规模的夜间检查。这些是预期入口，不代表当前默认门禁为绿色。
