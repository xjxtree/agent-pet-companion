# Agent Pet Companion 全面项目审查报告

> **历史快照：** 本报告只描述 2026-07-10 当时的工作区与验证结果。2026-07-14 之后的实现、当前门禁红项和发布阻塞项请查看[当前项目状态](../../PROJECT_STATUS.md)；本文中的通过数量不得作为当前候选构建证据。

> 审查日期：2026-07-10
> 审查基线：当前工作区（包含用户已有、尚未提交的实现）
> 产品基线：`AgentPetCompanion_ProductPlan_V5.md`
> 技术基线：`AgentPetCompanion_TechnicalPlan_V1_1.md`

## 1. 执行摘要

项目已经形成可运行的 V1 纵向切片：macOS SwiftUI/AppKit/Metal 客户端、Rust PetCore、UDS JSON-RPC、SQLite、`.petpack`、AI 生成会话、桌面悬浮宠物和四类 Agent 连接都有实际代码及验证脚本。主导航、Pet Studio 双页签、固定状态集合、12/20 FPS、悬浮窗缩放柄等关键产品约束总体保持一致。

审查与修复期共登记 **54 个确认问题**（P1 17、P2 28、P3 9）和 **12 个结构性优化项**。问题覆盖 Pet 资源与数据库事务、daemon 唯一性、事件隐私与幂等、App Server 断流、生成恢复、主线程渲染、Overlay 可访问性、Agent 官方契约、默认测试隔离、交付工程与真实性能验收。第 54 项是在首轮实机回归中新增确认的性能口径缺陷。

截至本轮结束，账本状态为 **48 `FIXED`、6 `MITIGATED`、0 `OPEN`、0 `DEFERRED`**。6 个 `MITIGATED` 都只剩真实第三方 Agent 或真实 Codex App Server 的外部授权验收；本地实现、官方形状 fixture、契约门禁和失败降级均已完成。审查没有读取认证、token、cookie 或 secret 文件，也没有改写用户真实 Agent 配置。

## 2. 审查范围与方法

### 2.1 已覆盖范围

- 全量阅读 Rust workspace：`petcore`、`petcore-cli`、`petcore-types` 与集成测试。
- 全量阅读 macOS Swift/SwiftUI/AppKit/Metal 代码、模型和验证 target。
- 检查 JSON Schema、Shell/Python 辅助脚本、Agent 模板、Pet Studio Skill、README 与设计/实现计划。
- 对运行中的应用执行真实界面巡检，覆盖 Pet Studio、Pet Library、Enable & Behavior、Agent Connections、AI 历史会话、悬浮宠物折叠和放大状态。
- 运行格式、编译、单元/集成、隔离端到端、安全边界、事件风暴和 app bundle 验证。
- 对会随时间变化的 Agent 集成接口使用当前官方文档交叉核验。

### 2.2 审查限制

- 工作区在审查开始前已有大量未提交改动；本报告按当前快照审查，不把这些改动归因于本次审查，也不覆盖或回退用户改动。
- Codex Security 插件的强制预检因运行时并发槽/配置元数据不满足而返回 `incomplete`，因此**不能声称完成了该插件定义的穷尽式安全扫描**。安全结论来自逐文件审查、严格边界测试、RustSec 和运行时验证。
- 未在没有用户明确授权的情况下加载真实 Codex、Claude Code、Pi、OpenCode 配置，也未发起真实 Codex App Server 生成；这些外部验收对应 6 个有界 `MITIGATED`。
- 无法通过静态截图稳定表达 hover/缩放柄显隐瞬间；拖动、键盘/AX 缩放、两种气泡方向、短气泡、跨显示约束和缩放持久化均由宿主实机门禁验证。
- Developer ID 签名、公证与 universal Release 仍需要完整 Xcode 和发布凭据；仓库已提供会在条件不满足时明确失败的发布脚本与文档。

## 3. 验证基线

| 检查 | 结果 | 说明 |
|---|---:|---|
| `bash -n script/*.sh` | PASS | Shell 语法通过 |
| Python AST 编译 | PASS | Pet Studio helper 可解析 |
| `cargo fmt --all -- --check` | PASS | Rust 格式通过 |
| `cargo test --workspace --locked -- --test-threads=1` | PASS | Rust workspace 全量单元、集成、故障注入与文档测试通过 |
| 隔离模式 `script/test_all.sh` | PASS | M0–M6、Schema 正反例、模拟连接、安全、事件风暴、V1、Overlay 离线检查与开发包打包通过 |
| `swift test --enable-swift-testing …` | PASS | 8 个 suite、57 个 Swift Testing 用例通过 |
| `cargo clippy --workspace --all-targets --locked -- -D warnings` | PASS | 无 warning |
| `git diff --check` | PASS | 当前 diff 无空白错误 |
| `cargo audit --deny warnings` | PASS | 159 个依赖、0 个 RustSec 漏洞 |
| 宿主 UI / Overlay / recovery | PASS | 主窗口、上下/短气泡、交互、AX 缩放、持久化和 daemon 恢复均通过 |
| Renderer 30 秒真实采样 | PASS | hidden/high/ultra/original 的 CPU、RSS、FPS、decoded cache、drawable 与 Metal 指标均在预算内 |
| app bundle 验证 | PASS（开发包） | 可运行 arm64 开发包；正式签名/公证由独立发布门禁负责 |

### 3.1 Renderer 最终实测

| 场景 | CPU 平均 | 观察 FPS | Renderer RSS 峰值增量 | 预算 |
|---|---:|---:|---:|---:|
| Overlay 隐藏基线 | 0.10% | — | RSS median 135.38 MiB | 基线 |
| high / standard | 2.50% | 12.00 | 21.08 MiB | CPU ≤ 4%；内存 ≤ 180 MiB；FPS ≥ 10.8 |
| ultra / smooth | 3.27% | 19.99 | 57.69 MiB | CPU ≤ 7%；内存 ≤ 260 MiB；FPS ≥ 18 |
| original / smooth | 3.60% | 20.04 | 247.58 MiB | CPU ≤ 9%；内存 ≤ 420 MiB；FPS ≥ 18 |

