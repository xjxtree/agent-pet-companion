# Agent Pet Companion 当前项目状态

> 状态日期：2026-07-16
> 审计范围：当前工作树中的产品/技术文档、Swift macOS App、Rust PetCore/CLI、四类 Agent 连接器、构建与验证脚本  
> 结论：项目已达到本地 V1 **develop 候选**；本文原列 P0、P1 工程项已完成。当前不按正式产品交付，Developer ID、公证等工作保留在 P2。

## 1. 文档口径

1. [产品方案 V5](design/product-plan-v5/AgentPetCompanion_ProductPlan_V5.md)定义产品范围与验收目标。
2. [技术方案 V1.1](design/AgentPetCompanion_TechnicalPlan_V1_1.md)定义架构、协议、安全、性能与生命周期约束。
3. 本文记录当前工作树的实际完成度、验证证据和剩余事项。
4. [实施计划 V2](plan/AgentPetCompanion_ImplementationPlan_V2.md)记录阶段执行结论。
5. [`.petpack` V1 白皮书](specifications/AgentPetCompanion_Petpack_Whitepaper_V1.md)定义当前容器、producer profile、安全预算、修订与兼容策略。

`docs/audits/2026-07-10-project-review/` 是历史快照；其结果已被本文替代。当前工作树仍包含未提交变更，验证结论只绑定本文日期的工作树，不等于 Git HEAD 或正式 release。

## 2. 当前运行架构

| 层 | 实现 | 责任边界 |
|---|---|---|
| macOS UI Host | Swift 6、SwiftUI、AppKit/NSPanel、Metal；单实例 | 单例控制中心、状态栏菜单、桌宠、消息气泡和用户交互。关闭控制中心不退出 Host；标准 Quit 退出全部 UI。 |
| PetCore | Rust 用户级 LaunchAgent | Agent 事件、状态仲裁、SQLite、`.petpack`、生成任务和 RPC；独立于 UI Host 常驻，不绘制 UI。 |
| PetCore CLI | Rust CLI | Hook/Extension/Plugin 的受控本地入口、连接诊断与维护。 |
| 本地通信 | UDS JSON-RPC `apc.petcore-rpc.v2`；受 token 保护的 loopback HTTP | App/CLI 与 PetCore 通信；adapter 只放行有界展示和导航字段。 |
| 数据 | SQLite schema 4；`.petpack` 读/写 `apc.petpack.v1` | 本地持久化；不读取 Agent auth、token、cookie 或私有会话数据库。 |
| 事件 | `apc.agent-event.v1` | 统一状态、用户/Agent 消息、公开活动摘要、交互请求与会话打开信息。 |

App、PetCore、CLI 和连接器不再只比较 RPC 版本。每个 bundle 携带 `apc.runtime-manifest.v1`，精确绑定 App version/build、`APCBuildID`、PetCore/CLI build、RPC、数据库/事件 schema、`.petpack` 可读版本列表/当前写入版本和四个 connector contract。App 将候选 runtime 放入 `APC_HOME/runtime/versions/<build-id>`，先执行 manifest 与数据库只读预检，再交接 LaunchAgent；候选 health/manifest 不匹配时恢复 `last-known-good`。为兼容早期同版 `apc.runtime-manifest.v1`，Rust/Swift 在缺少新增读写字段时会从 `petpack_schema_version` 重建等价默认值；真正未知的数据库、schema 或版本组合仍 fail closed。

健康版本提交后，`APC_HOME/runtime/current` 以原子符号链接指向当前完整 runtime。已安装连接器统一引用稳定的 `runtime/current/petcore-cli`，App 在版本交接后只刷新已经安装的本项目 connector 文件/配置项；未安装连接器和用户的其他配置不改写。连接器因此不再随 build ID 固化到旧 CLI。

`APC_DISABLE_LAUNCH_AGENT=1` 只影响本次隔离验证，绝不会 bootout 用户全局 `dev.agentpet.petcore`。验证清理会按隔离 `APC_HOME/runtime/versions` 下的精确可执行路径认领被 reparent 的 PetCore，并进行 TERM/KILL 有界回收。CI 明确用 macOS 系统 Bash 3.2 和尾斜杠 `TMPDIR` 执行该门禁；路径归一化兼容 Bash 3.2/5，身份协议存在但校验失败时禁止退化为路径扫描，夹具失败也会按本次记录的精确 PID 回收，不遗留孤儿进程。

