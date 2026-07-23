# Validation Profiles / 验证层级

This document defines what each validation layer can prove. A listed command is not evidence that the current commit passed; use fresh command output, CI artifacts, or GitHub Release notes for the exact commit and artifact.

本文只定义各层验证能证明什么。命令出现在表中不代表当前提交已经通过；具体结论必须来自对应 commit 与产物的新鲜命令输出、CI artifact 或 GitHub Release notes。

| Profile / 层级 | Main entrypoints / 主要入口 | Proves / 能证明 | Does not prove / 不能证明 |
|---|---|---|---|
| `fast/core` | `cargo fmt --all -- --check`, strict workspace Clippy, `cargo test --workspace --locked`, `validate_swift_tests.sh`, schema validators, `validate_overlay_offline.sh`, `validate_security_boundaries.sh` | Rust formatting/lints, deterministic Rust, PetCore, CLI, schema, Swift-core, UI-model, overlay, renderer-budget, and bounded diagnostic filtering. / Rust 格式与 lint、确定性核心逻辑、UI 模型、悬浮层及有界诊断过滤。 | Visible macOS UI, real third-party Agents, or real Codex App Server generation. / 不代表真实 UI、Agent 或 App Server。 |
| `simulated integration` | `validate_portable_pet_maker.sh`, `validate_connectors_runtime.sh` | Integration behavior in isolated `APC_HOME`/`APC_AGENT_CONFIG_HOME`, portable pet creation/editing, generated connector artifacts, event normalization, filtering, and library flows. / 隔离目录中的便携宠物制作、连接器与数据流。 | User Agent trust/authentication, real model/tool execution, or visible overlay acceptance. / 不代表用户真实 Agent 与可见悬浮层。 |
| `macos runtime` | `build_and_run.sh --verify`, `validate_app_bundle.sh`, overlay/main-window/renderer/recovery validators | The exact packaged App, bundled runtime, window/overlay structure, interaction, persistence, rendering telemetry, and recovery exercised by the commands that ran. Live UI work uses Computer Use first. / 实际运行到的打包 App 与 macOS UI 行为。 | Real Agent/provider behavior, full Instruments profiling, or safety of an unapproved direct-input fallback. / 不代表真实 Agent、完整性能分析或未授权输入自动化。 |
| `real agent connectors` | `validate_real_agent_connectors.sh` | Current managed connector commands can emit diagnostic events through the running local runtime without reading credentials. / 当前真实连接器本地事件链路。 | Provider authentication, real model execution, or a complete user task. / 不代表认证、模型执行或完整任务。 |
| `real app server` | `validate_real_app_server.sh` | A real Codex App Server session through PetCore, including strict full-source generation, validation, build, import, and activation when required. / 真实 App Server 制作链路。 | Visible packaged-App interaction and rendering of the same artifact; those remain macOS runtime acceptance. / 不代表同一产物的可见 UI 与渲染验收。 |
| `perf/nightly` | `validate_event_storm.sh`, renderer budget assertions, external profiling | Bounded event-storm and budget regressions; expanded runs may add Instruments. / 事件风暴与预算回归。 | Full CPU/GPU conclusions unless the matching profiler evidence was actually captured. / 未实际采集时不代表完整 CPU/GPU 结论。 |
| `public distribution` | `build_release.sh --public --arch all`, `validate_public_release_artifacts.sh --directory … --version … --build … --commit …` | Exact five-file inventory, four-entry checksum inventory, pre-extraction ZIP safety, expected commit/build identity across both archives, every Mach-O's exact thin architecture, Developer ID authority and Team ID, hardened runtime, designated requirements, minimal entitlements, accepted notarization, stapling, Gatekeeper, packaged runtime identity, and download equality for the artifacts actually processed. / 实际处理产物的五文件清单、四项校验和、解压前 ZIP 安全、双架构 commit/build 身份、所有 Mach-O 精确 thin 架构、Developer ID、Hardened Runtime、公证、staple、Gatekeeper、运行时身份与下载摘要一致性。 | A release that was not downloaded and checked, a skipped Apple service, missing native arm64 or x86_64 packaged-functional evidence, a different commit/artifact, or visible behavior on an untested physical Mac. / 不代表未下载复验、跳过 Apple 服务、缺失原生双架构功能证据、其他 commit/产物或未验收物理 Mac 上的可见行为。 |

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
- `APC_VALIDATE_REAL_AGENT_CONNECTORS=0|1` controls access to current user connector files and installed Agent CLIs. Only `1` opts into the real check; it never authorizes reading credential stores.
- `APC_VALIDATE_REAL_APP_SERVER=0|1` controls a real App Server session. Only `1` opts into the real check. `APC_REQUIRE_EXTERNAL_SKILL_SOURCE=1` is the strict release path; setting it to `0` explicitly downgrades the proof.
- `APC_VALIDATE_OVERLAY_INTERACTION=1` enables the direct-input technical gate but is not user authorization to take over input.
- `APC_EVENT_STORM_COUNT` changes the bounded stress size; the default is `180`.