采样方法为每档 61 次、0.5 秒间隔，使用累计进程 CPU time delta、重复 `ps` RSS、隐藏基线差值和应用内 decoded/Metal allocation telemetry；draw count、drawable/Metal 分配均为非零，且 `draw_reads_disk=false`。

## 4. 运行界面证据

所有修复版窗口截图均由隔离 `APC_HOME`、真实 app bundle 与真实 AX 导航生成，并扁平化为 RGB PNG。对照图把原始基线与同视口修复版并排后再做视觉判断，不以单张截图代替 QA。

| 场景 | 基线 | 修复版 | 并排对照 |
|---|---|---|---|
| Pet Studio / New（窄） | [baseline](screenshots/01-pet-studio-new.png) | [after](screenshots/after/01-pet-studio-new.png) | [compare](comparisons/01-pet-studio-new-before-after.png) |
| Pet Studio / New（宽） | [baseline](screenshots/02-pet-studio-new-wide.png) | [after](screenshots/after/02-pet-studio-new-wide.png) | [compare](comparisons/02-pet-studio-new-wide-before-after.png) |
| Pet Library | [baseline](screenshots/03-pet-library.png) | [after](screenshots/after/03-pet-library.png) | [compare](comparisons/03-pet-library-before-after.png) |
| Enable & Behavior | [baseline](screenshots/04-enable-behavior.png) | [after](screenshots/after/04-enable-behavior.png) | [compare](comparisons/04-enable-behavior-before-after.png) |
| Agent Connections | [baseline](screenshots/05-agent-connections.png) | [after](screenshots/after/05-agent-connections.png) | [compare](comparisons/05-agent-connections-before-after.png) |
| Overlay 折叠状态 | [baseline](screenshots/06-overlay-collapsed.png) | [after](screenshots/after/06-overlay-collapsed.png) | [compare](comparisons/06-overlay-collapsed-before-after.png) |
| Overlay 放大状态 | [baseline](screenshots/07-overlay-large.png) | [after](screenshots/after/07-overlay-large.png) | [compare](comparisons/07-overlay-large-before-after.png) |
| AI 会话失败/重试 | [baseline history](screenshots/08-ai-session-history.png) | [after retry](screenshots/after/08-ai-session-retry.png) | [compare](comparisons/08-ai-session-before-after.png) |

## 5. 确认问题账本

严重度定义：

- **P1**：会造成数据损坏、隐私泄漏、核心流程不可恢复、宿主环境破坏，或关键能力与产品声明不符。
- **P2**：明显可靠性、性能、兼容性、可访问性或可维护性缺陷，发布前应处理。
- **P3**：低概率边缘情况、文档/一致性/体验债务；仍属于本轮完整修复范围。

### 5.1 P1 — 必须优先修复

#### APC-P1-001 Pet 资源替换与数据库提交不是同一原子操作 — `FIXED`

- 证据：`crates/petcore/src/petpack.rs:718-747,810-836,1167-1207`；CLI 在 `crates/petcore-cli/src/main.rs:347-353` 直接绕过 daemon。
- 问题：资源目录先移动/覆盖，数据库稍后提交，且 daemon 与 CLI 之间没有跨进程锁。崩溃或并发导入会产生“文件是新版本、数据库是旧版本”或互相覆盖。
- 修复方向：单写入者或跨进程写锁；资源 staging、可回滚交换、DB transaction 和恢复日志组成显式提交协议；CLI 默认通过 daemon。
- 完成证据：导入写入独立 immutable revision；DB 故障恢复旧 pointer 并只删新 revision。daemon/显式 offline CLI 共用 store lock，默认 CLI 经 RPC；原子导入 12/12 与 CLI routing 3/3 通过。

#### APC-P1-002 取消已有 Pet 的生成会破坏先前可用资源 — `FIXED`

- 证据：`crates/petcore/src/generation.rs:1547-1615`。
- 问题：为已有 pet 生成新 revision 后取消，旧目录不能可靠恢复，取消操作可能把已安装宠物留在损坏状态。
- 修复方向：revision 独立 staging；只有成功验证后切换 active revision；取消只删除未提交 revision。
- 完成证据：取消按当前 revision 条件恢复旧 DB 行与 active pointer；迟到取消不会覆盖更晚手工导入。原子取消回归及既有 generation lifecycle 取消回归通过。

#### APC-P1-003 第二个 daemon 在确认唯一实例前修改运行任务 — `FIXED`

- 证据：`crates/petcore/src/daemon.rs:20-31`、`rpc.rs:53-57`、`generation.rs:101-112`。
- 问题：新进程先把 running/waiting job 标为中断，再检查 socket 是否已有健康实例；误启动第二实例会破坏第一实例状态。
- 修复方向：先获取唯一实例锁/探测健康 socket，再执行恢复逻辑。

#### APC-P1-004 Agent 原始工具输入、输出和命令被持久化 — `FIXED`

- 证据：`crates/petcore/src/connections.rs:363-380,428-470`、`petcore-cli/src/main.rs:182-208`、`rpc.rs:563-615`、`db.rs:300-319`。
- 问题：denylist 无法覆盖 prompt、命令输出、文件内容、环境变量和凭据变体，违反“只消费明确事件通道，不读取/保存 agent secret”的项目边界。
- 修复方向：默认只接受并存储小型 typed event envelope；payload allowlist + 大小上限 + 递归脱敏；原始正文不落库；已有数据库提供清理迁移。

#### APC-P1-005 外部事件幂等键没有来源/会话命名空间 — `FIXED`

- 证据：`petcore-cli/src/main.rs:194-208,1098-1105`、`rpc.rs:460-465`、`db.rs:95-105,300-320`。
- 问题：不同 Agent 或会话使用相同 event id 时，`INSERT OR IGNORE` 会静默丢掉真实事件。
- 修复方向：唯一键使用 `(source, session_id, external_event_id)`；缺省 id 由 canonical envelope 生成；迁移旧数据。