## 3. 产品与 UI 完成度

| 功能域 | 当前状态 |
|---|---|
| 三入口导航、Studio 双页签、本地宠物库 | 已实现 |
| 原生 UI | 控制中心、状态栏、桌宠控制、右击菜单和消息气泡使用 macOS 原生 clear Liquid Glass。消息气泡在 macOS 26 使用无 tint、无填充、无边框、无附加 opacity 的 `NSGlassEffectView.Style.clear`，完整 SwiftUI 气泡作为系统保证层级正确的 `contentView`；macOS 14–15 使用系统 `ultraThinMaterial` 回退。 |
| 桌宠渲染 | Metal-backed；12/20 FPS；高/超清 eager cache、原画 ring cache；左键拖动与宠物右侧缩放；缩放手柄与气泡开关同列且命中区独立；左键单击无额外响应、仅右击显示原生菜单；不显示拖动标签或脚下玻璃底座。 |
| 会话气泡 | 每个 Agent 一个气泡；同 Agent 多会话分行；标题、最多两行的当前公开活动/回复、状态和唯一「打开」操作；两行渲染与 Panel 高度测量一致；默认 15 分钟普通会话收起。 |
| 状态内容 | Running 优先显示公开思考摘要/计划或本地化工具活动；已完成工具不再冒充当前活动，公开 revision 停滞但任务时钟推进时清除旧摘要；Ready 显示最新 Agent 回复；Needs input/Blocked 显示当前交互或错误。 |
| 打开会话 | 精确会话 URL优先，其次原终端 App，再到对应 Agent App；Codex CLI 不盲用 ChatGPT thread 深链；Warp 有合法 session URL 时精确定位，否则激活 Warp。 |
| 生命周期 | UI Host 单实例；关闭窗口不退出；菜单栏/桌宠可恢复控制中心；标准 Quit 不停止 PetCore；磁盘 App 替换按 build ID 交接。 |
| Agent 图标 | App 与气泡共用 `AgentIconProvider`。按 `/Users/zyq/git/agent-copilot/` 的官方资源优先策略，优先解析 ChatGPT/Codex、Claude、OpenCode 的已安装 App/品牌资源；Pi 使用项目内品牌徽标；无资源时才使用明确 fallback。 |
| AI 宠物来源 | 正式 App 默认要求真实图像能力产出的 `skill-full-source`；确定性 materializer 仅供显式 simulated gate 使用，不可标成 AI 来源。已验证来源在宠物库显示七状态、帧率、provenance 与 PetCore 资源校验结论。 |
| 宠物库可移植性 | 任意合规 `.petpack` 进入同一校验/不可变 revision 链；支持原子导出、重新导入、保持活跃状态的同 ID 修订，以及对 App 创建或外部导入宠物发起 Codex AI 修改。 |
| 外部 Agent 制作 | 新增 provider-neutral `agent-pet-maker` 技能；Claude Code、Pi、Hermes、OpenCode 等具备真实图像能力的宿主可创建/修改、校验与构建包。缺能力时返回 `capability_missing`；仅在用户明确授权时通过在线 daemon 导入/激活。 |

V1 仍不包含公共素材库、分享/社区、Petdex 导入、Codex 内置宠物资产导出、Windows UI、云账号或完整 Agent mission control。

## 4. Agent 连接器状态

