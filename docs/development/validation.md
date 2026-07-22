# Validation Profiles / 验证层级

This document defines what each validation layer can prove. A listed command is not evidence that the current commit passed; use fresh command output, CI artifacts, or GitHub Release notes for the exact commit and artifact.

本文只定义各层验证能证明什么。命令出现在表中不代表当前提交已经通过；具体结论必须来自对应 commit 与产物的新鲜命令输出、CI artifact 或 GitHub Release notes。

| Profile / 层级 | Main entrypoints / 主要入口 | Proves / 能证明 | Does not prove / 不能证明 |
|---|---|---|---|
| `fast/core` | `validate_m0.sh`, `validate_m1.sh`, `validate_m2.sh`, `validate_m6.sh`, `validate_swift_tests.sh`, `validate_security_boundaries.sh` | Deterministic Rust, PetCore, CLI, schema, Swift-core, UI-model/source contracts, local daemon, petpack, renderer-budget, and fake-secret-redaction behavior. / 确定性核心逻辑、UI 模型/源码契约与安全边界。 | Visible macOS UI, real third-party Agents, or real Codex App Server generation. / 不代表真实 UI、Agent 或 App Server。 |
| `simulated integration` | `validate_m3.sh`, `validate_m4.sh`, `validate_m5.sh`, `validate_connectors_runtime.sh`, `validate_v1.sh` | Integration behavior in isolated `APC_HOME`/`APC_AGENT_CONFIG_HOME`, generated connector artifacts, event normalization, filtering, and library flows. / 隔离目录中的模拟集成。 | User Agent trust/authentication, real model/tool execution, or visible overlay acceptance. / 不代表用户真实 Agent 与可见悬浮层。 |
| `macos runtime` | `build_and_run.sh --verify`, `validate_app_bundle.sh`, overlay/main-window/renderer/recovery validators | The exact packaged App, bundled runtime, window/overlay structure, interaction, persistence, rendering telemetry, and recovery exercised by the commands that ran. Live UI work uses Computer Use first. / 实际运行到的打包 App 与 macOS UI 行为。 | Real Agent/provider behavior, full Instruments profiling, or safety of an unapproved direct-input fallback. / 不代表真实 Agent、完整性能分析或未授权输入自动化。 |
| `real agent connectors` | `validate_real_agent_connectors.sh` | Current managed connector commands can emit diagnostic events through the running local runtime without reading credentials. / 当前真实连接器本地事件链路。 | Provider authentication, real model execution, or a complete user task. / 不代表认证、模型执行或完整任务。 |
| `real app server` | `validate_real_app_server.sh` | A real Codex App Server session through PetCore, including strict full-source generation, validation, build, import, and activation when required. / 真实 App Server 制作链路。 | Visible packaged-App interaction and rendering of the same artifact; those remain macOS runtime acceptance. / 不代表同一产物的可见 UI 与渲染验收。 |
| `perf/nightly` | `validate_event_storm.sh`, renderer budget assertions, external profiling | Bounded event-storm and budget regressions; expanded runs may add Instruments. / 事件风暴与预算回归。 | Full CPU/GPU conclusions unless the matching profiler evidence was actually captured. / 未实际采集时不代表完整 CPU/GPU 结论。 |

## Default host-safe gate / 默认宿主安全门禁

```bash
APC_VALIDATE_HOST_UI=0 \
APC_VALIDATE_OVERLAY_INTERACTION=0 \
APC_VALIDATE_REAL_AGENT_CONNECTORS=0 \
APC_VALIDATE_REAL_APP_SERVER=0 \
./script/test_all.sh
```

The default/simulated gate must use isolated homes and must not launch the GUI, mutate user LaunchAgents, invoke real Agents, or read credentials. Run component commands directly when narrowing a failure; the release gate remains the complete set documented in [macOS release procedure](../release/macos-release.md).

默认与模拟门禁必须使用隔离 home，不启动 GUI、不修改用户 LaunchAgent、不调用真实 Agent，也不读取凭据。定位失败时可单独运行组件命令；正式发布仍以 [macOS 发布流程](../release/macos-release.md)中的完整门禁为准。

## Explicit runtime gates / 显式真实运行时门禁

- `APC_VALIDATE_HOST_UI=0|1` controls packaged macOS runtime validation. Live UI verification must use Computer Use first; any fallback that can launch or activate an App, move input, or steal focus requires explicit user approval immediately before use.
- `APC_VALIDATE_REAL_AGENT_CONNECTORS=0|1|auto` controls access to current user connector files and installed Agent CLIs. It never authorizes reading credential stores.
- `APC_VALIDATE_REAL_APP_SERVER=0|1|auto` controls a real App Server session. `APC_REQUIRE_EXTERNAL_SKILL_SOURCE=1` is the strict release path; setting it to `0` explicitly downgrades the proof.
- `APC_VALIDATE_OVERLAY_INTERACTION=1` enables a legacy direct-input technical gate but is not user authorization to take over input.
- `APC_EVENT_STORM_COUNT` changes the bounded stress size; the default is `180`.

Recommended expanded commands:

```bash
APC_VALIDATE_REAL_AGENT_CONNECTORS=1 ./script/validate_real_agent_connectors.sh
APC_VALIDATE_REAL_APP_SERVER=1 ./script/validate_real_app_server.sh
APC_EVENT_STORM_COUNT=1000 ./script/validate_event_storm.sh
```

Run only the gates whose environment and authorization are present. Report skipped gates as skipped, never as passed.

## UI Next visual fixtures / UI Next 视觉夹具

Debug and test builds provide a non-interactive, offscreen renderer for the five control-center roots, About, MenuBarExtra, and all seven overlay states. Its representative scenario catalog covers 760/880/1120/1440 pt widths, system/light/dark appearance, English and Simplified Chinese, 1×/2× pixels, supported accessibility-display modes, PetCore operational states, four Agent sources, both configuration subpages, and 0/1/8 active sessions. Each scenario completes a real SwiftUI/AppKit bitmap transaction; overlay scenarios use the production Metal pet-stage path with checked-in state frames.

The fixture injects an unreachable PetCore socket and disables hit testing across the complete surface. It must not read or mutate the user's service, connectors, files, URLs, window state, or application lifecycle. Locale overrides are task-scoped, and accessibility/selection overrides default to the live system and persisted scene values outside a fixture.

These fixtures prove deterministic layout consumption and fallback presentation in the current build environment. They do not replace Computer Use acceptance of the packaged App, physical 1×/2× displays, multiple displays, or macOS 14–15/26 runtime behavior.

UI Next 的 Debug/测试夹具会在不可交互的离屏宿主中真实完成 SwiftUI/AppKit 位图渲染，并覆盖控制中心、About、MenuBarExtra、七种桌宠状态及规格要求的代表性矩阵。夹具使用不可达 PetCore socket、关闭整棵视图的点击，并以任务作用域切换语言；它不能替代打包 App、真实显示器、多屏与各 macOS 版本上的 Computer Use 可见验收。