#### APC-P1-006 App Server stdout 提前断开会自旋至超时 — `FIXED`

- 证据：`crates/petcore/src/app_server.rs:897-929,1387-1409`，默认超时 180 秒。
- 问题：EOF 与“暂时没有消息”处理相同，循环可持续占用 CPU，用户只在最终超时后看到错误。
- 修复方向：EOF 立即判定子进程状态并失败；使用阻塞 channel/async select；增加断流测试。
- 完成证据：stdout channel 现在显式区分 line/timeout/I/O/EOF，初始化与 turn 中途 EOF 都立即返回退出码和有界 stderr；`cargo test -p petcore --test app_server_transport` 通过。

#### APC-P1-007 GUI 启动会反复 `kickstart -k` 健康 daemon — `FIXED`

- 证据：`apps/macos/.../PetCoreProcessManager.swift:37,160,213`、`AgentPetCompanionApp.swift:67`、`AppStore.swift:143`。
- 问题：bootstrap 路径可重复进入，每次强制重启后台服务，打断生成任务和连接状态。
- 修复方向：健康检查优先；仅未运行/不健康时 bootstrap；安装、启动、重启拆成幂等状态机。
- 完成证据：任何启动动作前先健康检查，启动计划无 `-k`；bootstrap 并发合并、失败可重试且退避有界。Swift transport/process-manager 独立复审通过。

#### APC-P1-008 `input_request` 错误地结束“正在生成”状态 — `FIXED`

- 证据：`AppStore.swift:374`、`AppStore.swift:88`、`PetStudioView.swift:401`。
- 问题：AI 等待用户补充信息时 `isGenerating=false`，界面允许启动第二个任务并隐藏取消按钮。
- 修复方向：显式 generation state machine（idle/starting/running/waitingForInput/cancelling/succeeded/failed）；waiting 仍属于 active job。

#### APC-P1-009 GUI 重启后不能重新附着正在运行或等待输入的生成任务 — `FIXED`

- 证据：`AppStore.swift:143,442,1186`；当前 snapshot 不包含 active job，历史只围绕已完成 pet。
- 问题：应用崩溃/重启后用户看不到仍在 daemon 中运行的任务，无法继续输入或取消。
- 修复方向：snapshot 返回 active jobs/session transcript；AppStore 启动时恢复订阅和交互状态。

#### APC-P1-010 Overlay 只约束宠物本体，缩放柄可落在屏幕外 — `FIXED`

- 证据：`OverlayGeometry.swift:130,262,286`。
- 问题：靠近屏幕右下角时，控制点超出可见工作区，用户无法再缩放。
- 修复方向：以宠物 + 阴影 + 控制点的交互包围盒做 clamp；加入各角、多显示器、不同 scale 测试。

#### APC-P1-011 主线程同步解码帧并在 draw path 读取磁盘缓存 — `FIXED`

- 证据：`OverlayRootView.swift:848,856,949,1005,1042`。
- 问题：非原始尺寸帧在 `@MainActor` 同步解码，渲染路径可读取 ring cache，导致掉帧和 UI 卡顿。
- 修复方向：后台有界解码队列、预取、内存 LRU、不可变纹理交换；draw path 禁止文件 I/O。

#### APC-P1-012 Swift UDS 调用无读写超时/取消并可能阻塞主 actor — `FIXED`

- 证据：`PetCoreClient.swift:60,124`、`PetCoreProcessManager.swift:131`。
- 问题：daemon 卡住时健康检查或业务 RPC 可无限等待并冻结 UI。
- 修复方向：actor/后台 transport、connect/read/write deadline、取消传播和断线重连。
- 完成证据：actor 隔离异步 UDS transport 具备 256 KiB/5 秒边界和取消关闭；socket path 不可变。严格并发构建、transport validation 与独立复审通过。

#### APC-P1-013 Overlay 缩放只有鼠标路径 — `FIXED`

- 证据：`PetOverlayController.swift:363,518`、`OverlayRootView.swift:1345`。
- 问题：键盘和辅助技术用户无法完成显示尺寸调整这一核心操作。
- 修复方向：可聚焦的缩放控制、键盘增减快捷键、AX increment/decrement action、清晰焦点和数值反馈。

#### APC-P1-014 所谓“真实 App Server 生成”仍是固定占位图 — `MITIGATED`

- 证据：`app_server.rs:1495,1527-1538`、`skills/agent-pet-studio/SKILL.md:35-38,106-114`、helper `skills/agent-pet-studio/scripts/*:135-210`、`script/validate_real_app_server.sh:149-180`。
- 问题：helper 生成单帧几何 PNG，不使用用户参考图；验证只证明 App Server 能调用该占位 helper。README 对“AI 生成”的描述高于实际能力。
- 修复方向：Skill 生成并验证完整 7 状态、真实帧序列和参考图约束；在能力完成前明确标记 preview，测试必须检查语义差异而非固定文件存在。

#### APC-P1-015 默认验证脚本会修改宿主全局运行状态 — `FIXED`

- 证据：`script/build_and_run.sh:19-21` 在解析模式前执行 `launchctl bootout`/`pkill`；renderer 验证复用该脚本；README 默认测试在 Darwin 可启动 GUI/真实 App Server。
- 问题：普通 build/test 会终止用户正在运行的 Agent Pet Companion 进程或触发外部集成，破坏性超出测试预期。
- 修复方向：先解析参数；build-only 永不触碰进程；测试使用临时 label/socket/data root；真实集成必须显式 opt-in。

#### APC-P1-016 Pi connector 注册不存在的事件并误判完成/失败/等待 — `MITIGATED`

- 证据：`connections.rs:347-400,641-712`、`core_validation.rs:3420-3438`、`script/validate_connectors_runtime.sh:130-153`。
- 问题：官方 ExtensionAPI 不存在 `tool_execution_failed`、`permission_request`、`approval_request`、`session_error`；`agent_end` 后仍可能 retry/compact/follow-up，`session_shutdown` 可能是 reload/new/resume/fork。当前实现会漏掉等待/失败并提前显示 Done，且自建 Map 自检把无效模板判为正常。
- 修复方向：使用显式、可类型检查的官方事件；完成用 `agent_settled`；`tool_execution_end.isError` 只表示可恢复的单次工具错误，最终失败由 settled run 的 assistant `stopReason=error` 判断；等待确认通过可证明的 Extension/UI 事件表达；真实 Pi opt-in 测试加载 extension。