| Agent | 契约 | 已实现与已验证能力 |
|---|---|---|
| Codex | `codex-hooks-2026-07-15-schema-v3` | ChatGPT/Codex CLI 发现、官方 hooks、1 秒 App Server 近期任务只读同步、标题/用户与 Agent 消息/公开活动、状态与安全跳转；`commandActions` 区分读取/搜索/Shell，只有 `inProgress` 工具可作为当前活动。真实 Hook 通过显式 bypass-trust 运行产生事件；持久 Hook Trust 仍必须由用户在 ChatGPT 中确认，App 明确说明精确实时工具切换依赖该信任。 |
| Claude Code | `claude-hooks-2026-07-14-activity-v3` | prompt、tool/batch、permission/elicitation、compact/subagent/task、stop/failure、消息/活动与终端导航；可恢复工具失败不误报 Blocked。 |
| Pi Coding Agent | `pi-extension-20260714-message-v5` | prompt、message update/end、tool、settled、compact、最终错误语义、标题/消息/活动与终端导航；正常完成不会误报 Blocked。 |
| OpenCode | `opencode-v1.17.18-activity-v4` | session/message/tool/permission/question/error/idle、标题/消息/活动与终端导航；标准事件观察不依赖 Server。 |

当前机器上四个连接器均已更新到当前 runtime 的 `petcore-cli`。Claude、Pi、OpenCode 完整检查为“已验证”；Codex 只有用户控制的持久 Hook Trust 为“未验证”，其他 CLI、插件、App Server、事件 socket 与本地通道均正常。连接页继续区分“已安装、已启用、已验证、未验证、非必需”，不会把诊断事件冒充真实 Agent turn。

## 5. 已完成的 P0

| P0 项 | 完成证据 |
|---|---|
| 恢复可信默认门禁 | M1/M5/security allowlist 已同步 `activity_kind/activity_content` 等正式字段；schema 正反 fixtures 保持 fail closed。 |
| Swift 单元测试 | 引入固定 `swift-testing 6.3.2` 与兼容 runner；当前 95 tests / 10 suites 通过。 |
| 统一 runtime manifest | Rust/Swift 使用同一 `apc.runtime-manifest.v1`；health、preflight、bundle validator 精确比较完整 manifest，并测试覆盖同版旧 manifest 重建新增 `.petpack` 读写字段。 |
| `.petpack` 标准与兼容握手 | 发布白皮书、manifest/来源/brief/event/validation 五组 schema 正反 fixtures；runtime manifest 同时公开 read versions 与 write version。 |
| 降级/兼容保护 | 未来 DB、错误 build/RPC/schema/connector contract 组合拒绝启动；UI 显示更新/不匹配状态；候选未验证不提交为 current。 |

## 6. 已完成的 P1

| P1 项 | 完成证据 |
|---|---|
| 两阶段交接与回滚 | stage → manifest/DB preflight → instance-bound shutdown → candidate LaunchAgent/direct start → exact health → commit current/LKG；失败自动恢复 LKG。 |
| Computer Use 实机回归 | 最终 develop 候选通过控制中心启动、服务就绪、Agent 连接页/官方图标视觉检查；关闭控制中心后 App 与 PetCore 均继续运行。全程未使用 AppleScript、CGEvent、`open -n` 或直接抢占鼠标键盘。 |
| 真实连接器与 App Server | `APC_VALIDATE_REAL_AGENT_CONNECTORS=1` 和 `APC_VALIDATE_REAL_APP_SERVER=1` 均通过；不读取认证文件。真实 Codex hook 另通过安全只读 turn 验证事件落库。 |
| 真实 Pet Studio 完整闭环 | 通过 packaged App + Computer Use 创建 `星雾团子`：真实 Codex App Server 图像生成、透明分帧、七状态校验、`.petpack` 构建、自动入库、启用和桌面渲染全部完成。14 张帧哈希均不同，`idle/start/tool/waiting/review/done/failed` 七状态逐一实机显示。 |
| Studio/Agent 会话隔离 | PetCore 在 `thread/list` 和 `thread/read` 两层排除 `generation-jobs/job_*` 下的 Studio 内部 Codex 任务，不把生成提示或结果 JSON 放入 Agent 气泡。 |
| 更新后连接器连续性 | `runtime/current/petcore-cli` 稳定入口与已安装 connector 引用刷新已实现；最终实机交接后 Pi/OpenCode 已使用稳定入口，Claude 的 80 条历史 versioned Hook 被清理为 20 个官方事件各一条 current Hook。App/Core/CLI/connector 不再因 versioned CLI 路径产生更新滞留。 |
| Codex 活动时序与分类 | App Server 同步周期收紧到 1 秒；完成态 `fileChange`/命令/MCP 不再作为当前活动，结构化命令按读取/搜索/Shell 分类，同一 turn 稳定记录原位更新；有损快照缺少新 item 时不复活旧思考或旧文件状态。 |
| 宠物导出与往返 | PetCore/RPC/CLI 使用校验前后 staging + 同文件系统原子替换导出当前不可变 archive；测试覆盖字节保持、重新导入、未知 ID、受管目录、symlink/损坏源不覆盖目标。 |
| 任意宠物 Codex 修订 | `generation.edit` 安全展开当前包，固定 ID/created_at/画质/尺寸/FPS/状态结构；提交前核对基线 SHA，冲突时保留用户较新 revision；非活跃宠物修改后仍非活跃。真实隔离 App Server E2E 已从外部导入的 `pet_lunari` 产生同 ID/原 created_at 的新 revision，仅重绘 `done` 两帧，其余 12/12 PNG 与基线 byte-identical。 |
| 可移植 Agent Skill | `agent-pet-maker` 支持 create/modify、真实图像能力门禁、安全解包、状态哈希、未改状态 byte-identical、统一 CLI 校验构建和显式在线导入/激活；已完成全新月兔 14 帧真实 image generation 前向测试，以及仅修改 `tool` 状态的真实外部修订（其余 6 状态、12 帧逐字节不变）。 |
| 可移植元数据隐私 | 当前 Studio 打包移除 App Server thread/turn/session/request/command-source，并用严格 event schema 重写包内 session；对话与完整执行记录只留在私有 generation job，不随 `.petpack` 导出。 |
| Renderer 真实性能 | high 11.936/12 FPS、CPU 2.6%、RSS 增量 19.14 MiB；ultra 19.897/20、3.433%、70.92 MiB；original 19.857/20、4.567%、274.34 MiB；隐藏态 CPU 0.133%，全部在预算内。 |

