# Validation Profiles / 验证层级

This document defines what each validation layer can prove. A listed command is not evidence that the current commit passed; use fresh command output, CI artifacts, or GitHub Release notes for the exact commit and artifact.

本文只定义各层验证能证明什么。命令出现在表中不代表当前提交已经通过；具体结论必须来自对应 commit 与产物的新鲜命令输出、CI artifact 或 GitHub Release notes。

| Profile / 层级 | Main entrypoints / 主要入口 | Proves / 能证明 | Does not prove / 不能证明 |
|---|---|---|---|
| `fast/core` | `cargo fmt --all -- --check`, strict workspace Clippy, `cargo test --workspace --locked`, `validate_swift_tests.sh`, schema validators, `validate_overlay_offline.sh`, `validate_overlay_interaction.sh`, `validate_security_boundaries.sh` | Rust formatting/lints, deterministic Rust, PetCore, CLI, schema, Swift-core, UI-model, and the four native overlay interaction suites bound to the current interaction-contract source digest. / Rust 格式与 lint、确定性核心逻辑、UI 模型，以及绑定当前交互源码摘要的四个原生悬浮层测试套件。 | Visible macOS UI, real pointer acceptance, real third-party Agents, or real Codex App Server generation. / 不代表真实可见 UI、真实指针验收、Agent 或 App Server。 |
| `simulated integration` | `validate_portable_pet_maker.sh`, `validate_connectors_runtime.sh` | Integration behavior in isolated `APC_HOME`/`APC_AGENT_CONFIG_HOME`, portable V2 creation/editing, exact native-size keyframes, actual-duration per-state `authored_timing` previews and timing-digest freshness, synthetic crossfade/interpolation rejection, frame-bound review freshness, generated connector artifacts, event normalization, filtering, and library flows. / 隔离目录中的 V2 便携宠物制作、精确原生尺寸关键帧、按各状态逐帧时长渲染的 `authored_timing` 预览与时序摘要新鲜度、合成叠化/插值拒绝、与帧绑定的复核、连接器与数据流。 | Artistic quality from a real model, user Agent trust/authentication, real model/tool execution, or visible overlay acceptance. / 不代表真实模型的艺术质量、用户真实 Agent 与可见悬浮层。 |
| `macos runtime` | `build_and_run.sh --verify`, `validate_app_bundle.sh`, overlay/main-window/renderer/recovery validators | The exact packaged App, bundled runtime, clean-home two-pet seed, canonical covers and seven-state runtime-frame inventories, window/overlay structure, interaction, persistence, rendering telemetry, and recovery exercised by the commands that ran. Live UI work uses Computer Use first. / 实际运行到的打包 App、干净目录中的两只内置宠物、规范封面与七状态运行帧，以及命令覆盖的 macOS UI、持久化、渲染遥测与恢复行为。 | Real Agent/provider behavior, full Instruments profiling, or safety of an unapproved direct-input fallback. / 不代表真实 Agent、完整性能分析或未授权输入自动化。 |
| `real agent connectors` | `validate_real_agent_connectors.sh` | Current managed connector commands can emit diagnostic events through the running local runtime without reading credentials. / 当前真实连接器本地事件链路。 | Provider authentication, real model execution, or a complete user task. / 不代表认证、模型执行或完整任务。 |
| `real app server` | `validate_real_app_server.sh` | A real Codex App Server session through PetCore, including canonical identity/action direction, strict full-source generation, current frame-bound motion QA/review, validation, build, import, and activation when required. / 真实 App Server 制作链路，包括规范身份/动作导演、与当前帧绑定的动作 QA/复核、校验、构建、导入与按需启用。 | Visible packaged-App interaction and rendering of the same artifact; those remain macOS runtime acceptance. / 不代表同一产物的可见 UI 与渲染验收。 |
| `perf/nightly` | `validate_event_storm.sh`, renderer budget assertions, external profiling | Bounded event-storm and budget regressions; expanded runs may add Instruments. / 事件风暴与预算回归。 | Full CPU/GPU conclusions unless the matching profiler evidence was actually captured. / 未实际采集时不代表完整 CPU/GPU 结论。 |
| `GitHub Release distribution` | `build_release.sh --github-release --arch all`, `validate_github_release_artifacts.sh --directory … --version … --build … --commit …`, `validate_github_release_api.py …` | Exact three-file inventory, two-entry checksum inventory, pre-extraction ZIP safety, full commit/build/runtime identity across both archives, strict ad-hoc signature integrity, every Mach-O's exact thin architecture, native packaged-functional validation, download equality, and a published latest stable GitHub API projection with the same asset digests. / 实际处理产物的三文件清单、两项校验和、解压前 ZIP 安全、双归档完整 commit/build/runtime 身份、严格 ad-hoc 签名完整性、所有 Mach-O 精确 thin 架构、原生包内功能验收、下载摘要一致性，以及具有相同资产摘要、已公开的 latest stable GitHub API 投影。 | Developer identity, Apple notarization, stapling, default Gatekeeper acceptance, GitHub Release immutability, a release that was not downloaded and checked, a different commit/artifact, or visible behavior on an untested physical Mac. / 不代表开发者身份、Apple 公证、stapling、默认 Gatekeeper 接受、GitHub Release 不可变性、未下载复验的 Release、其他 commit/产物或未验收物理 Mac 上的可见行为。 |