#### APC-P1-017 OpenCode connector 未按官方 payload 读取 session/args — `MITIGATED`

- 证据：`connections.rs:447-470,762-769`、`petcore-cli/src/main.rs:1107-1121`。
- 问题：官方通用 Event 是 `{type, properties:{...}}`，direct before 是 `input.{tool,sessionID,callID}` + `output.args`；当前 parser 不读 `properties.sessionID`、`event.properties.sessionID` 或 `input.sessionID`，并错误从 `input.args` 取命令。会话关联和工具上下文静默丢失，伪造顶层 sessionID 的自检掩盖缺陷。
- 修复方向：固定兼容的官方版本、按 discriminated payload 解析，fixture 使用官方真实形状；不持久化完整 args/output，只提取 allowlisted 状态字段。

### 5.2 P2 — 发布前可靠性、性能与体验问题

#### APC-P2-001 UDS server 可被慢连接/超长单行拖垮 — `FIXED`

- `daemon.rs:49-58,102-113` 为每连接建线程，`read_line` 无长度、deadline 或并发上限。
- 增加最大 frame、超时、连接 semaphore；解析前拒绝超限消息。

#### APC-P2-002 JSON Schema 与运行时规则双向漂移 — `FIXED`

- schema 允许 `smooth` 默认、任意 `frames_dir`/`loop`；Rust 使用固定规则；Rust 又未拒绝空 name/style/date、未知字段和错误类型 agent event。
- 由共享 typed schema 生成 Rust/Swift 校验；启用 `deny_unknown_fields` 和严格类型错误。

#### APC-P2-003 ZIP 内嵌套帧路径被 basename 扁平化并可覆盖 — `FIXED`

- `petpack.rs:75-93,1348-1382`。
- 拒绝嵌套/重复逻辑目标，或保留并严格校验规范目录；解压前检测 collision。
- 完成证据：目录和 ZIP 均拒绝嵌套帧；解压预扫描拒绝重复/大小写碰撞和反斜杠路径；`petpack_resource_limits` 的 nested/collision 回归通过。

#### APC-P2-004 只限制压缩包大小，未限制解码尺寸和总内存 — `FIXED`

- `petpack.rs:19-21,75-106,1307-1315,1348-1382`。
- 限制单图像素、帧数、解压总字节、解码预算和纹理预算，防止 zip/image bomb。
- 完成证据：限制 1 GiB archive、4 GiB expanded、256 MiB/entry、5,000 entries、40 帧/state、280 帧总量、16,777,216 像素/frame 与 420 MiB 解码/state；resource-limit 10/10 通过。

#### APC-P2-005 参考图声明格式与实际 decoder 不一致且无配额 — `FIXED`

- `Cargo.toml:16` 的 image features 只支持 PNG/WebP，逻辑却接受 jpg/heic 等；`generation.rs:1629-1688`、`petpack.rs:1803-1808,2037-2081` 无数量/字节/像素上限。
- 能力探测和 UI accept 必须从同一支持列表生成；加入 3 层配额与明确错误。
- 完成证据：共用 validator 仅接受内容/扩展一致的 PNG/WebP，限制 4 文件、20 MiB/文件、40 MiB 总量和 16,000,000 像素/图；reference policy 4/4 通过。

#### APC-P2-006 Claude hook 卸载可能删除用户同组的其他 hook — `FIXED`

- `connections.rs:1834-1899` 只要组内存在 APC 子项就删除整个混合 group。
- 做结构化、仅目标项的外科式移除，并保留顺序和未知字段。

#### APC-P2-007 外部 CLI 探测没有 timeout — `FIXED`

- `connections.rs:541,600,703-708,774-779,934-937,999-1008,1735-1737`。
- 使用统一有时限的 process runner，限制输出，取消时杀整个 process group。

#### APC-P2-008 状态 revision 没覆盖所有可见 Pet 字段 — `FIXED`

- `db.rs:278-297,524-559`。
- revision 应由所有客户端可见字段的单调变更生成，避免 UI 漏刷新。

#### APC-P2-009 每次 snapshot 重扫所有帧且吞掉修复错误 — `FIXED`

- `rpc.rs:374-379`、`petpack.rs:945-981,1455-1493`。
- 安装时持久化验证结果/资源摘要；后台校验按 mtime/hash 增量执行；错误可观测。
- 完成证据：DB 缓存资产 fingerprint/验证结果；未变化复用、变化才完整校验/修复，同一损坏 fingerprint 不重试；snapshot 通过 `pet_asset_warnings` 返回有界结构化错误。缓存/修复/失败回归通过。

#### APC-P2-010 输出目录位于输入目录下时会递归打包 staging — `FIXED`

- `petpack.rs:671-695,2211-2235`。
- canonical path 预检并排除输出/staging；加入输入包含输出的回归测试。
- 完成证据：build 在创建 staging/ZIP 前 canonicalize 并拒绝位于输入树内的输出；`build_rejects_output_inside_input` 通过。

#### APC-P2-011 HTTP port marker 可陈旧且 readiness 语义不可靠 — `FIXED`

- `daemon.rs:34-46,116-120,380-387`。
- marker 写入 PID/start-time/随机实例 id，原子替换；客户端必须以带 token 的 health 为准，退出时仅删除自己的 marker。

#### APC-P2-012 `events.recent` 极端 limit 变成无限且事件无保留策略 — `FIXED`

- `rpc.rs:174-180`、`db.rs:95-105,323-334`。
- 服务器端 clamp 到安全范围；按数量/时间清理并为诊断保留聚合指标。

#### APC-P2-013 `start`/`done` 的非循环语义被渲染器忽略 — `FIXED`