## 7. 2026-07-16 验证矩阵

| 验证 | 结果 |
|---|---:|
| `script/test_all.sh` 默认 deterministic/simulated/security/bounded-stress 门禁 | PASS |
| Swift tests | PASS，100 tests / 10 suites（含原生 clear glass 前景层级、完整尺寸/远端命中、玻璃辅助功能回退、同步 RPC envelope 解码与旧 `apc.runtime-manifest.v1` 新增字段重建回归）；`swift-testing` 固定为兼容 CI Swift 6.1.2 的 6.1.3，直接 `swift test` 与本地兼容验证入口均通过。 |
| Rust workspace tests、fmt、clippy `-D warnings` | PASS |
| 默认测试隔离与 owned-runtime 回收 | PASS：系统 Bash 3.2、Bash 5、尾斜杠/含空格临时路径和真实 reparent 场景均通过；篡改身份时 fail closed，无夹具进程残留。 |
| App lifecycle contract | PASS，8/8 |
| Swift overlay/UI offline contract | PASS，10/10 |
| develop App bundle + runtime manifest + connector repair smoke | PASS |
| develop ZIP 解压后 `codesign --verify --deep --strict` | PASS |
| 真实四连接器 gate | PASS；Codex 持久 Hook Trust 保持用户确认态 |
| 真实 Codex App Server gate | PASS |
| packaged App 真实 AI 宠物制作与七状态使用 | PASS；`星雾团子`、14/14 唯一帧、七状态逐项实机显示 |
| Renderer runtime budget | PASS |
| Computer Use UI/lifecycle/图标检查 | PASS（覆盖最终候选启动与关窗持续运行） |
| 桌宠紧凑布局回归 | PASS：Computer Use 优先完成新版启动与旧实例退出；气泡按宠物内容带重新锚定，气泡开关下移并与缩放手柄保持同列。两个控件各自由 36/38 pt 透明原生控制 panel 承载，不再受宠物主体鼠标穿透影响；系统命中检查、收起→展开、缩放增量→恢复、Overlay 10/10 离线契约与当前 Swift 套件均通过。 |
| 桌宠点击与菜单语义 | PASS：左键策略单测确认不打开菜单，AppKit 左键事件仅保留拖动生命周期；Computer Use 实机读取到“桌宠”辅助元素及“按住左键拖动，右击打开快捷菜单”说明，系统 AX 只为该元素公开 `AXShowMenu` 菜单动作；悬浮“拖动”标签已移除。 |
| Codex 气泡活动回归 | PASS：Rust 单元/transport 覆盖工具分类、完成项、稳定状态记录和 reasoning revision；实机验证新思考摘要、完成会话无残留活动、收起后再次展开。当前机器 Hook Trust 仍为用户待确认，故精确 PreToolUse 实机项不伪报通过。 |
| 最大透明气泡回归 | PASS：Computer Use 完成旧 UI Host 退出与最终 bundle 启动，当前进程从新 bundle 运行且 App/PetCore/CLI build ID 一致为 `0.1.0.1.20260716074459.78573`；macOS 26.5.1 在黑/白/灰交替条纹背景完成静默整屏与局部截图，条纹连续透过气泡，Agent 名称、会话标题、当前活动和状态位于玻璃前景层且可读。正常态为原生 `NSGlassEffectView.Style.clear`、无 tint/填充/边框/附加 opacity；系统仍保留 clear glass 固有的折射和散射。Reduce Transparency/Increase Contrast 使用外观匹配的可读性回退。证据：`dist/evidence/liquid-glass-max-clear/full-screen.png`、`bubble-detail.png`。 |
| `.petpack` producer schemas | PASS：manifest/source/brief/source-event/validation 五组 Draft 2020-12 schema 正反 fixtures；当前 Studio 元数据逐文件/逐事件 schema 验证。 |
| Portable Skill 真实前向测试 | PASS：真实图像工具生成 `Lunari` 月兔，7 状态 × 2 张透明 192×208 PNG、14 帧均有状态内变化，384×416 cover/14 帧 WebP，最终 CLI validation `ok=true`、0 warning。 |
| Portable Skill 真实修改测试 | PASS：对月兔仅重绘 `tool` 两帧为星锤动作；其余 6 状态、12 帧与基线 byte-identical，完整包通过 PetCore validation，14 frames、0 warning。 |
| 真实 Codex `generation.edit` | PASS：隔离环境直接调用真实 Codex App Server，无 GUI、无确定性 fallback；`pet_lunari` 保持同 ID 与原 created_at，产生新 revision，仅 `done` 两帧变化，其余 12/12 PNG byte-identical。source、job archive 和安装 archive 均通过 14-frame validation；人工只读检查确认两帧是蹲下→跃起并带金色月牙星环的完成动作。 |