Recommended expanded commands:

```bash
APC_VALIDATE_REAL_AGENT_CONNECTORS=1 ./script/validate_real_agent_connectors.sh
APC_VALIDATE_REAL_APP_SERVER=1 ./script/validate_real_app_server.sh
APC_EVENT_STORM_COUNT=1000 ./script/validate_event_storm.sh
```

Run only the gates whose environment and authorization are present. Report skipped gates as skipped, never as passed.

Supported public distribution is fail-closed and requires an externally
provisioned Developer ID identity, Team ID, and `notarytool` keychain profile.
Without them, `build_release.sh --public` exits unavailable and never emits a
preview under a public filename. Use `build_release.sh --preview` explicitly
for an ad-hoc development artifact. The offline fake-command test in
`validate_build_scripts_safety.sh` proves command ordering and failure closure;
malicious-ZIP, identity-mismatch, extra-Mach-O, exact-inventory, and mode tests
prove those static boundaries. None of these offline tests proves a real Apple
signature, notarization, Gatekeeper result, or native packaged execution.

受支持公开分发采用失败闭锁，要求外部配置 Developer ID identity、Team ID 与
`notarytool` Keychain profile。缺少配置时 `--public` 会明确以 unavailable 退出，
不会用公开文件名生成预览包；ad-hoc 开发产物必须显式使用 `--preview`。构建安全
校验中的离线假命令、恶意 ZIP、身份错配、额外 Mach-O、精确清单与模式冲突测试
只证明静态边界，不代表真实 Apple 签名、公证、Gatekeeper 或原生包内执行。

Public mode accepts only `--arch all`; `--preview` and `--public` are mutually
exclusive, and the former `--release` validation alias is unsupported. Public
App validation verifies Developer ID, hardened runtime, staple, and Gatekeeper
before invoking the packaged App, PetCore, or CLI.

Release CI imports signing and notarization credentials from the protected
`public-release` environment into an ephemeral Keychain only after the
host-safe source gate, then deletes the Keychain and temporary credential files
with an `always()` cleanup. Separate private-key-free GitHub-hosted
`macos-15` arm64 and `macos-15-intel` x86_64 jobs assert their native
architecture and run packaged-functional acceptance; a clean hosted job
downloads and publishes only after both pass. Every download compares five
signing-job digests before ZIP inspection or extraction. An unavailable or
mismatched native job leaves publication incomplete rather than converting an
unrun gate into a pass.

发布 CI 只在 host-safe 源码门禁通过后，才从受保护的 `public-release`
environment 将签名与公证凭据导入临时 Keychain，并通过 `always()` 清理 Keychain
与临时凭据文件。之后由不接触私钥的 GitHub 托管 `macos-15` arm64 与
`macos-15-intel` x86_64 任务断言原生架构并执行包内功能验收；两者都通过后，干净的
托管任务才可下载并发布。任一原生任务不可用或架构不匹配，都保持发布未完成。

## Product-refactor acceptance / 产品重构验收

The [product refactor execution](product-refactor-execution.md) defines task-level acceptance without claiming that the current commit has passed. Use the existing profiles as follows:

| Product area / 产品区域 | Minimum deterministic proof / 最小确定性证明 | Additional acceptance / 补充验收 |
|---|---|---|
| Presentation models and presets | Swift unit/UI-model tests, localization consistency | Long English/Chinese copy at supported widths |
| Session identity/navigation | Rust projection/database/RPC tests, schema/security fixtures, Swift decoding tests | Real-host navigation only through the explicit connector gate |
| Desktop bubbles and pet interaction | Offline overlay validation and interaction model tests | Packaged visible UI with Computer Use first |
| Library, Maker, Configuration, Connections, Diagnostics | Focused Swift/Rust tests plus `fast/core` | Packaged main-window acceptance; real App Server only when explicitly enabled |
| First-run demo | Fresh isolated home and negative proof that demo data never enters PetCore events/diagnostics | Packaged visible UI with Computer Use first |
| Performance and event pressure | Renderer budget and event-storm gates | Instruments or external profiling only when actually captured |
| Supported public distribution | Offline pipeline-order/failure tests plus exact final archive/signature/package/checksum validation | Externally provisioned Developer ID signing, accepted notarization, staple validation, Gatekeeper, GitHub Release download revalidation, and clean-machine launch |

Do not paste results into the task document or this file. Attach exact evidence to the matching commit, pull request, CI artifact, or GitHub Release.