- `OverlayRootView.swift:940` 对所有状态统一取模。
- 按 manifest 的 loop/one-shot 规则停在末帧，并在状态切换时复位。

#### APC-P2-014 自动隐藏语义与气泡实现不一致 — `FIXED`

- `AppModels.swift:263`、`PetOverlayController.swift:215`、`OverlayRootView.swift:22`。
- idle 气泡当前不会出现；明确“隐藏宠物/隐藏气泡/折叠”的状态机并统一实现、文案和测试。

#### APC-P2-015 Behavior 全对象并发写入可能乱序覆盖 — `FIXED`

- `AppStore.swift:477`。
- 串行化 mutation 或发送 field patch + expected revision；处理冲突和失败回滚。

#### APC-P2-016 跨显示器拖动仍被起始屏幕约束 — `FIXED`

- `OverlayRootView.swift:554,589`。
- 拖动期间按当前指针/最大相交屏幕动态选择工作区；保留归一化位置。

#### APC-P2-017 主界面和 Overlay 存在系统性可访问性缺口 — `FIXED`

- Event Toggle 空标签；来源 switch 只读出状态、不读来源；style/quality 仅颜色表达且无 selected trait；PetCard 用 `onTapGesture`；分段 picker 标签为空；连接页 AX 树合成巨长字符串；连接按钮缺少明确 selected/label。
- 逐控件补语义、role、value、selected 状态、键盘顺序和 live announcement；添加 AX 自动验证。

#### APC-P2-018 固定浅色背景/文字在深色与高对比模式下失效 — `FIXED`

- `DesignSystem.swift:4`、`ContentView.swift:14`。
- 使用 semantic color 和现有 token 的 light/dark/high-contrast 变体；实机 snapshot 对照。

#### APC-P2-019 指针监测频率过高 — `FIXED`

- 当前约每秒 108 次 pointer timer callback，另有 2 Hz 扫描。
- 改用事件驱动 tracking area/global monitor，动画显示期间才启用低频 fallback。

#### APC-P2-020 多 Agent 状态聚合位于 UI 层且优先级可陈旧 — `FIXED`

- `AppStore.swift:59`。
- PetCore 作为单一状态仲裁器，带事件时间/租约；UI 只渲染 canonical active state。

#### APC-P2-021 已提交的生成表单仍可编辑 — `FIXED`

- AI 会话运行或 waiting 时，name/style/quality/reference 仍可改变，但改变不会可靠地作用于当前任务。
- 活跃任务冻结初始输入；后续只开放结构化补充输入，并显示任务摘要。

#### APC-P2-022 Library 对“资源完整”和状态规格的判断失真 — `FIXED`

- `PetLibraryView.swift:218,329` 只凭文件可读就显示完整，并硬编码 7 状态、12/20 FPS。
- 展示 daemon 返回的已验证摘要、缺失/损坏状态和 manifest 实际参数；规格常量共享。

#### APC-P2-023 Agent Connections 自适应 Grid 垂直错位且 switch 视觉状态不清 — `FIXED`

- 实机截图显示默认 GridItem alignment 使矮卡片垂直居中；behavior/连接 switch AX 为 on，但灰色外观近似 off；事件 switch 不读事件名。
- Grid 顶对齐；统一 accent/tint；文本与 AX 同时表达状态，不依赖颜色。

#### APC-P2-024 Codex hook 使用不存在/语义不匹配的生命周期映射 — `MITIGATED`

- `connections.rs:244-279` 注册 `StopFailure`，但当前 Codex Hooks 官方事件清单没有该事件；每次 `PostToolUse` 也不等于“需要用户 review”。
- 删除不受支持 hook；只从官方事件与 payload 映射可证明状态。若 Codex 没有独立失败事件，应诚实降级并通过支持的 App Server/event stream 补足，而不是虚构 hook。

#### APC-P2-025 Claude hook 路径、失败语义、输出和检查不完整 — `MITIGATED`

- `connections.rs:281-330,1233-1282,1800-1802` 固定写 `HOME/.claude`，未尊重 `CLAUDE_CONFIG_DIR`；漏掉代表工具失败的 `PostToolUseFailure`；command 默认同步、无短 timeout/async 且 CLI 成功 JSON 写 stdout；静态检查不能证明 settings 有效、未被禁用或实际加载。
- 尊重官方配置根；区分 API turn `StopFailure` 与工具 `PostToolUseFailure`；增加 quiet/有界异步旁路；结构化解析 settings，并把“已配置”和“已真实触发”分开展示。

#### APC-P2-026 Pi RPC 能力被宣称但未实现/真实探测 — `FIXED`

- `connections.rs:517-556` 仅查 `pi --help`；技术文档却把 Extension + RPC 写成已实现方案。
- V1 若只需观察现有 Pi 会话，应明确仅支持 Extension；若保留 RPC，则实现 `pi --mode rpc` 的 strict LF JSONL、request id、异步事件和 `extension_ui_request/response`，并用 `get_state` 做真实健康探测。

#### APC-P2-027 OpenCode 状态映射和 Server 探测不符合官方语义 — `MITIGATED`

- `connections.rs:419-425,452-470,576-639` 使用不存在的 `session.done`，把所有 `session.updated` 变成 Start、所有 `permission.*` 变成 Waiting；after output 没有模板假定的 `error` 字段，合成的 `tool.execute.failed` 基本不可达；Server 只看 help 文案。
- 使用 stable Event/types 的 `session.idle/error/status` 与 permission updated/replied 兼容层；用真实 `/global/health` 探测 server，并在官方网页与稳定类型冲突处固定兼容矩阵。

#### APC-P2-028 Renderer 性能门禁只校验理论缓存且未断言实际 CPU/内存 — `FIXED`

- 修复后复审证据：`validate_renderer_runtime_budget.sh` 只断言 `estimated_runtime_cache_mb`，对单次 `ps` 的 CPU/RSS 仅记录且 RSS 只要求大于 0；实测 original 整个 App RSS 为 462.4 MB，但没有隐藏基线、renderer delta 或 Metal/纹理实占，既不能证明超过也不能证明满足 420 MB Renderer 预算。
- 建立隐藏/无帧稳定基线，采样足够长的 CPU 平均和 RSS 峰值 delta，结合实际缓存/纹理分配指标硬断言技术方案各档预算；明确整个 App RSS 与 Renderer 增量的口径，禁止把理论 `width×height×4×frames` 当成实测验收。