## 8. 当前 develop 包

`script/build_app_bundle.sh` 默认生成 ad-hoc development 签名的：

- `dist/AgentPetCompanion.app`：构建产物；若仓库位于 File Provider 管理目录，Finder 元数据可能随后改变裸 bundle 的严格签名判断。
- `dist/AgentPetCompanion-develop.zip`：当前支持的非正式 develop 交付物。App 在非 File Provider 临时目录完成组装、签名和归档；ZIP 排除资源 fork/xattr，并在另一临时目录解压后再次做严格签名校验。
- 当前 develop build：`0.1.0.1.20260716074459.78573`。
- ZIP SHA-256：`72c0f00162df3f50622cc0d9d19e1eed4bc0abccf28301380223fd8e732169ff`。

该包不是 Developer ID 分发包，不承诺 Gatekeeper、公证或正式升级渠道。

## 9. 剩余工作（P2，不在本次非正式交付范围）

1. universal Release、Developer ID、hardened runtime、notarization、staple、Gatekeeper 与正式归档证据。
2. 确认并清理工作树中带 ` 2` 后缀的重复 schema、fixture、script 和 release 文档；这些可能包含用户未合并内容，不能批量删除。
3. 将 develop 已验证的 runtime manifest/回滚演练迁移到正式 CI 和安装更新通道。

## 10. 维护规则

任何改变产品行为、运行架构、RPC/schema、连接器契约、发布版本或验收结论的改动，都必须在同一变更中更新产品/技术/实施文档和本文。历史审计只追加“被后续状态替代”的提示，不回写当时证据。