## Native-resolution tier qualification / 原生分辨率档位核验

The current V2 quality contract is based on decoded source capacity, not the
requested image size or a resized final PNG. On 2026-07-31, the current image
generation path was qualified with the repository's half-scale round-trip
probe against a 576×624 target cell:

当前 V2 画质契约依据真实解码后的来源容量，而不是请求尺寸或缩放后的最终 PNG。
2026-07-31 使用仓库中的半尺度往返损失探针，对当前图像生成链路的 576×624 目标单格
完成了以下核验：

| Load / 负载 | Decoded 4×2 sheet / 4×2 解码整图 | Effective cell / 实际单格 | Probe result / 结果 |
|---|---:|---:|---|
| Diagnostic 1 px grid, parallel lines, and small numerals / 诊断用 1 px 网格、平行线与小号数字 | 1704×923 | 426×461 | `REJECT` |
| Representative eight-frame Bytebud action / Bytebud 真实八帧动作 | 1536×1024 | 384×512 | `REJECT` |

Both decoded sheets were below the required 576×624 native cell and failed the
probe. V2 therefore exposes only `low` 192×208 and `standard` 384×416;
`standard` is the default and largest qualified tier. Upscaling, padding a
smaller crop, super-resolution, or splitting a state across multiple batches
cannot substitute for missing native single-batch capacity. A provider or
generation-path change must rerun both a diagnostic grid and a representative
eight-frame action before a larger tier can be proposed, and that result
requires a coordinated schema, runtime, producer, fixture, and documentation
revision.

两张整图解码后的单格都小于 576×624 原生要求，且探针均判定为 `REJECT`。因此 V2
只提供 `low` 192×208 与 `standard` 384×416；`standard` 是默认且最大的已核验档位。
放大、给小图补边、超分辨率或将一个状态拆成多批次，都不能替代缺失的单批次原生容量。
更换提供方或生成链路后，如需提议更大档位，必须同时重跑诊断网格与真实八帧动作，
并同步修订 schema、运行时、制作器、fixture 与文档契约。

## Default host-safe gate / 默认宿主安全门禁

```bash
APC_VALIDATE_HOST_UI=0 \
APC_VALIDATE_REAL_AGENT_CONNECTORS=0 \
APC_VALIDATE_REAL_APP_SERVER=0 \
./script/test_all.sh
```

The default/simulated gate must use isolated homes and must not launch the GUI, mutate user LaunchAgents, invoke real Agents, or read credentials. Run component commands directly when narrowing a failure; the release gate remains the complete set documented in [macOS release procedure](../release/macos-release.md).

默认与模拟门禁必须使用隔离 home，不启动 GUI、不修改用户 LaunchAgent、不调用真实 Agent，也不读取凭据。定位失败时可单独运行组件命令；正式发布仍以 [macOS 发布流程](../release/macos-release.md)中的完整门禁为准。

## Explicit runtime gates / 显式真实运行时门禁

- `APC_VALIDATE_HOST_UI=0|1` controls packaged macOS runtime validation. Live UI verification must use Computer Use first; any fallback that can launch or activate an App, move input, or steal focus requires explicit user approval immediately before use.
- `APC_VALIDATE_REAL_AGENT_CONNECTORS=0|1` controls access to current user connector files and installed Agent CLIs. Only `1` opts into the real check; it never authorizes reading credential stores.
- `APC_VALIDATE_REAL_APP_SERVER=0|1` controls a real App Server session. Only `1` opts into the real check. `APC_REQUIRE_EXTERNAL_SKILL_SOURCE=1` is the strict release path; setting it to `0` explicitly downgrades the proof. Strict generation may use an initial turn plus five same-thread checkpoint continuations, each bounded to 25 minutes and preserving already-passed state rows. The default acceptance window is 155 minutes; `APC_REAL_APP_SERVER_POLL_SECONDS` and `APC_REAL_APP_SERVER_POLL_COUNT` may lengthen that window but may not shorten it below 155 minutes. When `APC_REAL_APP_SERVER_ARTIFACT_DIR` is set, the validator writes rolling isolated-job/status checkpoints (every 600 polls by default, configurable with positive `APC_REAL_APP_SERVER_ARTIFACT_CHECKPOINT_EVERY`) and preserves the final job/status on both success and failure.
- `APC_EVENT_STORM_COUNT` changes the bounded stress size; the default is `180`.