### 5.3 P3 — 一致性、边缘情况与工程债务

#### APC-P3-001 capability token 先创建后 chmod，存在短暂权限窗口 — `FIXED`

- `daemon.rs:65-75`、`paths.rs:50-57`。
- 用 `OpenOptionsExt::mode(0o600)` 原子创建，并验证父目录权限。

#### APC-P3-002 损坏 JSONL 被静默丢弃，半行可污染后续事件 — `FIXED`

- `generation.rs:116-125,361-395,416-425`。
- 记录有界诊断、隔离坏记录、区分 EOF 半行并在 writer 恢复时清理/轮转。
- 完成证据：坏完整行生成不含原文的行号/hash/category 诊断，后续合法行保留；append 会截断坏尾并先写诊断；`generation_jsonl_recovery` 4/4 通过。

#### APC-P3-003 JSON-RPC 2.0 语义仅部分实现且命名误导 — `FIXED`

- `rpc.rs:61-68,86-129`、`daemon.rs:102-113`。
- 要么完整实现 request/batch/notification/error，要么将协议明确命名为项目私有 RPC 并固定 envelope/version。

#### APC-P3-004 generation message 每次解码生成新 UUID — `FIXED`

- `AppModels.swift:410`。
- 服务端提供稳定 message id；Swift 按 id diff，避免列表跳动和重复动画。
- 完成证据：新消息写入稳定 id，旧 JSONL 行由规范内容派生确定性 id；`legacy_messages_receive_stable_ids` 通过。

#### APC-P3-005 Library 的导入入口与 V1 窄范围存在歧义 — `FIXED`

- `PetLibraryView.swift:68`。
- 明确仅导入 app-owned `.petpack`，移除任何暗示 Petdex/Codex 资产兼容的文案和 accept type。

#### APC-P3-006 缺少本地化/String Catalog — `FIXED`

- 当前用户文案散落在 Swift 源码，公共文档虽双语但产品 UI 无统一本地化路径。
- 引入中英 String Catalog，错误和 onboarding 使用稳定 key。

#### APC-P3-007 非当前选中 Pet 显示全局 active event — `FIXED`

- `PetLibraryView.swift:260`。
- 卡片/详情只显示该 pet 的资源与状态；全局 Agent 活动放在明确的全局区域。

#### APC-P3-008 无 active pet 时手工 placeholder 且默认比例过小 — `FIXED`

- 当前占位造型与实际资源路径不同，默认 scale `0.12` 时真实宠物非常小。
- 使用正式 bundled starter pet 或清晰空状态；根据资源可视边界校准默认显示尺寸。

#### APC-P3-009 文档、构建与仓库卫生存在多处漂移 — `FIXED`

- 实现计划仍引用技术 V1；产品表单 4 项与技术计划新增 note/UI nil 不一致；`.petpack` 布局描述不一致；README 缺 macOS 14/toolchain 前置条件；Cargo 元数据是 `example.invalid`；无 CI/toolchain pin；Python cache 未忽略且可能打入 bundle；连接测试遗留固定 `/tmp` 文件；旧设计资产无索引。
- 统一版本和格式说明；补 CI、pin、CONTRIBUTING、平台矩阵、忽略/打包规则和临时目录清理。

### 5.4 闭环证据索引

| 机制与覆盖问题 | 最终实现与可重复证据 |
|---|---|
| 原子 Pet revision：P1-001、P1-002、P2-003～005、P2-009～010 | immutable revision、条件 active pointer、共享 store lock、daemon-first CLI、ZIP/像素/帧/参考图配额；`petpack_import_atomic` 12/12、`petpack_import_routing` 3/3、`petpack_resource_limits` 10/10、`reference_image_policy` 4/4 通过。 |
| daemon / RPC / token：P1-003、P2-001～002、P2-011、P3-001、P3-003 | 唯一实例锁在恢复前获取；UDS/HTTP 绝对 deadline、并发和 256 KiB 边界；原子实例 marker 与 0600 token；JSON-RPC batch/notification/标准错误完整；`daemon_lifecycle` 25/25、`daemon_http_security` 4/4、`schema_fixtures` 3/3 通过。 |
| 事件隐私、幂等和保留：P1-004～005、P2-008、P2-012、P3-002 | strict typed ingest envelope、closed vocabulary、来源/会话命名空间、稳定缺省 id、可见字段 revision、数量保留与 crash-safe legacy scrub；`event_envelope_security` 15/15、`generation_jsonl_recovery` 4/4 和安全边界脚本通过。 |
| 生成状态与恢复：P1-006、P1-008～009、P2-021、P3-004 | EOF 立即失败；daemon 持久化 active job/message sequence；Swift 可恢复 running/waiting session，冻结已提交表单并保留稳定消息 id；`app_server_transport` 2/2、`generation_lifecycle` 4/4、`generation_recovery` 8/8、Swift generation tests 通过。 |
| macOS 生命周期与 transport：P1-007、P1-012、P1-015 | 健康优先、bootstrap 合并和有界退避；actor UDS deadline/取消/断线恢复；默认测试只操作隔离 home 与 owned PID/instance，不再 broad kill；Swift process/transport tests 与 `validate_test_isolation.sh` 通过。 |
| Overlay、状态仲裁与 renderer：P1-010～011、P1-013、P2-013～014、P2-016、P2-019～020、P2-028 | 完整交互包围盒、当前指针 display、AX/键盘缩放、one-shot scheduler、PetCore canonical lease、事件驱动指针、actor 解码 + LRU/ring + ready handoff、draw path 零磁盘；UI validation 7/7、宿主 Overlay 五类门禁与 30 秒真实性能门禁通过。 |
| Behavior 与主界面：P2-015、P2-017～018、P2-022～023、P3-005～008 | CAS field patch、语义颜色/AX label/selected state、top-aligned adaptive grid、app-owned `.petpack` UTI、daemon 资源摘要、Pet-scoped event、starter/scale 校准、完整 zh-Hans V1 表面与中英 catalog parity；Swift UI tests、主窗口 AX 门禁和 8 组并排截图通过。 |
| 外部进程与 Agent 契约：P1-016～017、P2-006～007、P2-024～027 | 统一有界 process runner（输出限额、process-group/精确 PID 生命周期）、Claude 外科式卸载、Codex/Claude/Pi/OpenCode 版本化官方形状 fixtures、strict parser、真实 health 探测、对不支持 Pi RPC 的诚实降级；`process_runner` 6/6、`connector_contracts` 4/4、模拟 connector runtime 通过。 |
| 真实生成边界：P1-014 | deterministic helper 只允许标记为 preview；external/full source 必须返回并通过完整 `.petpack` 验证，不能用 brief 或固定 helper 冒充；core generation source-gate 回归通过。真实 Codex App Server 生成留作授权门禁。 |
| 工程与交付：P3-009 | Swift Testing target、Rust/Swift CI、Rust toolchain pin、CONTRIBUTING、设计索引、开发/Release/签名公证脚本和失败前置检查均已补齐；默认 `test_all.sh` 与 app bundle 验证通过。 |

