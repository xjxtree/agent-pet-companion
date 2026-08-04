# Validation Profiles / 验证层级

This document defines what each validation layer can prove. A listed command is not evidence that the current commit passed; use fresh command output, CI artifacts, or GitHub Release notes for the exact commit and artifact.

本文只定义各层验证能证明什么。命令出现在表中不代表当前提交已经通过；具体结论必须来自对应 commit 与产物的新鲜命令输出、CI artifact 或 GitHub Release notes。

| Profile / 层级 | Main entrypoints / 主要入口 | Proves / 能证明 | Does not prove / 不能证明 |
|---|---|---|---|
| `fast/core` | `cargo fmt --all -- --check`, strict workspace Clippy, `cargo test --workspace --locked`, `validate_swift_tests.sh`, schema validators, `validate_overlay_offline.sh`, `validate_overlay_interaction.sh`, `validate_security_boundaries.sh` | Rust formatting/lints, deterministic Rust, PetCore, CLI, schema, Swift-core, UI-model, and the five native overlay interaction suites bound to the current interaction-contract source digest. / Rust 格式与 lint、确定性核心逻辑、UI 模型，以及绑定当前交互源码摘要的五个原生悬浮层测试套件。 | Visible macOS UI, real pointer acceptance, real third-party Agents, or real Codex App Server generation. / 不代表真实可见 UI、真实指针验收、Agent 或 App Server。 |
| `simulated integration` | `validate_portable_pet_maker.sh`, `validate_connectors_runtime.sh` | Integration behavior in isolated `APC_HOME`/`APC_AGENT_CONFIG_HOME`, portable V3 creation/editing, deterministic flat-background matting and fail-safe key-conflict behavior, source-resolution transparent masters, one premultiplied-Alpha runtime downscale for all three tiers, multi-background QA, actual-duration per-action `authored_timing` previews, the 8–12 second all-action-bound presence preview and premature-static/mechanical-loop rejection, timing-digest freshness, synthetic crossfade/interpolation rejection, frame-bound review freshness, generated connector artifacts, event normalization, filtering, and library flows. / 隔离目录中的 V3 九动作便携宠物制作、确定性的纯色背景抠图与底色冲突安全失败、来源分辨率透明母版、三档画质的单次预乘 Alpha 运行尺寸缩放、多背景 QA、按各动作逐帧时长渲染的 `authored_timing` 预览、绑定全部动作的 8–12 秒存在感预览及过早静止/机械循环拒绝、时序摘要新鲜度、合成叠化/插值拒绝、与帧绑定的复核、连接器与数据流。 | Artistic quality from a real model, user Agent trust/authentication, real model/tool execution, or visible overlay acceptance. / 不代表真实模型的艺术质量、用户真实 Agent 与可见悬浮层。 |
| `macos runtime` | `build_and_run.sh --verify`, `validate_app_bundle.sh`, overlay/main-window/renderer/recovery validators | The exact packaged App, bundled runtime, clean-home three-pet seed, canonical covers and nine-action runtime-frame inventories, semantic burst settling, local acknowledge/drag interactions, window/overlay structure, persistence, rendering telemetry, and recovery exercised by the commands that ran. Live UI work uses Computer Use first. / 实际运行到的打包 App、干净目录中的三只内置宠物、规范封面与九动作运行帧、语义动作收束和本地点击/拖动交互，以及命令覆盖的 macOS UI、持久化、渲染遥测与恢复行为。 | Real Agent/provider behavior, full Instruments profiling, or safety of an unapproved direct-input fallback. / 不代表真实 Agent、完整性能分析或未授权输入自动化。 |
| `real agent connectors` | `validate_real_agent_connectors.sh` | Current managed connector commands can emit diagnostic events through the running local runtime without reading credentials. / 当前真实连接器本地事件链路。 | Provider authentication, real model execution, or a complete user task. / 不代表认证、模型执行或完整任务。 |
| `real app server` | `validate_real_app_server.sh` | A real Codex App Server session through PetCore, including canonical identity/action direction, strict full-source generation, current frame-bound motion QA/review, validation, build, import, and activation when required. / 真实 App Server 制作链路，包括规范身份/动作导演、与当前帧绑定的动作 QA/复核、校验、构建、导入与按需启用。 | Visible packaged-App interaction and rendering of the same artifact; those remain macOS runtime acceptance. / 不代表同一产物的可见 UI 与渲染验收。 |
| `perf/nightly` | `validate_event_storm.sh`, renderer budget assertions, external profiling | Bounded event-storm and budget regressions; expanded runs may add Instruments. / 事件风暴与预算回归。 | Full CPU/GPU conclusions unless the matching profiler evidence was actually captured. / 未实际采集时不代表完整 CPU/GPU 结论。 |
| `GitHub Release distribution` | `build_release.sh --github-release --arch all`, `validate_github_release_artifacts.sh --directory … --version … --build … --commit …`, `validate_github_release_api.py …` | Exact three-file inventory, two-entry checksum inventory, pre-extraction ZIP safety, full commit/build/runtime identity across both archives, strict ad-hoc signature integrity, every Mach-O's exact thin architecture, native packaged-functional validation, download equality, and a published latest stable GitHub API projection with the same asset digests. / 实际处理产物的三文件清单、两项校验和、解压前 ZIP 安全、双归档完整 commit/build/runtime 身份、严格 ad-hoc 签名完整性、所有 Mach-O 精确 thin 架构、原生包内功能验收、下载摘要一致性，以及具有相同资产摘要、已公开的 latest stable GitHub API 投影。 | Developer identity, Apple notarization, stapling, default Gatekeeper acceptance, GitHub Release immutability, a release that was not downloaded and checked, a different commit/artifact, or visible behavior on an untested physical Mac. / 不代表开发者身份、Apple 公证、stapling、默认 Gatekeeper 接受、GitHub Release 不可变性、未下载复验的 Release、其他 commit/产物或未验收物理 Mac 上的可见行为。 |