Deterministic overlay interaction contracts run unconditionally inside
`test_all.sh`. `validate_overlay_interaction.sh` emits
`apc.overlay-interaction-attestation.v1` only after the exact
`OverlayPlacementAuthorityTests`, `AppStoreOverlaySnapshotTests`,
`OverlayGeometryTests`, and `OverlayDisplayWidthTests` suites pass. The
attestation binds the build ID, the closed suite inventory, and the digest of
the fixed sorted interaction-contract file list; portable production
verification rejects a missing, stale, incomplete, or unknown-field result.
Real pointer, focus, Space, and window-lifecycle checks are a
separate Computer Use acceptance step; no environment variable is treated as
authorization to take over input.

确定性的浮层交互契约会由 `test_all.sh` 无条件执行。真实指针、失焦、Space
与窗口生命周期检查单独使用 Computer Use 验收；任何环境变量都不代表接管输入的授权。

Recommended expanded commands:

```bash
APC_VALIDATE_REAL_AGENT_CONNECTORS=1 ./script/validate_real_agent_connectors.sh
APC_VALIDATE_REAL_APP_SERVER=1 ./script/validate_real_app_server.sh
APC_EVENT_STORM_COUNT=1000 ./script/validate_event_storm.sh
```

Run only the gates whose environment and authorization are present. Report skipped gates as skipped, never as passed.

In this document, GitHub Release distribution means the architecture-specific
ZIP downloads published as Agent Pet Companion V1's only official channel.
Official archives are ad-hoc signed. No Apple account, Developer ID identity,
notarization profile, protected release environment, release Variable, or
release Secret is part of this gate. The validation therefore proves code
integrity, identity, architecture, and packaging—not publisher identity,
notarization, stapling, or default Gatekeeper acceptance.

本文所说的 GitHub Release 分发，是 Agent Pet Companion V1 唯一正式渠道中的分架构
ZIP。正式归档采用 ad-hoc 签名；门禁不需要 Apple 账户、Developer ID identity、
公证 profile、受保护 release environment、Variables 或 Secrets。因此它证明的是
代码完整性、发布身份、架构与打包契约，不证明发布者身份、Apple 公证、stapling 或
默认 Gatekeeper 接受。

Official mode is explicit and fail-closed:
`build_release.sh --github-release --arch all` is the only supported release
invocation. Development Apps and handoff archives use
`build_app_bundle.sh [--archive]`; they cannot be renamed into official
artifacts. Offline malicious-ZIP, full-commit identity, unexpected-Mach-O,
exact-inventory, checksum, and mode tests prove those static boundaries. They
do not replace native packaged execution or downloaded-asset validation.

正式模式必须显式运行 `build_release.sh --github-release --arch all`，且只接受
双架构一起构建。开发 App 与交接归档由 `build_app_bundle.sh [--archive]` 生成，
不能通过改名替代正式产物。恶意 ZIP、完整 commit 身份、额外 Mach-O、精确清单、
校验和与模式测试证明静态边界，但不能替代原生包内运行和 Release 下载后复验。

Release CI uses GitHub-hosted `macos-15` arm64 and `macos-15-intel` x86_64
jobs to assert native architecture and run packaged-functional acceptance. A
clean publish job downloads the exact three assets only after both pass. Every
download compares three trusted build-job digests before ZIP inspection or
extraction, then revalidates the complete three-file/two-checksum-entry set. An
unavailable or mismatched native job leaves publication incomplete. After
publishing the draft, the final gate reads both the tag Release and
`/releases/latest`, requires `draft == false` and `prerelease == false`, and
matches all three API asset digests to the trusted build outputs. GitHub
Release immutability is intentionally outside this gate.

发布 CI 使用 GitHub 托管 `macos-15` arm64 与 `macos-15-intel` x86_64 任务断言
原生架构并执行包内功能验收。两者通过后，干净的发布任务才会下载恰好三个资产；
每次下载都先比对构建任务记录的三个可信摘要，再检查 ZIP 并完整复验三文件、两行
校验和清单。任一原生任务不可用或架构不匹配，发布保持未完成。

发布草稿公开后，最终门禁同时读取对应 tag Release 与 `/releases/latest`，要求
`draft == false`、`prerelease == false`，并将 API 返回的三个资产摘要与构建任务
可信摘要逐项比对。GitHub Release 不可变性不属于本门禁。

Codex plugin content/version validation is a separate deterministic release
gate:

```bash
./script/validate_codex_plugin_version.py --base-ref BASE_COMMIT_OR_TAG
```

It compares `plugins/codex`, `skills/agent-pet-studio`, and
`skills/agent-pet-maker` with the base and requires a strictly greater
`plugin.json` version for any content change. It proves source/version
discipline, not that a particular user's active Codex cache already converged;
that requires the connector runtime tests.

该门禁将 `plugins/codex`、`skills/agent-pet-studio` 与
`skills/agent-pet-maker` 和基线比较；任意内容变化都要求 `plugin.json` 版本严格
增加。它证明源码与版本纪律，不代表某位用户的 Codex 活跃缓存已经收敛；后者必须由
连接器运行时测试证明。

Do not paste results into this file. Attach exact evidence to the matching
commit, pull request, CI artifact, or GitHub Release.