### 5.5 `MITIGATED` 的有界剩余条件

| 问题 | 已完成 | 唯一剩余外部条件 |
|---|---|---|
| P1-014 | 全来源真实性 gate、preview/full 明确分流、无 App Server 时诚实失败 | 用户明确允许后运行 `APC_VALIDATE_REAL_APP_SERVER=1 ./script/validate_real_app_server.sh`，由真实 image-capable Codex App Server 返回完整 petpack。 |
| P1-016 | Pi 只注册受支持事件，以 `agent_settled`、`tool_execution_end.isError` 和可证明 waiting 语义映射；官方形状 fixture 通过 | 在用户真实 Pi Extension 环境中显式 opt-in 触发一次完整会话。 |
| P1-017 | OpenCode v1.17.18 discriminated/direct payload、`properties.sessionID` 和 `output.args` 解析回归通过 | 在用户真实 OpenCode plugin/server 环境中显式 opt-in 触发一次完整会话。 |
| P2-024 | Codex 不再注册虚构 `StopFailure`，只声明可证明 hook 状态 | 用户信任并加载真实 Codex plugin/hook 后完成 roundtrip。 |
| P2-025 | 尊重 Claude 配置根、补全失败语义、quiet bounded handler、结构化安装检查 | 用户允许写入/加载其真实 Claude Code hooks 后完成 roundtrip。 |
| P2-027 | OpenCode stable event 兼容矩阵、idle/error/status/permission 映射和 `/global/health` 探测已实现 | 用户允许加载其真实 OpenCode plugin/server 后完成 roundtrip。 |

## 6. 官方 Agent 集成核验

### 6.1 Codex