## Source-resolution producer qualification / 来源分辨率制作能力核验

V3 package/runtime support and a particular image producer's capacity are
separate contracts. V3 accepts `low` 192×208, `standard` 384×416, and `high`
576×624, but every producer must prove decoded source-crop capacity rather
than relying on the requested image size or a resized final PNG. The returned
sheet may use different dimensions; a complete 12:13 crop at or above the
target is accepted and then downscaled once by the shared pipeline. On 2026-07-31,
the ChatGPT/Codex built-in image-generation path was measured with the
repository's half-scale round-trip probe against a 576×624 target cell:

V3 宠物包/运行时支持与具体生图工具的能力是两份独立契约。V3 接受 `low`
192×208、`standard` 384×416 与 `high` 576×624，但每个制作方都必须证明真实解码后的
来源裁片容量，不能只依赖请求尺寸或缩放后的最终 PNG。生图整图尺寸可以不同；只要
每帧都能取得不小于目标的完整 12:13 裁片，就可以交由共享流水线一次缩小。2026-07-31 使用仓库中的
半尺度往返损失探针，对 ChatGPT/Codex 内置生图链路的 576×624 目标单格完成了以下核验：

| Load / 负载 | Decoded 4×2 sheet / 4×2 解码整图 | Effective cell / 实际单格 | Probe result / 结果 |
|---|---:|---:|---|
| Diagnostic 1 px grid, parallel lines, and small numerals / 诊断用 1 px 网格、平行线与小号数字 | 1704×923 | 426×461 | `REJECT` |
| Representative eight-frame Bytebud action / Bytebud 真实八帧动作 | 1536×1024 | 384×512 | `REJECT` |

Both decoded sheets were below the required 576×624 source crop and failed the
probe. Therefore ChatGPT/Codex built-in `imagegen` and the App's Codex-backed
Studio are qualified only for `low` and `standard`; they reject `high` before
generation rather than spending attempts and falling back. The portable Maker
may build `high` with another provider or user-supplied production source only
after that path proves at least 576×624 source crops. Upscaling, padding a smaller crop,
super-resolution, or splitting a state across multiple batches cannot
substitute for missing source pixels. A newly used high-capacity path
must run both a diagnostic grid and a representative eight-frame action before
production.

两张整图解码后的单格都小于 576×624 来源裁片要求，且探针均判定为 `REJECT`。因此
ChatGPT/Codex 内置 `imagegen` 与 App 内基于 Codex 的 Studio 只具备 `low` 和
`standard` 制作能力，并会在生图前拒绝 `high`，避免消耗无意义的尝试或静默降级。
通用 Maker 只有在其他提供方或用户提供的生产来源证明具备至少 576×624 裁片后，
才可制作 `high`。放大、给小图补边、超分辨率或将一个状态拆成多批次，都不能替代
缺失的来源像素容量；首次使用新的高分辨率链路前，必须同时运行诊断网格与真实八帧动作。

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
`OverlayGeometryTests`, `OverlayDisplayWidthTests`, and
`OverlayInteractionTelemetryTests` suites pass. The
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
./script/validate_overlay_performance_summary.sh /absolute/summary.json 60
```

An opt-in Release validation launch may set the absolute
`APC_OVERLAY_PERFORMANCE_SUMMARY_PATH`; after at least one completed drag, the
summary validator checks closed aggregate fields, event-to-window p95/p99
against the supplied refresh rate, main-thread handler p95/p99, a sub-1%
missed-display-link ratio, and the five-attempt persistence ceiling. The file
contains no raw signpost rows or product/user identifiers. Capture 60 Hz and
any available 120 Hz display separately; unavailable refresh rates must be
reported as not covered rather than inferred from synthetic tests.

在 Release 验证启动中可显式设置绝对路径
`APC_OVERLAY_PERFORMANCE_SUMMARY_PATH`。至少完成一次拖动后，摘要校验器会检查
闭合聚合字段、相对指定刷新率的 event-to-window p95/p99、主线程处理 p95/p99、
低于 1% 的 display-link 丢失比例，以及最多五次的持久化尝试。文件不包含原始
signpost 行或任何产品/用户标识。60 Hz 与可用的 120 Hz 屏幕必须分别采集；缺少的
刷新率应明确标记为未覆盖，不能用合成测试代替。

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
`plugin.json` version for any content change. It also validates the structured
retired Studio Skill history, requires the base Skill's exact SHA-256 whenever
Studio changes, keeps prior history entries append-only, rejects unrelated new
ownership digests, and forbids listing the current Skill as retired. It proves
source/version and upgrade-ownership discipline, not that a particular user's
active Codex cache already converged; that requires the connector runtime
tests.

该门禁将 `plugins/codex`、`skills/agent-pet-studio` 与
`skills/agent-pet-maker` 和基线比较；任意内容变化都要求 `plugin.json` 版本严格
增加。它还会校验结构化的 Studio Skill 历史清单：Studio 发生变化时必须保存基线
Skill 的精确 SHA-256，已有摘要只能追加不能删除，不得加入无关所有权摘要，也不得把
当前 Skill 标记为历史内容。它证明源码、版本及升级所有权纪律，不代表某位用户的
Codex 活跃缓存已经收敛；后者必须由连接器运行时测试证明。

Do not paste results into this file. Attach exact evidence to the matching
commit, pull request, CI artifact, or GitHub Release.