- [Codex App Server](https://developers.openai.com/codex/app-server) 使用 JSONL/stdio 的 JSON-RPC-like 协议；实现保留其线上 envelope，不错误强加 `jsonrpc` 字段，并对初始化、turn、EOF 和 stderr 做有界处理。
- [Codex plugin 构建文档](https://developers.openai.com/codex/plugins/build) 要求 `.codex-plugin/plugin.json`；仓库现在提供可版本化 plugin 结构和 Pet Studio Skill，不再只依赖不可追踪的散落模板。
- [Codex Hooks](https://learn.chatgpt.com/codex/hooks) 没有 `StopFailure`；修复版已删除该虚构事件，也不再把普通 `PostToolUse` 冒充成需要用户 review。
- 本地官方形状 fixture、安装/检查/卸载契约通过；真实用户环境仍由显式 opt-in gate 负责。

### 6.2 Claude Code

- [Hooks reference](https://code.claude.com/docs/en/hooks)、[Hooks guide](https://code.claude.com/docs/en/hooks-guide)、[Settings](https://code.claude.com/docs/en/settings) 和 [.claude directory](https://code.claude.com/docs/en/claude-directory) 确认 `StopFailure` 与 `PostToolUseFailure` 的语义不同；修复版分别映射 API turn 与工具失败。
- 安装路径尊重 `CLAUDE_CONFIG_DIR`；handler quiet、timeout/output 有界，不向 hook stdout 注入项目 RPC JSON。
- 安装、检查和卸载使用结构化 JSON；卸载只移除精确 owned command，保留同组用户 hook、顺序和未知字段。
- 本地混合 hook group、无效 settings 和幂等修复测试通过；真实 Claude 加载仍需用户授权。

### 6.3 Pi Coding Agent

- [Extensions](https://pi.dev/docs/latest/extensions) 和固定官方提交的 [ExtensionAPI 事件](https://github.com/earendil-works/pi/blob/34582ef34beec868b0df4fb969385b8af5960c45/packages/coding-agent/src/core/extensions/types.ts#L1017-L1043) / [`pi.on` 重载](https://github.com/earendil-works/pi/blob/34582ef34beec868b0df4fb969385b8af5960c45/packages/coding-agent/src/core/extensions/types.ts#L1165-L1211) 是当前 V1 契约基线。
- 模板已删除不存在的事件；完成使用 `agent_settled`，单次 `tool_execution_end.isError` 保持运行态，最终失败读取 settled run 的 assistant `stopReason=error`；等待只从可证明的 tool/UI 交互产生。
- [RPC](https://pi.dev/docs/latest/rpc) 是严格 LF JSONL；V1 现在明确只支持 Extension 观察，不再把未实现的 `pi --mode rpc` 宣称为已支持。
- 版本化模板和官方形状 fixture 通过；真实 extension 加载仍需用户授权。

### 6.4 OpenCode

- [Plugins](https://opencode.ai/docs/plugins/)、[Server](https://opencode.ai/docs/server/) 和固定 v1.17.18 的 [Plugin hook 类型](https://github.com/anomalyco/opencode/blob/v1.17.18/packages/plugin/src/index.ts#L222-L284) / [stable Event 类型](https://github.com/anomalyco/opencode/blob/v1.17.18/packages/sdk/js/src/gen/types.gen.ts#L439-L478) 是当前兼容矩阵。
- parser 同时处理 `{type,properties:{...}}` 与 direct hook 的 `input.{tool,sessionID,callID}` / `output.args`，不保存完整 args/output；after 不再假设不存在的 `error` 字段。
- 状态映射使用可证明的 `session.idle/error/status` 和 permission updated/replied 兼容层；Server 通过真实 `/global/health` JSON 探测。
- discriminated/direct payload fixture 与 health parser 通过；真实 plugin/server roundtrip 仍需用户授权。

## 7. 结构性优化项

这些不是另起炉灶的扩展功能，而是消除上述问题反复出现的共同机制。

1. **单写入者 PetCore**：GUI/CLI 都通过 daemon；所有资源、DB、event 和 revision 变更串行化。
2. **可恢复 revision 协议**：每个 pet revision 独立目录 + journal + 原子 active pointer，启动时可回放/回滚。
3. **严格 typed envelope**：Agent event、RPC、schema、Swift model 从同一源生成，拒绝隐式强制转换和未知字段。
4. **隐私最小化管线**：来源适配器先提炼状态，再进入 core；原始 tool payload 不跨边界、不落库。
5. **生成任务状态机**：daemon 持有唯一真相，GUI 可重连；input request、取消、失败和完成都有稳定 id/revision。
6. **有界资源策略**：连接数、消息、事件、参考图、zip、像素、帧、纹理、子进程输出和历史记录统一配额。
7. **后台渲染资产管线**：离线验证/缩放/预取，Metal draw path 只读内存中的 ready texture。
8. **事件聚合租约**：source/session/sequence/timestamp + TTL，PetCore 确定跨 Agent 的 canonical 状态。
9. **外部进程统一 runner**：timeout、输出限制、process-group cancellation、allowlist 和结构化诊断。
10. **真实验证分层**：纯单测、隔离集成、host-mutating UI、真实外部 Agent 分开，默认只运行前两层。
11. **生成 schema/types 与契约测试**：JSON Schema 必须由测试实际执行，Swift/Rust 示例共享 golden fixtures。
12. **交付工程化**：CI、锁定 toolchain、Release universal build、Developer ID 签名、公证、资源 sealing、版本/升级策略。

| 优化项 | 状态 | 落地证据 |
|---:|---:|---|
| 1 | `DONE` | GUI/CLI 默认经 daemon，offline writer 受 singleton/store lock 约束。 |
| 2 | `DONE` | immutable revision + atomic pointer + 故障恢复/并发测试。 |
| 3 | `DONE` | strict ingest schema、Rust typed normalizer、Swift models 与 golden fixtures。 |
| 4 | `DONE` | 原始 payload/命令/输出不跨 core 边界；旧数据 crash-safe scrub。 |
| 5 | `DONE` | daemon generation job/message sequence + Swift resumable state machine。 |
| 6 | `DONE` | UDS/HTTP/process/ZIP/图片/帧/纹理/事件/日志统一有界。 |
| 7 | `DONE` | actor 解码、LRU/ring、ready handoff、Metal/draw 实测门禁。 |
| 8 | `DONE` | PetCore canonical state arbitration、时间/租约/优先级与终态过期。 |
| 9 | `DONE` | 统一 process runner，具备 deadline、输出上限、process group 和精确 PID ownership。 |
| 10 | `DONE` | 默认隔离、宿主 UI、真实 connector、真实 App Server、性能 profile 分层。 |
| 11 | `DONE` | Schema 正反 fixtures、官方 connector shapes、Swift catalog/model parity tests。 |
| 12 | `DONE` | CI、toolchain pin、开发/Release/签名公证脚本和交付文档。 |

## 8. 已确认符合基线的部分

- V1 主导航仍为 Pet Studio、Enable & Behavior、Agent Connections。
- Pet Studio 保持 New / Pet Library 两个页签。
- 状态集合与产品基线相符：idle、start/thinking、tool/working、waiting、review、done、failed。
- 12 FPS 标准和 20 FPS smooth 的设计约束已进入实现。
- 显示尺寸通过 Overlay 右下角 handle 调节，没有重新增加设置字段。
- Overlay 使用 NSPanel/AppKit，宠物帧走 Metal-backed 渲染。
- HTTP 管理端点限定 loopback 且使用 bearer capability token；UDS 权限为 0600。
- ZIP slip、pet id 路径校验、删除前 canonicalization、SQL 参数化均已有防护。
- Rust 主代码未发现 `unsafe`；未发现主动读取 Agent auth/token/cookie 文件的实现。

## 9. 修复批次与完成结果

| 批次 | 范围 | 对应问题 | 完成门槛 |
|---|---|---|---|
| A | 数据原子性、daemon 唯一性、隐私、事件幂等、RPC 边界 | P1-001～006，P2-001～012，P3-001～003 | 故障注入/并发/迁移/限额测试全部通过 |
| B | macOS 生命周期、生成恢复、transport、overlay、AX | P1-007～013，P2-013～023，P3-004～008 | Swift tests + semantic token validation + 实机窗口/键盘/AX/交互巡检 |
| C | 真实 AI/Agent 集成与安全卸载 | P1-014、P1-016～017、P2-005～007、P2-024～027 | 官方事件契约 fixtures、真实 opt-in gate、无占位声明 |
| D | 构建、CI、文档、交付 | P1-015，P3-009 与优化项 | 默认测试无宿主副作用，CI/Release 检查可重复 |
| E | 全量回归与报告关闭 | 全部 | 问题账本无未解释 `OPEN`；fresh 全量验证证据 |

五个批次均已达到本地完成门槛。每项都有复现或失败测试、实现修复、回归门禁、相关文档和最终状态；无法在当前授权范围内完成的真实第三方验收已明确列为 6 个 `MITIGATED`，没有静默略过或无理由 `DEFERRED`。
