# Changelog / 版本变更记录

This file records user-visible changes. Every GitHub Release must correspond to exactly one version section named `[x.y.z] - YYYY-MM-DD`; its Git tag must be `vx.y.z`. During development, changes accumulate under `[Unreleased]`. When publishing, rename that section to the released version and create a new empty `[Unreleased]` section above it.

本文件记录用户可见变化。每个 GitHub Release 必须对应且只对应一个 `[x.y.z] - YYYY-MM-DD` 版本段，Git tag 使用 `vx.y.z`。开发中的变化统一写入 `[Unreleased]`；发布时将其改为实际版本，并在上方新建空的 `[Unreleased]`。

Use the `Added`, `Changed`, `Fixed`, `Deprecated`, `Removed`, and `Security` categories only when they apply. Do not store test logs, implementation diaries, pending-work lists, or release evidence here; those belong in CI and the GitHub Release notes for the exact artifact.

仅在适用时使用 `Added`、`Changed`、`Fixed`、`Deprecated`、`Removed` 与 `Security` 分类。不要在这里保存测试日志、实现过程、待办列表或发布证据；这些内容应进入对应产物的 CI 与 GitHub Release notes。

Keep each user-visible change in its own bullet. Write the English text first, then place its Chinese translation in a separate indented paragraph. Split unrelated changes into separate bullets instead of extending one entry.

每项用户可见变化应使用独立条目：先写英文，再将中文译文放在单独的缩进段落中。互不相关的变化应拆成多个条目，不要持续扩写同一条。

## [Unreleased]

### Fixed / 修复

- The Control Center now defers its first appearance reveal until SwiftUI finishes the current render pass, preventing the installed macOS App from opening with a blank main window.

  控制中心现在会等到 SwiftUI 完成当前渲染周期后再显示首次外观，避免已安装的 macOS App 打开后主窗口呈现空白。

## [0.4.0] - 2026-08-12

### Added / 新增

- AI Pet Maker now includes a Universal Pet Maker Skill manager for the provider-neutral `agent-pet-maker` workflow. Users can inspect its requirements and versions, install or adopt it only at `~/agent/skills/agent-pet-maker`, update or reinstall the complete App-managed directory, reveal it in Finder, and explicitly uninstall it. The App does not infer whether an Agent discovers that directory and preserves unowned conflicting content.

  AI 宠物制作现新增面向通用 `agent-pet-maker` 工作流的“通用宠物制作技能”管理器。用户可以查看技能依赖与版本，仅在 `~/agent/skills/agent-pet-maker` 安装或纳入管理，更新或重新安装完整受管目录，在 Finder 中打开目录，并明确卸载；App 不推断 Agent 是否识别该目录，也不会覆盖存在冲突的非受管内容。

### Changed / 变更

- Protected PR delivery now dispatches exact-main validation before bounded source cleanup, then removes a newly merged direct, task, or train source branch with an exact-head atomic lease. Closed-PR replay never deletes a recreated ref, even at the old SHA, and resolves the authoritative merged identity from the single-PR API so a temporarily incomplete PR-list response cannot strand main validation. Agent guidance now requires an explicit stage, cached-diff audit, commit, clean-worktree, push/PR lifecycle and a repository-wide post-merge worktree/branch audit; Release guidance also recognizes both trusted exact-commit main `push` and `workflow_dispatch` proofs.

  受保护 PR 交付现在会先派发精确 main 验证，再通过绑定精确 head 的原子 lease 有界清理本次新合并的 direct、task 或 train 源分支；closed PR replay 即使遇到旧 SHA 重建的 ref 也绝不删除，并会从单 PR API 解析权威合并身份，避免 PR 列表响应暂时缺字段时让 main 验证永久搁置。Agent 规范现要求显式暂存、cached diff 审计、提交、clean worktree、推送/PR 的完整生命周期，以及合并后的全仓 worktree/分支审计；Release 规范也统一认可受信任的同 commit main `push` 与 `workflow_dispatch` 证明。

- Local pre-push validation is now a bounded formatting, syntax, contract, and compile gate, while required GitHub CI runs complete source checks in parallel across Rust shards, Swift interaction proof, integration contracts, overlay validation, stress, and App assembly. Agents choose either a direct hotfix/small PR to protected `main` or coordinated task PRs to one shared train followed by a final train PR; repository-owned ready PRs are squash-merged by a trusted workflow only after `Required CI`. A successful trusted `main` validation emits an exact-commit source proof that GitHub Release reuses before dual-architecture packaging, and an explicit Release dispatch can bind a missing tag only after that proof succeeds. Fail-closed ruleset automation protects both `main` and integration trains after the new required check is proven remotely.

  Complete direct and final train PR proofs are now promoted to the squash-merged `main` commit when their repository, PR run, ordered parents, artifact, and exact Git tree all match. Run/attempt-bound merge tickets prevent a completed check from being reused after a PR changes base or lane. Each Rust shard now emits its own run/attempt completion marker, and a separate exact-set gate blocks candidate, main, and `Required CI` proof issuance if GitHub's matrix summary omits a shard. The replay-safe post-CI merger explicitly dispatches validation for the exact main SHA, avoiding GitHub's suppression of ordinary events produced by `GITHUB_TOKEN`; control-plane PRs fail closed to trusted manual merge so they cannot rewrite and prove their own gate. This removes the duplicate post-merge Rust, Swift, integration, stress, overlay, and App-assembly run while preserving a main-commit-bound Release proof; promotion uncertainty automatically falls back to complete main CI, and task PRs merged into a train still run only their path-scoped checks.

  本地预推送验证现收敛为有界的格式、语法、合同与编译门禁；必选 GitHub CI 则通过 Rust 分片、Swift 交互证明、集成合同、悬浮层验证、压力与 App 组装并行完成全量源码检查。Agent 会在热修复/小范围 direct PR 与“多个任务 PR 汇入共享 train、再由 train PR 至 main”之间选择；仓库内 ready PR 仅在 `Required CI` 成功后由受信任 workflow 执行 squash 合并。受信任的 `main` 验证会生成绑定精确 commit 的源码证明，GitHub Release 在双架构打包前复用该证明，显式 Release dispatch 也只有在证明成功后才能绑定缺失 tag。fail-closed ruleset 自动化会在新必选检查已由远端证明后保护 `main` 与集成 train。

  direct PR 与最终 train PR 的完整证明现可在仓库、PR run、有序父提交、artifact 与精确 Git tree 全部匹配时晋升到 squash 合并后的 `main` commit。绑定 run/attempt 的 merge ticket 会阻止 PR 更换 base 或通道后复用旧检查。每个 Rust 分片现会分别生成绑定 run/attempt 的完成标记，独立的精确集合门禁会在 GitHub 矩阵汇总遗漏任一分片时阻止候选、main 与 `Required CI` 证明签发。可重放恢复的 CI 后合并器会为精确 main SHA 显式派发验证，从而避开 GitHub 对 `GITHUB_TOKEN` 所产生普通事件的抑制；控制面 PR 会 fail closed 转为受信任人工合并，不能重写并自证门禁。此机制删除合并后重复的 Rust、Swift、集成、压力、悬浮层与 App 组装任务，同时保留绑定 main commit 的 Release 证明；晋升存在任何不确定性时都会自动回退完整 main CI，合入 train 的 task PR 仍只运行按路径检查。

- Grouped and flat desktop session bubbles now retain exactly one body message: the newest Agent reply or explicit thinking/plan text, shown in at most two lines. Tool and other lifecycle activity continue to update the separate top-right status indicator without entering or replacing the body, while navigation notices keep their existing priority.

  按 Agent 聚合与平铺展示的桌面会话气泡现在都只保留一条正文消息：最近的 Agent 回复或明确的思考/计划文本，最多展示两行。工具及其他生命周期活动仍会更新右上角独立状态标识，但不会进入或替换正文；导航提示继续保持原有优先级。

### Fixed / 修复

- The first-run demo now hands each pet action to Metal without retaining or cross-fading the prior action's drawable, preventing stalled-looking playback and multiple action frames from appearing together.

  首次运行演示现在会在各宠物动作之间正确交接 Metal 渲染内容，不再保留或交叉淡化上一动作的 drawable，避免播放看似卡帧及多个动作帧同时出现。

- Child and sub-Agent sessions are now consistently excluded from desktop bubbles, including Pi parallel-review sessions whose reserved `subagent-*` identity lacks a `parentSession` header.

  子会话和子 Agent 会话现在会被一致地排除在桌面气泡之外，包括缺少 `parentSession` 头、但使用保留 `subagent-*` 标识的 Pi parallel-review 会话。

- Pi connection checks now accept the current diagnostic canary as proof that the managed Extension loaded, even when the probe process later exits because no model is configured, so the App no longer keeps asking for an irrelevant restart.

  Pi 连接检查现在会将当前诊断 canary 视为受管 Extension 已加载的证据；即使探针进程随后因未配置模型而退出，App 也不会继续提示无关的重启操作。

- A Pi prompt submitted without a selected model now reaches the desktop bubble as an immediate failed state instead of remaining indefinitely at session started; the connector uses Pi's public model-presence context without reading provider credentials.

  Pi 未选择模型时提交的消息现在会立即把桌面气泡更新为失败状态，不再无限停留在“会话已开始”；连接器仅使用 Pi 公开的模型存在状态，不读取任何提供商凭据。

## [0.3.6] - 2026-08-11

### Changed / 变更

- The README desktop hero now shows all three bundled pets alongside collapsed, expanded, and Agent-grouped expanded session bubbles captured from isolated test sessions, preserving the native Liquid Glass backdrop treatment alongside longer message, activity, and mixed runtime-state examples.

  README 桌面主视觉现横向展示三个内置宠物，以及从隔离测试会话实机截取的折叠、展开和按 Agent 聚合展开气泡；原生液态玻璃背景效果得到保留，并补充了更长的消息、活动内容与混合运行状态。

### Fixed / 修复

- Fixed the App-managed Codex Hook file being rejected because it contained an unsupported `release_version` field. Hook versions are now bound through the plugin manifest and exact content verification, and a Hook loading failure is shown as requiring investigation or repair instead of incorrectly promising that restarting Codex will fix it.

  修复 App 管理的 Codex Hook 文件因包含不受支持的 `release_version` 字段而被拒绝的问题。Hook 版本现在通过插件清单与精确内容校验绑定；Hook 加载失败会提示需要检查或修复，不再错误地承诺重启 Codex 即可解决。

## [0.3.5] - 2026-08-11

### Fixed / 修复

- Official macOS archives are now built with Apple Swift 6.2 or newer and the macOS 26 SDK while retaining a macOS 14 deployment target. Release validation rejects an old linked SDK, a raised minimum system version, or non-weak Liquid Glass symbols, and runs the same candidate on macOS 15 compatibility hosts and macOS 26. The Control Center and session bubbles therefore use native Liquid Glass on macOS 26 and the authored system-material fallback on macOS 14 and 15.

  正式 macOS 归档现强制使用 Apple Swift 6.2+ 与 macOS 26+ SDK 构建，同时保持 macOS 14 最低运行版本。发布门禁会拒绝旧链接 SDK、被抬高的最低系统版本或非弱链接的 Liquid Glass 符号，并让同一候选产物分别在 macOS 15 兼容主机与 macOS 26 上运行。因此控制中心与会话气泡会在 macOS 26 使用原生液态玻璃，在 macOS 14、15 使用既定的系统材质回退。

## [0.3.4] - 2026-08-11

### Changed / 变更

- New installations now show pet-bubble sessions in one cross-Agent flat stack by default; grouping sessions by Agent remains available in Pet Configuration.

  全新安装的宠物气泡现在默认将所有 Agent 会话放入同一个平铺堆栈；仍可在“宠物配置”中开启按 Agent 聚合。

- The English and Chinese READMEs now share three privacy-safe product screenshots covering the desktop-pet status experience, the five-area control center, and AI Pet Maker.

  中英文 README 现在共用三张不含隐私信息的产品截图，分别展示桌宠状态体验、包含五个功能区域的控制中心，以及 AI 宠物制作。

### Fixed / 修复

- Fixed a macOS 26 crash when Metal completed a desktop-pet frame on its background completion queue while the callback was incorrectly isolated to the main actor.

  修复 macOS 26 上 Metal 在后台完成队列结束桌宠帧渲染时，回调被错误隔离到主 Actor 而导致的闪退。

- Cold startup now joins the single PetCore bootstrap before handling the App's initial activation refresh, avoiding a transient offline state and duplicate recovery while a new installation validates and seeds its bundled pets.

  冷启动处理 App 首次激活刷新前，现在会先汇入唯一的 PetCore 启动流程，避免全新安装校验并种入内置宠物期间短暂误报离线及重复触发恢复。

## [0.3.3] - 2026-08-10

### Changed / 变更

- Desktop-pet hit testing no longer reads global cursor, button, or modifier-key state; creates a system event tap or cross-application event monitor; or installs a keyboard event monitor. Window-local cursor polling plus App-local mouse events preserve transparent-pixel passthrough and dragging without requesting macOS Input Monitoring access.

  桌宠命中测试不再读取全局光标、鼠标按键或修饰键状态，不再创建系统事件 tap、跨 App 事件监听或键盘事件监听；现在通过窗口内光标轮询与 App 内鼠标事件，在无需申请 macOS“输入监控”权限的前提下保留透明像素穿透与拖动能力。

### Fixed / 修复

- Fixed an Agent connection that reported a managed path conflict and could not be repaired after an update, when the only difference was that its managed files came from an earlier App-managed install. Ownership of a managed root is now proven by its plugin manifest and hooks, and inside a root this App provably wrote, Set Up or Repair replaces the App's own files at its own fixed paths. Recognizing an installed Studio Skill no longer depends on a maintained list of past release digests, where one missing entry left an install with no working repair.

  修复更新后 Agent 连接被判定为受管路径冲突且无法修复的问题：此前只要受管文件来自更早的 App 安装就会触发。受管根目录的归属现在由插件清单与 Hook 判定；在可证明由本 App 写入的根目录内，“一键设置或修复”会覆盖本 App 自己固定路径上的文件。识别已安装的 Studio 技能不再依赖需要人工维护的历史发布摘要名单 —— 该名单缺少任何一条，都会让对应安装彻底失去修复能力。

- Every App-managed Codex artifact now states its own release version: the plugin manifest, the installed hooks file, and both Skills. Agent Connections reports the hook as its own component and shows each component's installed version, so a single stale Skill or hook is named directly instead of inheriting the plugin's version.

  本 App 管理的每个 Codex 组件现在都带有自己的版本标识：插件清单、已安装的 Hook 文件与两个技能。Agent 连接会把 Hook 作为独立组件列出，并显示每个组件各自的已安装版本；单个陈旧的技能或 Hook 会被直接指名，而不再沿用插件的版本。

- Fixed managed connector conflicts being reported as a symbolic link or non-directory path even when the path shape was correct. The blocking check now states the real reason and names the exact path, and the update notice no longer directs users to Set Up or Repair while that action skips the affected Agent.

  修复受管连接器冲突一律被描述为符号链接或非目录路径的问题（即使路径形态本身正确）。阻断检查项现在说明真实原因并给出具体路径；在“一键设置或修复”会跳过该 Agent 的状态下，更新提示也不再引导用户去点击它。

- Fixed a launch crash on macOS 26 caused when the notification authorization completion arrived on a background queue while its closure was isolated to the main actor. Notification authorization now uses the async API and resumes on the correct executor.

  修复 macOS 26 上通知授权完成回调在后台队列返回、但闭包被隔离到主 Actor 时触发的启动崩溃；通知授权现改用 async API，并在正确的执行器上恢复。

- Fixed long Control Center pages being clipped below the window when the shared detail layout let nested scroll regions expand to their ideal content height. Pet Library details, AI Pet Maker forms, and Agent Connection cards now receive the finite visible viewport and scroll normally.

  修复控制中心共用详情布局让内层滚动区域按理想内容高度展开、导致长页面在窗口下方被裁切的问题；宠物库详情、AI 宠物制作表单与 Agent 连接卡片现在会获得有限的可见视口并可正常滚动。

## [0.3.1] - 2026-08-09

### Added / 新增

- AI Pet Maker is now a persistent split-view session workspace: the single unfinished task stays pinned above terminal history, while the right side switches in place between an untimed draft and a ChatGPT-style, paged, user-visible timeline. Native Codex input requests, waiting or recoverable continuation, backend-authoritative duration, wake/restart refresh, and actionable macOS notifications are first-class App flows; ChatGPT conversation rendering is no longer a product dependency.

  AI 宠物制作现改为持久化左右分栏会话工作台：唯一未终结任务固定置顶，右侧在不计时草稿与类似 ChatGPT、可分页的用户可见时间线之间原地切换。Codex 原生输入请求、等待或可恢复继续、后端权威时长、唤醒/重启刷新及可操作的 macOS 通知都成为 App 内正式流程，不再依赖 ChatGPT 对会话内容的呈现。

- AI Pet Maker now keeps a persistent newest-first history for every creation or revision task, including failed, canceled, and no-result jobs. Users can inspect the brief, status, timestamps, result metadata, key progress, and a bounded Codex excerpt in the App; when App Server confirms that the exact persistent thread still exists and is not archived, the detail offers a safe **View Full Conversation in ChatGPT** action. Studio threads are given bounded user-facing names, and their internal hooks no longer leak into the desktop-pet session bubble.

  AI 宠物制作现在会持久保留按时间倒序排列的全部制作与修改任务，包括失败、取消及未产出宠物的任务。用户可在 App 内查看需求、状态、时间、结果元数据、关键进度及受限 Codex 摘要；仅当 App Server 现场确认对应持久会话仍存在且未归档时，详情才提供安全的“在 ChatGPT 中查看完整会话”操作。Studio 会话会获得有界的用户可读名称，其内部 Hook 也不再误入桌宠会话气泡。

- AI Pet Maker now accepts validated JPG/JPEG reference images alongside PNG and WebP, checks Codex App Server readiness before enabling creation, and shows a live, selectable, independently scrollable Codex conversation during an active Studio job. Missing or unresponsive Codex installations are explained in-page and cannot start a job.

  AI 宠物制作现除 PNG、WebP 外也支持经过校验的 JPG/JPEG 参考图；页面会在开放制作前检查 Codex App Server 可用性，并在 Studio 任务期间实时显示可选择文本、可独立滚动的 Codex 会话。Codex 未安装或无响应时会在页面内明确说明，并禁止发起任务。

- Pet Configuration can now switch desktop session bubbles between the existing per-Agent groups and a shared cross-Agent tray with one native-glass card per session. The flat tray uses one global folded stack, shows each card's Agent identity, prioritizes Needs input > Blocked > Ready > Running, and freezes order within a turn so repeated thinking, planning, tool, message, or snapshot updates cannot make concurrent cards jump; a real new turn moves once inside its state partition.

  “宠物配置”现可在既有的按 Agent 聚合气泡与跨 Agent 统一会话列表之间切换；平铺模式中每个会话使用一张带 Agent 标识的原生玻璃卡，共用一个全局折叠栈，按“等待你操作 > 阻塞 > 已完成 > 运行中”排序，并在同一轮次内冻结顺序，因此反复思考、规划、调用工具、消息流式更新或快照刷新都不会让并发卡片跳动；真正的新轮次只会在所属状态区间内移动一次。

- Pet Configuration → Appearance now offers a two-tier bubble text size. **Standard** keeps the current size, and **Larger** scales every desktop bubble text role by the same factor, so the size relationships between agent name, session title, detail lines, and status badges stay unchanged. The choice persists through PetCore, and bubble height plus click regions are re-measured for the selected tier.

  “宠物配置 → 外观”新增两档气泡字号：**标准**保持当前字号，**更大**按同一比例放大桌面气泡内所有文字，因此 Agent 名称、会话标题、详情行与状态标签之间的字号比例保持不变。该选择通过 PetCore 持久化，气泡高度与点击区域也会按所选档位重新计算。

- Added restrained App-local pet interactions: an idle primary click uses a short `acknowledge` action, pointer-down without bubble content adds a 160 ms low-amplitude press response, and direct dragging selects authored `drag_left` or `drag_right` loops. These never emit Agent events, change semantic state, add gaze tracking, or create post-release motion.

  新增克制的 App 本地宠物交互：空闲时主点击播放短促 `acknowledge` 动作；没有气泡内容时，按下增加 160 毫秒低幅轻按反馈；直接拖动则选择制作好的 `drag_left` 或 `drag_right` 循环。这些交互不会产生 Agent 事件、改变语义状态、加入视线追踪或产生释放后运动。

- Added the user's `桃蕾` character as the third read-only built-in companion alongside `星雾团子` and `Bytebud 字节芽`, with the same immutable seeding, preview, enable, and export behavior.

  将用户的 `桃蕾` 角色作为第三只只读内置宠物，与 `星雾团子`、`Bytebud 字节芽` 一同提供，并遵循相同的不可变种入、预览、启用与导出规则。

- The selected-pet preview in Pet Library now starts with the package's `idle` action and offers all nine portable actions as a local preview selector. Choosing an action plays its authored frames, per-frame timing, playback mode, and reduced-motion behavior without changing the desktop pet or emitting an Agent event.

  宠物库的已选宠物预览现在会默认播放宠物包的 `idle` 动作，并提供全部九种通用动作的本地预览选择；选择动作后会按原始帧、逐帧时序、播放模式及减弱动态效果设置播放，不会改变桌面宠物，也不会产生 Agent 事件。

- Agent Connections now verifies typed App-managed connector and bundled-Skill versions plus exact content internally, then lists only those App-installed items inside the corresponding expanded Agent. Codex shows its independent plugin-bundle version; Claude Code, Pi, and OpenCode carry and report the App release that installed their managed connector. Each item shows its verified active version, while a missing or mismatched marker names the App-required version and keeps setup/repair available. The App no longer scans or presents user-managed plugins, extensions, packages, or Skills.

  Agent 连接现在会在内部验证类型化的 App 受管连接器、随附技能版本及精确内容一致性，并仅在对应 Agent 的展开内容中列出这些由本 App 安装的项目；Codex 显示独立的插件能力包版本，Claude Code、Pi 与 OpenCode 则在受管连接器中携带并报告安装它们的 App 发行版本。每项都会显示已校验的当前版本；版本标记缺失或不匹配时会明确列出本 App 所需版本，并保留设置/修复入口。App 不再扫描或展示用户自行管理的插件、扩展、软件包或技能。

- Added an in-App language preference with Follow System, English, and Simplified Chinese choices. The typed PetCore setting persists across launches and updates the Control Center, desktop pet, menus, and accessibility presentation immediately.

  新增 App 内语言设置，支持跟随系统、English 与简体中文；该类型化 PetCore 设置会跨启动持久化，并立即切换控制中心、桌宠、菜单及无障碍呈现。

- Added one typed pet-resource recovery path across first run, Pet Library, and AI Pet Maker. It revalidates the immutable package and atomically restores the cover plus all nine animation actions before preview-dependent actions return.

  在首次体验、宠物库与 AI 宠物制作中新增统一的类型化资源恢复路径；恢复会重新校验不可变宠物包，并原子重建封面与全部九种动画动作，完成后才重新开放依赖预览的操作。

### Changed / 变更

- Local validation now has a change-scoped pre-push gate and an explicit source-fingerprinted resume mode for full-gate diagnosis. Cheap localization parity fails before compiler-heavy suites, environment-mutating generation lifecycle tests run in isolated child processes instead of one poisonable global lock, and one content-verified interaction proof is reused across offline overlay and App assembly in the same validation run; uncached `test_all.sh` remains the CI/Release authority.

  本地验证现新增变更范围预推送门禁，以及用于完整门禁排错、按源码指纹恢复的显式模式。本地化一致性会在重编译测试前快速失败；会修改环境变量的制作生命周期测试改在隔离子进程中运行，不再依赖可能 poison 的全局锁；同一次验证中，经过内容核验的交互证明会由离线悬浮层与 App 组装复用；CI/Release 仍以无缓存的 `test_all.sh` 为权威入口。

- AI Pet Maker history details now open directly into the production conversation without repeating its brief as a separate title and summary. Session status, progress, elapsed time, and available actions now share one adaptive horizontal bar below the conversation; destructive deletion remains directly visible, while supplementary actions collapse into a More menu only when space is constrained.

  AI 宠物制作历史详情现在会直接展示制作会话，不再将同一份需求重复渲染为独立标题和摘要；会话状态、进度、耗时与可用操作统一收拢到会话下方的自适应横向操作栏，删除操作始终直接可见，仅在空间不足时将补充操作折叠到“更多”菜单。

- Agent Connections now surfaces the automatic startup light check as **Basic check complete** or a specific actionable problem instead of collapsing every light result into **Not checked**. The first visit to the page in each App session requests one serialized full runtime check after the authoritative four-Agent snapshot and any release connector convergence are ready; fresh runtime results are reused, and **Check All** remains available for explicit retries.

  Agent 连接现在会将启动时自动完成的轻量检查显示为“基础检查完成”或具体可处理问题，不再把所有轻量结果统一折叠成“未检查”。每次 App 会话首次进入该页面时，会等待四个 Agent 的权威快照及发行版连接器收敛就绪后，串行触发一次完整运行检测；已有的新鲜运行结果会直接复用，“全部检查”仍可用于显式重试。

- Removed the nonstructural separator lines between the Control Center titlebar and page content, between Pet Configuration's subpage switch and form, and around AI Pet Maker's header and split workspace. Existing spacing, pane sizing, scrolling, selection, and split dragging remain unchanged.

  移除控制中心标题栏与页面内容之间、“宠物配置”子页面切换与表单之间，以及“AI 宠物制作”页头与分栏工作区周围的非结构性分割线；现有间距、面板尺寸、滚动、选择与分栏拖拽行为保持不变。

- AI Pet Maker's production list now shares the same adaptive native bar surface as the App sidebar instead of painting a separate gray List background. Each record gains an inset adaptive divider and more vertical breathing room, while the slightly wider default split gives task titles and status badges more room without compromising compact-window compatibility.

  AI 宠物制作的制作记录列表现在与 App 侧栏共用同一套自适应原生栏背景，不再绘制独立的灰色 List 底色；每条记录新增内缩的自适应分隔线与更充足的纵向留白，略微加宽的默认分栏也为任务标题和状态标识提供了更多空间，同时继续适配紧凑窗口。

- AI Pet Maker now uses one fixed page header for its identity and primary new-pet action, followed by two clearly bounded workspace panes: a counted, grouped creation history on the left and the selected task conversation on the right.

  AI 宠物制作现在使用固定的页面信息栏承载页面身份与“制作新宠物”主操作，下方以两个边界清晰的工作区分别呈现左侧带数量与分组的制作历史，以及右侧所选任务会话。

- The selected-pet detail now keeps its identity on the left and one state-aware accessory on the right: inactive pets show a compact **Use this pet** action, while the active or enabling pet shows a compact status surface. The former full-width action and left-stacked status no longer displace the preview.

  已选宠物详情现在将名称与来源保持在左侧，并在右侧统一显示一个状态感知组件：未使用的宠物显示紧凑的“使用这只宠物”操作，正在使用或启用中的宠物显示紧凑状态面板；原先占满整行的操作与左侧堆叠状态不再向下挤压预览区。

- Pet Library now uses a scalable master-detail workspace on wide windows: the collection keeps search and source filtering visible, shows filtered and total counts, adapts between three, two, and one card columns, and scrolls independently from the selected pet's preview and actions. Compact windows retain the existing stacked presentation.

  宠物库在宽窗口中现采用可扩展的主从分栏工作台：宠物集合会常驻显示搜索与来源筛选、呈现筛选数与总数、在三列/两列/单列卡片间自适应，并与所选宠物的预览及操作区域独立滚动；紧凑窗口继续使用既有的纵向布局。

- Post-update warnings now identify whether the blocker is missing bundled pets, the local service, or a named Agent connection. Connector conflicts, unavailable hosts, failed refreshes, and incomplete runtime verification each show their own recovery steps; Agent Connections opens the affected Agent automatically, and the old generic **Retry Update** action is replaced by a targeted check after the user completes the stated fix. A successful check reruns authoritative convergence and persists its receipt so the same warning does not return at the next launch.

  更新后的警告现在会明确区分内置宠物缺失、本地服务异常及具体 Agent 连接问题；连接文件冲突、Agent 宿主不可用、刷新失败与运行时验证未完成分别提供对应解决步骤。“Agent 连接”会自动展开受影响的 Agent，原先笼统的“重试更新”也改为在用户完成提示操作后执行针对性复检；复检成功后会重新完成权威收敛并持久化回执，避免同一警告在下次启动时再次出现。

- Transparent-area click-through is now a non-configurable desktop-overlay invariant, so Pet Configuration no longer exposes a switch that could make the pet or bubble panel block unrelated apps. Legacy stored values remain wire-compatible but are normalized to enabled.

  透明区域穿透现改为不可配置的桌面浮层固有行为，因此“宠物配置”不再提供可能让宠物或气泡面板阻挡其他 App 的开关；旧版存储值继续保持协议兼容，但会统一归一为启用。

- Pet Configuration now keeps its forms focused on settings and renders the result in a persistent **Pet Preview** at the bottom of the sidebar. The preview stays visible on all five feature pages and even while the real desktop pet overlay is hidden; it continues to reflect the current pet, size, theme, bubble text scale, enabled sources/events, per-Agent grouping or cross-Agent cards, folded/expanded multi-session preference, and semantic session states. The multi-session default remains directly configurable in both grouping modes.

  “宠物配置”现在让表单只承载设置项，并把效果统一渲染到侧栏底部持续可见的“宠物预览”中；无论当前打开五个功能页中的哪一页、真实桌宠浮层是显示还是隐藏，该预览都会保持展示，并继续反映当前宠物、尺寸、主题、气泡字号、启用来源/事件、按 Agent 聚合或跨 Agent 独立卡、多会话折叠/展开偏好及语义会话状态。“多会话默认显示”在两种聚合模式下都可直接配置。

- AI Pet Maker now keeps brief creation and all task history in one permanent split workspace. The previous history toolbar entry, modal sheet, outcome-filter surface, and duplicated single-session workspace were removed. Terminal deletion still removes only private task data and its workspace, preserves any committed Pet Library pet, and repairs retry ancestry.

  AI 宠物制作现将新建需求与全部任务历史统一放在常驻分栏工作台中；此前的历史工具栏入口、模态 sheet、结果筛选界面及重复的单会话工作区均已移除。删除终态记录仍只移除私有任务数据及工作区，保留已写入宠物库的宠物，并修复重试祖先关系。

- Agent host versions are now informational for Codex, Claude Code, Pi, and OpenCode rather than hard compatibility gates. Connection health is determined by the exact managed connector, native-host/runtime probes, local event channel, and current contract receipts; future, prerelease, older, or unparseable version strings no longer block an otherwise working integration. Connector JSON and field-shape failures now emit bounded, content-free structured diagnostics without recording the rejected value, messages, tool data, paths, identifiers, or credentials.

  Codex、Claude Code、Pi 与 OpenCode 的宿主版本现仅作为诊断信息，不再充当兼容性硬门槛。连接健康改由精确的受管连接器、原生宿主/运行探针、本地事件通道及当前契约回执共同判定；未来版、预发布版、旧版或无法解析的版本字符串不再阻断其他链路均正常的集成。连接器 JSON 与字段形状解析失败时会写入有界、无内容的结构化诊断，不记录被拒绝的原值、消息、工具数据、路径、标识或凭据。

- Pet Maker and in-App Pet Studio now repair chroma-contaminated RGB again at the final runtime Alpha boundary after the sole permitted downscale, without changing Alpha or opaque-interior pixels. Their shared gate keeps canvas contact and continuous or visible fringe as hard failures, while only a closed allowance of isolated low-Alpha evidence can proceed to mandatory five-background review. Transparency recovery is now bounded to failing frames, one edge contraction, and optional 0.25-pixel feathering for visible stair-stepping before source regeneration; the Skills no longer enumerate nearby crops, similar key colors, or feather values.

  Pet Maker 与 App 内 Pet Studio 现在会在唯一允许的缩小完成后，于最终运行时 Alpha 边界再次修复受键色污染的 RGB，且不改变 Alpha 或不透明内部像素。共享门禁继续将画布接触、连续或肉眼可见的色边作为硬失败，仅允许闭合上限内的孤立低 Alpha 证据进入强制五底色复核。透明化恢复现限制为只处理失败帧、一次边缘收缩，以及仅在收缩产生可见锯齿时使用 0.25 像素羽化，之后直接重生成源图；两个技能不再枚举相邻裁切、近似键色或羽化值。

- AI Pet Maker cancellation is now an irreversible, task-scoped shutdown protocol: it freezes duration at the cancel request, interrupts the exact active turn, observes completion when possible, stops the owned App Server process group, acknowledges the worker stop, archives the exact Studio thread, and only then reaches terminal `canceled`. Failed cleanup remains an explicit non-resumable cleanup state and retries automatically; canceled tasks never expose resume, retry, or conversation-opening actions.

  AI 宠物制作取消现为不可逆、严格限定到当前任务的关闭协议：取消请求时冻结时长，精确中断当前 turn，尽可能确认完成事件，停止该任务拥有的 App Server 进程组，确认 worker 已停止，再归档对应 Studio thread，之后才进入终态 `canceled`。清理失败时会停留在明确且不可恢复的清理状态并自动重试；已取消任务不再提供继续、重试或打开会话入口。

- AI Pet Maker's style choices now use distinct adaptive button surfaces: unselected choices keep a visible neutral fill and border, hover adds an accent cue, and the selected style uses a solid accent fill with high-contrast text. The group remains clear in light, dark, and increased-contrast appearances instead of blending into the form background.

  AI 宠物制作中的风格选项现改用边界清晰的自适应按钮：未选中项保留可见的中性底色与描边，悬停时显示强调色反馈，选中项使用实色强调背景与高对比文字；在浅色、深色及“提高对比度”外观中都不会再与表单背景混在一起。

- Pet Configuration's logical desktop-pet size range is now 100–300 pt instead of 80–224 pt; the 112 pt default, 1 pt step, bottom-center anchor, keyboard/VoiceOver adjustment, and authored animation timing remain unchanged. During upgrade, a previously saved 80–99 pt value is normalized once to 100 pt.

  “宠物配置”中的桌宠逻辑尺寸范围由 80–224 pt 调整为 100–300 pt；默认值仍为 112 pt，并继续保持 1 pt 步进、底部中心锚点、键盘/VoiceOver 调整及原始动画时序不变。升级时，之前保存的 80–99 pt 会一次性归一到 100 pt。

- The menu-bar companion now explicitly uses the system's compact `.menu` presentation and a dedicated 24×24 pt intrinsic AppKit image. The previous label visually scaled the 1024×1024 source PNG but left its intrinsic status-item layout at roughly 1024 pt, which expanded the dropdown across most of the display; the corrected icon compensates for the artwork's transparent padding and is visually balanced with neighboring status items while both menu content branches retain their compact intrinsic width.

  菜单栏桌宠现在显式使用系统紧凑 `.menu` 样式，并使用固有尺寸真正为 24×24 pt 的专用 AppKit 图像。此前标签虽然把 1024×1024 原始 PNG 视觉缩小，却让状态项布局仍保持约 1024 pt，导致下拉菜单横跨大半屏幕；修正后的图标补偿了图稿自身的透明留白，与相邻状态栏项目视觉均衡，同时两个菜单内容分支继续保持紧凑固有宽度。

- Custom floating surfaces now consistently use native macOS Liquid Glass, with the variant chosen per surface: desktop session bubbles keep the Regular lens, while overlay controls use `clear.interactive()` and noninteractive floating labels use `.clear`. Standard controls remain system-owned and ordinary content cards stay outside the glass layer.

  自定义浮动界面现已统一使用 macOS 原生 Liquid Glass，并按界面性质选择材质档位：桌面会话气泡保留 Regular 镜片，悬浮控件使用 `clear.interactive()`，非交互浮动标签使用 `.clear`；标准控件仍由系统管理，普通内容卡片不进入玻璃层。

- Desktop session bubbles keep their shared 20 pt continuous corner radius and full-strength native Regular lens while adding only a paired sub-point light/dark optical rim. The rim keeps the rounded boundary readable when one bubble crosses bright and dark backdrops; it adds no fill, tint, opacity change, shadow, or second material, and the App keeps its existing adaptive 344 pt multi-session layout, Agent/session hierarchy, hit regions, navigation, dismissal, and drag attachment.

  桌面会话气泡继续使用统一的 20 pt 连续圆角与满强度原生 Regular 镜片，仅补充一组不足 1 pt 的明暗双层光学边缘；当同一气泡横跨明亮与深色背景时，圆角边界仍可辨识，同时不增加填充、着色、透明度变化、阴影或第二层材质，并继续保持既有的 344 pt 自适应多会话布局、Agent/会话层级、命中区、跳转、收起及拖拽附着。

- Desktop bubbles no longer expose or persist a custom transparency value. On macOS 26 they always use the public, untinted, full-strength Regular Liquid Glass lens (`alphaValue = 1`, `tintColor = nil`) and let the system adapt blur, luminance, and refraction to the live desktop backdrop. The narrow AppKit bridge remains only to keep the native optical layer below sharp SwiftUI content in a transparent `NSPanel`; older systems and reduced-transparency accessibility retain their native fallbacks.

  桌面气泡不再提供或持久化自定义透明度数值。macOS 26 上始终使用公开、无着色、满强度的 Regular Liquid Glass 镜片（`alphaValue = 1`、`tintColor = nil`），由系统根据实时桌面背景自适应处理模糊、亮度和折射。精简后的 AppKit 桥仅用于在透明 `NSPanel` 中将原生光学层稳定置于清晰的 SwiftUI 内容下方；旧系统与“降低透明度”无障碍设置继续使用原生回退。

- Multi-session bubble ordering and its aggregate status tint now share one Needs input > Blocked > Ready > Running priority. Previously PetCore selected the correct attention session while the Swift group tint could still turn red for a lower-priority failure.

  多会话气泡的排序与汇总状态色现统一采用“需要输入 > 阻塞 > 已完成 > 运行中”的优先级；此前 PetCore 会正确选择需关注会话，但 Swift 组状态色仍可能被较低优先级的失败染成红色。

- Pet Maker and in-App Pet Studio now compare Motion QA's per-frame body-anchor and baseline path with each action card and deterministic pose guide. Intentional travel and easing remain valid; when registration drift is the only defect, they first try a QA-digest-bound transparent-frame correction using integer whole-frame translation, then require renewed animation review and Motion QA instead of immediately spending another generation.

  Pet Maker 与 App 内 Pet Studio 现在会将 Motion QA 报告的逐帧身体锚点、基线轨迹与动作卡及确定性姿势导图对照；符合设计的整体移动和缓动仍然有效。若仅有主体定位漂移，它们会先尝试绑定当前 QA 摘要、只做整像素整帧平移的透明帧校正，再重新目检动画并运行 Motion QA，而不是立即再次生图。

- Pet Maker and in-App Pet Studio now give every model-generated multi-frame action a deterministic pose guide plus a separate deterministic size-reference image derived from the same slot, centered crop, safe-box, baseline, and global-scale geometry. This prevents oversized or drifting figures in Dreamina 5.0 Pro action rows from making a safe 576×624 crop impossible. The shared transparency gate still reports visible key-like pixels for five-background review, but a nonzero count no longer fails a frame by itself; actual silhouette fringe, canvas contact, and visible contamination remain blockers. The bundled Codex capability version is now `0.5.4`.

  Pet Maker 与 App 内 Pet Studio 现为每个模型生成的多帧动作同时提供确定性姿势导图和独立的确定性尺寸参考图，两者共用同一组槽位、居中裁剪、安全区、基线与全局尺度几何；这会避免 Dreamina 5.0 Pro 动作横排中人物过大或尺寸漂移，导致无法安全裁出 576×624。共享透明化门禁仍会报告可见的类键色像素以供五种背景复核，但计数非零不再单独导致单帧失败；真实的轮廓溢色、画布接触和可见污染仍会阻断验收。随附 Codex 能力包版本现为 `0.5.4`。

- The two pet-making Skills now use progressive disclosure: their entry files contain only routing and executable workflow, while the shared V3, visual-production, transparency, security, and provider-specific Dreamina contracts each have one owner. Repeated manifest examples, retired-field/version commentary, and the non-production deterministic Studio preview helper were removed from the distributed Skills; that helper now exists only as a PetCore rejection fixture. Maker CLI discovery also recognizes only the current `AgentPetCompanion.app` bundle name.

  两个宠物制作技能现采用渐进披露：入口文件只保留能力分流与可执行流程，V3、视觉生产、透明化、安全及 Dreamina 提供方专用规范各自只有一个归属。重复的 manifest 示例、已退出字段/版本说明及非生产用途的 Studio 确定性预览 helper 已从分发技能中删除；该 helper 仅作为 PetCore 拒绝路径测试夹具保留。Maker CLI 探测也只识别当前的 `AgentPetCompanion.app` 包名。

- New pet creation now defaults to 50 authored frames across the nine V3 actions: `idle` uses 6 frames over 2,000 ms with its existing periodic cooldown behavior, `waiting` uses 8 frames over 1,060 ms per pass and plays three passes before settling on its final frame, and `failed` uses 8 frames over 1,060 ms per pass while retaining its three-pass final-frame settle. Both pet-making Skills, their helpers, App/PetCore creation defaults, and producer guidance are synchronized. Users may still request any structurally valid V3 timing, and existing valid V3 packages remain accepted without forced migration or rewriting.

  后续新宠物制作默认改为九动作共 50 个创作帧：`idle` 使用 6 帧、单轮 2,000 毫秒并保持原有周期冷却行为；`waiting` 使用 8 帧、单轮 1,060 毫秒，播放三轮后停在最后一帧；`failed` 使用 8 帧、单轮 1,060 毫秒，并保持三轮播放后停在最后一帧。两个宠物制作技能、辅助脚本、App/PetCore 创建默认值及生产指南已同步。用户仍可指定任何结构有效的 V3 时序，已有合规 V3 宠物包无需强制迁移或改写。

- The portable Maker and Studio Skills now share one provider-aware image-production guide. ChatGPT/Codex built-in `imagegen` is explicitly bounded to its approximate 1K–2K output envelope and `low`/`standard` pet production, while the portable Maker can use Dreamina `5.0Pro` at 4K for `high` 576×624 production; Studio rejects `high` before generation and gives that concrete handoff instead of attempting or downgrading it. The shared guide defines the canonical full-body identity base, image-to-image action rows, deterministic frameless equal-scale pose guides, reference responsibilities, exact 4/5/6/8-frame Dreamina canvases, one-result credit policy, terminal async polling, scale/order/background constraints, and defect-specific recovery.

  通用 Maker 与 Studio 技能现在共用一份按生图提供方分流的生产指南：ChatGPT/Codex 内置 `imagegen` 明确受其约 1K–2K 输出能力约束，只用于标清与标准宠物制作；通用 Maker 可使用 Dreamina `5.0Pro` 的 4K 生图制作高清 576×624 宠物，Studio 则在生图前拒绝 `high` 并给出这一明确交接，不会尝试生成或静默降级。共享指南统一定义完整全身身份基准图、图生图动作横排、脚本生成的无框等尺度姿态图、参考图职责、Dreamina 精确的 4/5/6/8 帧画布、单图 credits 策略、异步终态轮询、尺度/顺序/背景约束及按缺陷处理的恢复方式。

- `.petpack` is now an intentionally incompatible V3-only contract with exactly six semantic actions plus `acknowledge`, `drag_left`, and `drag_right`. Thinking, tool, and done play bounded three-pass bursts and then present idle without losing the underlying semantic state; waiting and failed retain explicit persistent settles. V1/V2 packages are rejected and must be recreated, with no migration or aliasing shim.

  `.petpack` 现已升级为有意不兼容旧版的 V3-only 契约，固定包含六个语义动作以及 `acknowledge`、`drag_left`、`drag_right`；思考、工具与完成动作播放三遍有界动作后在保留底层语义状态的同时回到 idle，等待与失败继续保留明确的持续收束姿势。V1/V2 宠物包会被拒绝并必须重新制作，不提供迁移或别名兼容层。

- Pet Studio and portable Pet Maker now require fully opaque flat-background source art for every new or regenerated frame and share one deterministic transparency and source-size normalization pipeline. The pipeline keeps source-resolution transparent masters, removes only spatially connected background, uses a conservative soft Alpha matte, reconstructs RGB only at the silhouette boundary, performs at most one linear-light premultiplied-Alpha downscale, and emits checkerboard/white/gray/black/complementary-background QA. Key-color conflicts and non-uniform backgrounds fail safely instead of changing subject colors or punching holes; optional sure-foreground masks cover enclosed background, and edge contraction is capped at one runtime pixel.

  Pet Studio 与通用 Pet Maker 现在要求每个新增或重制帧先生成完全不透明的纯色背景原图，并共用同一条确定性的透明化与来源尺寸规范化流水线。该流程保留来源分辨率透明母版，只移除与画布边界空间连通的背景，采用保守渐变 Alpha，仅在人物轮廓边缘重建 RGB，最多执行一次线性光预乘 Alpha 缩放，并生成棋盘格、白、灰、黑及底色互补背景 QA。底色与主体冲突或背景不均匀时会安全失败，不会改动人物颜色或挖空；可选“确定前景”遮罩用于处理轮廓内孔洞，Alpha 收缩最多为一个运行尺寸像素。

- Pet Studio and portable Pet Maker now judge authored actions by their actual runtime-size visual quality instead of fixed motion-layer counts or whole-subject displacement thresholds. Intentional travel, bounce, rotation, recoil, squash/stretch, scale, and baseline motion are allowed when identity, crop, props, timing, and loop/final-pose quality remain convincing; automated displacement/shape/scale/loop measurements are review evidence, while edge clipping and synthetic interpolation remain hard failures.

  Pet Studio 与通用Pet Maker 现在按运行尺寸下的实际动作观感验收，不再要求固定动作层数，也不再因宠物整体位移幅度越过阈值而直接失败；只要身份、构图、道具、节奏及循环/终止姿态观感可靠，整体移动、弹跳、旋转、后坐、挤压伸展、缩放与基线变化均可接受。位移、轮廓、缩放及循环测量改为人工复核证据，边缘裁切与合成插帧仍是硬失败。

- Studio and the portable Maker now share one visual-production and source-size normalization contract plus one PetCore final verifier. Maker finalization, Studio, and strict Studio import use the same decoded changed-state, frame-digest freshness, exact review coverage, preview, registration, interpolation, and timing-revision decisions; only workspace/source identity, output policy, and commit conflicts remain host-specific.

  Studio 与通用 Maker 现在共用一份视觉生产及来源尺寸规范化契约，并共用同一个 PetCore 最终验证器。Maker 最终化、Studio 与严格 Studio 导入会使用完全相同的解码后变更状态、帧摘要新鲜度、精确审核覆盖、预览、注册稳定性、插帧及时间修订判断；各宿主仅保留工作区/来源身份、输出策略与提交冲突处理。

- The provider-neutral `agent-pet-maker` Skill now directs every state as one runtime-readable performance: action complexity follows the pet and intended result instead of mandatory layer counts, multi-batch rows carry accepted boundary poses forward, and visual review explicitly checks the result at 192 × 208. Provider-specific anatomy, furniture, and platform workarounds remain outside the portable Skill contract.

  通用 `agent-pet-maker` 技能现在会把每个状态导演为一段在运行尺寸下可读的表演：动作复杂度由宠物形态与目标观感决定，不再要求固定动作层数；多批次动作会继承已通过的边界姿态；视觉审核也会明确在 192 × 208 下检查结果。特定提供方的解剖结构、家具及平台规避方案仍不进入通用技能契约。

- Pet Library imports now show an in-page current-file indicator, completed-file progress for multi-package selections, an honest long-import explanation, and a persistent success or retryable failure result.

  宠物库导入现在会在页面内显示当前文件、多包导入的已完成进度、长时间导入说明，以及可持续查看的成功结果或可重试失败结果。

- The Control Center sidebar now shows the validated current-pet preview centered above its existing name and enabled-state row.

  控制中心侧栏现在会在现有宠物名称与启用状态行上方，居中显示经过校验的当前宠物预览形象。

- Agent connection warnings now name the actual required action—such as Hook authorization, an Agent update, settings permission, a full host restart, local-service recovery, or managed repair—and replace misleading real-task prompts while a prerequisite is blocked.

  Agent 连接警告现在会准确说明所需操作，例如 Hook 授权、更新 Agent、设置授权、完全重启宿主、恢复本地服务或修复受管连接；前置条件受阻时也不再显示误导性的真实任务提示。

- Expanded Agent cards now show only the action required by the current state plus one **More** menu. Routine rechecks, test messages, safe reconfiguration, and confirmed removal stay available without presenting four equal-weight buttons; the former connection test is now named **Send Test Message** to describe what users actually see.

  展开的 Agent 卡片现在只直接显示当前状态所需的操作，并提供一个“更多”菜单；日常复查、测试消息、安全重新设置及需确认的移除仍可使用，但不再以四个同权重按钮铺开；原“测试连接”也改名为“发送测试消息”，与用户实际看到的结果一致。

- Service & Diagnostics now shows PetCore, local RPC, event-channel, desktop-pet, and bounded diagnostic-package information directly inside Service Status; the separate Technical Details block and expansion step have been removed.

  “服务与诊断”现在会在“服务状态”中直接展示 PetCore、本地 RPC、事件通道、桌宠及有界诊断包信息，并移除独立的“技术详情”区块与展开步骤。

- `.petpack` V3, PetCore, Pet Library, and the renderer support three exact runtime tiers: low 192×208, standard 384×416, and high 576×624. Image models are not required or trusted to return those dimensions exactly: a complete 12:13 source crop may equal or exceed the target and the shared pipeline may downscale it once, while upscaling remains invalid. Every action owns its exact `frame_durations_ms`, one of five structural playback modes with a fixed action/mode pairing, and a reduced-motion frame; the runtime plays those durations directly without sampling, retiming, restarting unchanged semantic state, or catch-up bursts after a stall. The portable Maker can build high packages only with sufficient source resolution. ChatGPT/Codex built-in `imagegen` and the Codex-backed in-App Studio remain limited to low and standard and reject high before generation.

  `.petpack` V3、PetCore、宠物库与渲染器支持三组精确运行画质：标清 192×208、标准 384×416 与高清 576×624。无需也不能信任生图模型精确返回这些尺寸：完整的 12:13 来源裁片可以等于或大于目标，并由共享流水线一次缩小，但仍禁止放大。每个动作独立声明精确的 `frame_durations_ms`、五种结构化播放方式之一并遵守固定动作/模式配对，以及减弱动态效果代表帧；运行时直接按制作时长播放，不抽帧、不重定时、不重启未变化语义状态，也不会在卡顿后快速补帧。通用 Maker 仅可在来源分辨率足够时制作高清包；ChatGPT/Codex 内置 `imagegen` 与 App 内基于 Codex 的 Studio 仍只支持标清和标准，并在生图前拒绝高清请求。

- Pet production now locks a canonical base for the selected runtime tier, serializes one complete state per ordinary batch, crops stable equal-size 12:13 source cells without resampling or per-pose fitting, and derives exact-tier runtime frames through the shared transparency pipeline with at most one downscale. Edge clipping plus synthetic crossfade, morph, optical flow, transformed copies, and interpolation remain rejected. Incremental and final QA render a keyframe sheet plus one actual-duration `authored_timing` preview per state; final QA also renders an 8–12 second presence preview bound to all nine actions and rejects semantic activity that freezes in under one second or loops mechanically. Digests bind the complete timing/frame contract, and fresh per-state review covers identity, distinct poses, action readability, anatomy, props, crop, continuity, and loop/settle quality after any downscale.

  宠物制作现在会为所选运行画质锁定规范基准图，普通流程每批串行完成一个状态，使用等大的稳定 12:13 来源单格无重采样裁切且不按姿势单独贴合，再通过共享透明化流水线以最多一次缩小生成精确运行尺寸帧。边缘裁切及合成叠化、变形、光流、变换副本和插值仍会被拒绝。增量与最终 QA 会生成关键帧表及每个状态按实际逐帧时长播放的 `authored_timing` 预览；最终 QA 还会生成绑定全部九动作的 8–12 秒存在感预览，并拒绝不到一秒就静止或持续机械循环的语义动作。摘要会绑定完整时序/帧契约，任意缩小后仍需重新复核身份一致性、姿势差异、动作可读性、解剖结构、道具、裁切、连续性及循环/收束效果。

- Desktop placement now has one presentation authority. Dragging derives every sample from an absolute screen anchor, hard-clamps it, and commits the exact release position once; stale snapshots, late or out-of-order acknowledgements, and failed saves cannot move the presented pet. Bubble and menu panels move as child windows of the pet root. Display size is now a persisted logical width controlled only by the accessible 100–300 pt slider in Pet Configuration, with a 112 pt default and height derived from the fixed canvas ratio.

  桌宠位置现在只有一个呈现权威。拖动以屏幕绝对坐标锚点推导每个样本、直接硬边界约束，并在释放时只提交一次准确位置；陈旧快照、延迟或乱序回执及保存失败都不能移动已经呈现的桌宠。气泡与菜单作为宠物根窗口的子窗口整体移动。显示尺寸改为持久化逻辑宽度，只能通过“宠物配置”中支持无障碍操作的 100–300 pt 滑块调整，默认 112 pt，高度由固定画布比例推导。

- Strict Pet Studio generation now checkpoints durable work across up to six same-thread 25-minute turns, preserving the canonical base and every passed state row while resuming only the earliest incomplete or failing state.

  严格 Pet Studio 制作现在会在同一线程的最多六个 25 分钟 turn 之间保存持久进度，保留规范基准图及每个已通过状态行，并且只从最早未完成或未通过的状态续做。

- Pet Library and AI Pet Maker now align their page-level toolbar actions with the trailing controls used throughout the Control Center.

  宠物库与 AI 宠物制作现在将页面级工具栏操作与控制中心其他页面一致地靠右对齐。

- Agent Connections now separates local integration health from real-task verification, exposes **Needs Repair** only with executable typed authority, and keeps one page-level primary check action.

  Agent 连接现在将本地集成健康度与真实任务验证分开；仅在存在可执行的类型化权限时显示“需要修复”，并保持页面级单一主检查操作。

- A healthy local Agent connector without ordinary-task evidence now appears as neutral **Awaiting verification** instead of green **Connected**; the card asks for one real Agent task while keeping setup and repair reserved for actual local faults.

  本地连接器健康但尚无真实任务证据时，Agent 卡片现以中性的“待验证”呈现，不再显示绿色“已连接”；卡片会提示运行一次真实 Agent 任务，而设置与修复仍只用于真实的本地故障。

- Agent Connections now uses a single-selection accordion: selecting an Agent opens only its concise verification, recovery guidance, and available actions, while connector internals, runtime terms, component contracts, and managed-location counts stay hidden from the ordinary UI.

  Agent 连接现在采用单选手风琴布局：选择一个 Agent 后只展开简洁的验证状态、处理提示与可用操作；连接器内部信息、运行时术语、组件契约及受管位置数量不再出现在普通界面。

- Agent sessions now use seven stable atomic events—`start`, `thinking`, `plan`, `tool`, `waiting`, `done`, and `failed`—with one label authority across connectors, PetCore, the App, menus, and configuration. Badges preserve the filtered event (or a closed stable tool subtype), while pet reactions are sparse: `start` has no action, `thinking` and `plan` share the package `thinking` action, and the other events use their namesake package states. Prompt admission, timestamps, completion tails, and high-frequency deltas cannot invent thinking or planning; tool completion stays tool, and waiting means the Agent is blocked on the user.

  Agent 会话现在统一使用七个稳定原子事件：`start`、`thinking`、`plan`、`tool`、`waiting`、`done` 与 `failed`，连接器、PetCore、App、菜单和配置共用同一套事件文案。Badge 保留筛选后的事件（工具事件可细化为闭集且稳定的工具子类型），宠物动作采用稀疏映射：`start` 不触发动作，`thinking` 与 `plan` 共用宠物包的 `thinking` 动作，其余事件使用同名宠物状态。请求接收、时间戳变化、完成尾事件及高频 delta 不会伪造思考或规划；工具完成仍属于工具事件，waiting 明确表示 Agent 阻塞并等待用户。

- Desktop bubbles now show one attention-prioritized or latest session per collapsed Agent and every concrete session in the bounded local snapshot when expanded. Each row reserves its two detail lines for bounded Agent messages and normalized semantic reasoning, command, tool input/output, error, or activity text instead of inserting generic lifecycle copy or stringifying raw host objects. The latest Agent reply always occupies the first detail line when available; the more frequently changing reasoning/tool activity follows on the second line. Running rows and badges stay visually neutral; status backgrounds are used only for **Completed** (green), **Waiting for You** (orange), and **Failed** (red). Collapsed groups keep their aggregate status visible with **failure > confirmation > completion > running** priority.

  桌宠气泡现在每个折叠 Agent 显示一个优先提醒或最新会话，展开后直接显示本地有界快照中的全部具体会话；每行标题下的两条详情专门用于展示有界 Agent 消息，以及归一化后的 reasoning、命令、工具输入输出、错误或其他有意义的活动文本，不再插入固定生命周期文案，也不会把宿主原始对象直接序列化到界面。有最新 Agent 回复时固定放在第一行，更新更频繁的思考与工具活动放在第二行。运行中会话与 badge 保持中性，仅“已完成”使用绿色、“等待你操作”使用橙色、“执行失败”使用红色背景；折叠会话组采用“失败 > 待确认 > 完成 > 进行中”的聚合优先级。

- Refined the control center around solid content surfaces and one prominent action per context, with larger-text layout, VoiceOver reading order, reduced-transparency fallbacks, and increased-contrast borders.

  控制中心改为实色内容层与每个上下文一个突出操作，并完善大字体布局、VoiceOver 阅读顺序、降低透明度回退与增强对比度边框。

### Fixed / 修复

- Managed PetCore runtime storage now retains only the current build, its last-known-good rollback build, and any build referenced by a live rollback checkpoint after a healthy commit. Complete unreferenced App-owned runtime directories are pruned without touching user data or foreign entries, preventing repeated development launches and upgrades from accumulating a new PetCore/CLI copy indefinitely.

  受管 PetCore 运行时存储现在会在健康提交后仅保留当前构建、上一可用回滚构建，以及仍被有效回滚检查点引用的构建；完整且无引用的 App 自有运行时目录会被清理，同时不触碰用户数据或外来条目，避免重复开发启动与升级无限累积 PetCore/CLI 副本。

- Desktop pets that finish a `burst_then_idle` action now publish the settled idle frame's real visible bounds and Alpha click mask while retaining ownership under the originating semantic Agent event. Session bubbles therefore remain attached to the visible pet instead of overlapping its head, and transparent-pixel hit testing follows the frame actually on screen; late geometry from a previous semantic state is still rejected.

  桌宠完成 `burst_then_idle` 动作后，现在会在继续归属于原始 Agent 语义事件的同时，发布 settled idle 帧真实的可见包围盒与 Alpha 点击遮罩。会话气泡会继续贴合屏幕上实际可见的宠物，不再覆盖宠物头部，透明像素命中也会跟随真正显示的帧；来自上一语义状态的迟到几何回调仍会被拒绝。

- Submitting a new or edited pet now switches immediately from the draft to the exact created Maker session even when the history list has not caught up yet. Active, waiting, recoverable, and cancellation-cleanup sessions no longer offer a ChatGPT jump that the desktop client would reject as in use elsewhere; completed, canceled, and terminal-failed sessions retain the action when their exact released thread is available. Session switching and post-delete selection also clear stale reply text and synchronize both detail and paged messages.

  提交新建或修改宠物后，即使历史列表尚未同步，也会立即从草稿切换到服务端返回的精确制作会话。运行中、等待输入、可恢复及取消清理中的会话不再提供会被 ChatGPT 以“正在其他位置使用”拒绝的跳转；已完成、已取消及终态失败会话在精确已释放线程可用时保留该入口。切换会话和删除后选中相邻会话时，也会清理陈旧回复草稿并同步详情与分页消息。

- Technical-information disclosures now make their entire header row clickable and keyboard-focusable instead of relying on the small chevron target, with matching hover and VoiceOver expanded/collapsed feedback everywhere the shared component appears.

  技术信息折叠区现在会让整排标题都可点击并可通过键盘聚焦，不再依赖狭小的箭头命中区；所有复用该组件的页面也会统一提供悬停反馈及 VoiceOver 展开/收起状态。

- Every AI Pet Maker session state now uses the same opaque status-panel structure below the shared metrics bar: pending, running, waiting for input, cancellation cleanup, completed, recoverable or terminal failure, and canceled. Only the semantic color, icon, copy, and optional inline reply/continue control change; result previews remain clipped to a fixed tile and timeline messages never show through underneath.

  AI 宠物制作的待开始、运行中、等待回复、取消清理、完成、可恢复或终结失败及已取消状态，现在都在共用指标栏下使用同一套不透明状态面板；仅语义色、图标、说明及可选的内嵌回复/继续控件发生变化。结果预览仍固定裁切在独立区域内，会话消息也不会从下方透出。

- Pet Library's AI modify, export, history, and delete controls now retain their own accessibility identities instead of inheriting one shared action-bar identifier. Modal edit/history presentation waits for the originating accessibility press to finish, and its layout containers preserve their descendant controls, so VoiceOver and accessibility-driven activation can address, open, and operate the intended flow reliably.

  宠物库的 AI 修改、导出、历史与删除控件现在会保留各自的无障碍身份，不再继承同一个操作栏标识；编辑/历史模态页会等待发起它的无障碍按压完成，其布局容器也会保留后代控件，因此 VoiceOver 与基于无障碍的激活可可靠定位、打开并操作目标流程。

- A deferred App update no longer creates a deadlock by disabling the only action that can finish a recoverable AI Pet Maker job. Starting another pet remains blocked while convergence waits, but the preserved job can now be continued and its button accurately reflects whether resume is available.

  延后的 App 更新不再因禁用唯一能完成可恢复 AI 宠物制作任务的操作而形成死锁；收敛等待期间仍会阻止另起宠物，但现在可以继续保留任务，且“继续”按钮会准确反映恢复是否可用。

- A recoverable AI Pet Maker failure no longer blocks the App/PetCore runtime handoff needed to install a fix and continue the preserved job. Current PetCore marks failed resumable work as replacement-safe, while the App safely rechecks older runtimes through their authoritative snapshot and decodes the restored failed-session projection instead of looping startup recovery.

  可恢复的 AI 宠物制作失败不再阻塞安装修复并继续保留任务所必需的 App/PetCore 运行时交接；当前 PetCore 会将可续做的失败任务标记为可安全替换，App 也会通过旧运行时的权威快照安全复核，并正确解码恢复后的失败会话投影，不再反复进入启动恢复。

- AI Pet Maker now recognizes Agent Pet Maker's private workspace layout, bound Motion QA/review evidence, and actual image-generator producer identity when completing strict full-source jobs. A fully validated pet no longer loops through no-progress continuation turns or fails before import merely because its source and evidence use the Maker helper's current paths and metadata contract.

  AI 宠物制作现在会在严格 full-source 任务收尾时识别 Agent Pet Maker 的私有工作区布局、已绑定的 Motion QA/review 证据及真实图像生成器身份；已完整通过校验的宠物不会再仅因源码、证据采用 Maker helper 的当前路径与元数据契约而反复进入无进展续接或在导入前失败。

- AI Pet Maker now keeps the selected session header and reply/continue area visible while only its message timeline scrolls. Legacy failures without a safe recovery checkpoint now say why they cannot continue in place and direct users to the preserved ChatGPT conversation or brief-copy path; recoverable failures continue to resume the same job, thread, and workspace.

  AI 宠物制作现在会固定显示所选会话的顶部信息与回复/继续区域，仅让消息时间线独立滚动。对于没有安全恢复检查点的旧失败记录，界面会明确说明无法原地继续的原因，并引导用户查看保留的 ChatGPT 会话或复制 brief；可恢复失败任务仍会在同一 job、线程与工作区内继续。

- The Control Center sidebar now reaches the native window edges as one system-material surface, and its live pet/message preview is a pinned bottom pane instead of a list safe-area inset, so resizing or switching pages cannot make the preview disappear.

  控制中心侧栏现在以同一块系统材质直接延伸至原生窗口边缘；宠物与消息实时预览也改为固定的底部区域，不再依赖列表安全区插入，因此调整窗口或切换页面都不会让预览消失。

- Codex sessions stopped by the user now leave the running state on the next App Server refresh. PetCore distinguishes their persisted `interrupted` completion boundary from externally running turns that another App Server instance reports as `interrupted`, so the desktop bubble updates promptly without prematurely ending long tasks. Claude Code, Pi, and OpenCode terminal mappings remain covered by the same cross-Agent lifecycle regression suite.

  用户手动停止 Codex 会话后，现在会在下一次 App Server 刷新时退出运行状态。PetCore 会用持久化的 `interrupted` 完成边界，将其与另一个 App Server 实例同样报告为 `interrupted` 的外部运行中任务区分开，因此桌宠消息气泡能及时更新，同时不会提前终止长任务；Claude Code、Pi 与 OpenCode 的终止映射继续由同一套跨 Agent 生命周期回归测试覆盖。

- Desktop-pet pointer ownership now resolves on a listen-only system event tap before AppKit chooses a target window, eliminating the first-down race that made an opaque pet intermittently impossible to drag. Ownership uses the current frame's exact Alpha mask and each session bubble's rounded card bounds—without a broad approach zone or key-window exception—so transparent pet pixels and space outside bubbles continue operating the app underneath; a missing or stale mask still falls back to the geometric pet body.

  桌宠指针归属现在会在 AppKit 选择目标窗口前，通过只监听的系统事件 tap 完成判定，从根源消除不透明宠物偶发无法拖动的首次按下竞态。归属严格使用当前帧 Alpha 遮罩与每张会话气泡的圆角卡片边界，不再使用扩大接近区或 key window 例外，因此宠物透明像素与气泡外区域仍可操作下层 App；遮罩缺失或过期时则继续回退到宠物几何区域。

- PetCore connection-status snapshots no longer rebuild Codex evidence from the complete retained event payload after every incoming hook. Evidence scans decode only the six bounded verification fields and coalesce per-Agent dirtiness for five seconds, while explicit connection operations and artifact changes still refresh immediately; high-volume Codex activity can no longer starve local socket requests and cause a false offline or installer-verification timeout.

  PetCore 的连接状态快照不再在每个新 Hook 到达后都从完整保留事件 payload 重建 Codex 证据；扫描现在只解码六个有界核验字段，并按 Agent 将脏状态合并五秒，显式连接操作及受管产物变化仍会立即刷新，因此高频 Codex 活动不会再挤占本地 socket 请求并造成误报离线或安装核验超时。

- Pet Library finite action previews now honor renderer completion: `burst_then_idle` actions such as done, thinking, and tool, plus `once_then_return` acknowledge, return visually to `idle` after their authored run. Reduced Motion uses the same authored completion duration instead of leaving the representative frame indefinitely. Pet or action changes also keep Metal eligible to present while an opaque fallback masks its retained drawable until the exact new render identity reaches the display, preventing a one-frame double image without deadlocking renderer readiness.

  宠物库中的有限动作预览现在会处理渲染完成回调：完成、思考、工具等 `burst_then_idle` 动作及 `once_then_return` 的回应动作会在原始播放结束后视觉回到 `idle`；“减弱动态效果”也使用相同的原始完成时长，不会无限停留在代表帧。切换宠物或动作时，Metal 会继续获得提交新帧的机会，同时由不透明兜底层遮住保留的旧 drawable，直到精确的新渲染身份真正到达屏幕，从而既消除一帧双影，也避免渲染就绪状态死锁。

- A successful exact runtime connection check now clears stale post-update attention only for the checked Agent, without running the broad managed-connector refresh, changing another Agent, or fabricating a convergence receipt. AI Pet Maker also reports the real higher-priority convergence, active-job, or Codex blocker before brief validity, so a completed brief is no longer mislabeled as incomplete.

  精确的运行时连接检查成功后，现在只会清除被检查 Agent 的陈旧更新提醒，不会运行全量受管连接器刷新、修改其他 Agent 或伪造收敛回执；AI 宠物制作也会先报告真实的更新收敛、活动任务或 Codex 阻塞，再判断 brief 是否有效，因此已完成的 brief 不会再被误报为未完成。

- Pi desktop bubbles now read `tool_execution_start.args` and finalized `ThinkingContent.thinking` using the host's actual field shapes. Explicit finalized thinking becomes bounded `thinking` activity, tool-start details no longer disappear behind a contentless update, and malformed message/tool fields produce private structured parse warnings instead of failing silently.

  Pi 桌宠气泡现按宿主真实字段读取 `tool_execution_start.args` 与已完成的 `ThinkingContent.thinking`；明确完成的思考内容会成为有界 `thinking` 活动，工具开始事件不再用空内容覆盖已有详情，消息或工具字段异常时也会写入隐私安全的结构化解析警告，而非静默丢失。

- AI Pet Maker no longer fails healthy work at a fixed six-turn checkpoint limit. Studio now continues while durable workspace artifacts are advancing, pauses only after three consecutive no-progress continuation segments (with a separate 12-hour safety window), and reports that pause without blaming a healthy Codex App Server. Failed jobs offer **Continue** in the same job, Codex thread, and workspace, preserving generated assets and passed QA; **Start Over** is a separate confirmed action that clearly creates a new job, and cancellation now requires confirmation. The creation page also shows the real current action, typed stage, continuation count, elapsed time, 30-second heartbeat health, and streamed Agent replies.

  AI 宠物制作不再因固定六个 turn 的 checkpoint 上限而终止仍在稳定推进的任务。Studio 会在工作区持久化产物持续变化时继续，仅在连续三个续接段都无进展时暂停（另有独立的 12 小时安全窗口），且不会把这种暂停误报为健康 Codex App Server 的连接故障。失败任务现在可在同一 job、Codex 会话与工作区内“继续制作”，保留已生成素材及通过的 QA；“重新开始”改为独立且需确认的操作，并明确说明会创建新任务；取消任务也需要确认。制作页同时展示真实当前动作、类型化阶段、续接次数、运行时长、30 秒心跳健康状态及流式 Agent 回复。

- Desktop session bubbles no longer reveal a gray rectangular panel around their rounded cards. Each native glass surface now owns its SwiftUI foreground through the supported AppKit content composition, keeping the surrounding borderless panel transparent.

  桌面会话气泡的圆角卡片周围不再显示灰色直角面板；每个原生玻璃表面现通过 AppKit 支持的内容组合方式承载 SwiftUI 前景，使周围的无边框面板保持透明。

- A session bubble no longer loses its visible rounded boundary when it straddles a bright window and a dark desktop. Native Regular Liquid Glass still samples the live backdrop at full strength, while a restrained dual-tone sub-point optical rim supplies the missing contrast without introducing a rectangular plate or opaque veil.

  当会话气泡横跨明亮窗口与深色桌面时，其圆角边界不再因背景同化而消失；原生 Regular Liquid Glass 仍以满强度采样实时背景，仅用克制的明暗双层亚像素光学边缘补足对比度，不会引入矩形底板或不透明遮罩。

- Desktop session bubbles now reserve their full two-line message height before, during, and after an Agent reply, so an empty, one-line, or two-line update cannot resize the glass card.

  桌面会话气泡现在会在 Agent 回复前、回复中及回复后始终预留完整的两行消息高度，因此无消息、一行消息或两行消息更新都不会改变玻璃卡片尺寸。

- Pet activation now reserves the SQLite writer before reading the current pet state, so concurrent Agent-event writes no longer reject the first click during a deferred transaction upgrade. Once PetCore confirms the transaction, the App also reflects the committed active pet before its full snapshot refresh, preventing a transient refresh failure from restoring the Enable button and prompting duplicate clicks.

  宠物启用现在会在读取当前宠物状态前先取得 SQLite 写入权，避免并发 Agent 事件写入在延迟事务升级时拒绝第一次点击；PetCore 确认事务成功后，App 也会在全量快照刷新前立即呈现已提交的启用状态，避免临时刷新失败让“启用”按钮重新出现并诱发重复点击。

- `.petpack` validation now rejects preview covers whose encoded PNG color type has no Alpha channel, whose transparent coverage is below 1%, or whose outer background contains a high-confidence baked-in checkerboard pattern. Import, runtime-asset repair, export, and CLI validation share the same gate, while localized checker patterns on a character or prop remain valid.

  `.petpack` 校验现在会拒绝以下预览封面：PNG 编码颜色类型不含 Alpha 通道、透明像素覆盖不足 1%，或外层背景存在高置信度的烘入棋盘格图案。导入、运行时资源修复、导出与 CLI 校验共用同一门槛；角色或道具上的局部格纹仍然有效。

- Standalone and Agent-grouped desktop session bubbles now use the same full-strength native Regular Liquid Glass lens for both the foreground card and every exposed rear card in a folded multi-session tray. Opaque-looking `.regularMaterial` plates, gray veils, opacity reduction, and synthetic rear-card outlines no longer replace live desktop transparency, refraction, and specular edge response; only a restrained semantic tint remains for completed, waiting, and failed states.

  独立会话与按 Agent 聚合的桌面会话气泡现在会在前景卡片以及多会话折叠托盘中每一张露出的后方卡片上使用同一套全强度原生 Regular Liquid Glass 镜片；显得不透明的 `.regularMaterial` 材质板、灰色遮罩、透明度衰减和合成叠卡描边不再取代实时桌面背景的透明、折射与高光边缘响应，仅为完成、等待和失败状态保留克制的语义色调。

- Standalone session cards again use the same semantic state color as Agent-grouped session rows: completed receives a restrained green card tint, waiting on the user orange, and failed red. A matching compact symbol remains in the existing `Agent · App/CLI` metadata line so state is not communicated by color alone. Running states stay neutral, and the treatment adds no button, capsule, border, or reserved message column.

  独立会话卡片现在重新采用与按 Agent 聚合会话行一致的语义状态色：完成使用克制的绿色卡片底色、等待用户操作为橙色、失败为红色；既有“Agent · App/CLI”元信息行中同时保留对应的小图标，避免只依赖颜色表达状态。运行中状态保持中性，整套处理不会增加按钮、胶囊、边框或占用消息正文列。

- Ungrouped desktop session cards now keep `Agent · App/CLI`, title, and latest content inside one glass frame. A folded multi-session tray shows one or two complete material cards offset behind the foreground card, making the stack visible without nested tray-only outlines; flat and grouped cards share the same restrained surface rim. The redundant destination arrow is removed so message copy uses the full row width. Clicking the foreground session in any folded multi-session card—Agent-grouped or ungrouped—expands the list first; only a later click on an expanded session navigates. The pet-side disclosure moves exactly one level per click—expanded → folded → hidden when collapsing, and hidden → folded → expanded when revealing. The **Larger** bubble text tier is also reduced from 1.25× to 1.15×.

  非 Agent 聚合的桌面会话卡片现在会把“Agent · App/CLI”、标题和最新内容放在同一个玻璃框内；多会话折叠态会在前景卡片后方错位露出一至两张完整材质卡片，既能看出叠放层次，也不会形成仅用于叠卡的嵌套轮廓；平铺卡片与分组卡片共用同一套克制的表面光学边缘。多余的跳转箭头也已移除，让消息使用整行宽度。无论是否按 Agent 聚合，点击折叠态多会话卡片的顶层会话都会先展开列表；只有之后点击展开列表中的具体会话才会跳转。宠物旁的展开/收起按钮每次只移动一级：收起时按“全部展开 → 单卡折叠 → 完全隐藏”，展开时按“完全隐藏 → 单卡折叠 → 全部展开”往返；“更大”气泡字号也由 1.25 倍收窄为 1.15 倍。

- Standalone desktop session cards now use a compact two-line `title · latest content` hierarchy instead of crowding the title, Agent, surface, and status into one row. Expanded flat trays keep their disclosure chevron beside the pet and use one priority-first top-to-bottom reading order, so the folded foreground card remains the first card after expansion whether the bubble is above or below the pet.

  独立桌面会话卡片现在采用紧凑的两行“标题 · 最新内容”层级，不再把会话标题、Agent、入口类型和当前状态挤在同一行；展开的平铺会话把收起箭头留在桌宠旁，并统一使用高优先级优先的从上到下阅读顺序，因此无论气泡位于桌宠上方还是下方，折叠前景卡展开后仍是列表第一项。

- Desktop session projection now keeps only root Agent sessions. OpenCode `parentID`, Codex App Server sub-Agent source kinds/`parentThreadId`, Pi `parentSession`, and Claude sidechain lineage produce a content-free suppression marker that removes any already-projected child card and blocks its later events; parent IDs are never persisted, titles are never used as a heuristic, and sub-Agent work may remain only as activity on the owning root session.

  桌面会话投影现在只保留 Agent 根会话。OpenCode 的 `parentID`、Codex App Server 的子 Agent 来源类型与 `parentThreadId`、Pi 的 `parentSession` 以及 Claude sidechain 血缘会生成不含内容的抑制标记：已投影的子会话卡片会立即移除，后续事件也不会再次生成卡片；父会话 ID 不会持久化，标题不会被用作猜测依据，子 Agent 工作最多只作为所属根会话的活动信息保留。

- OpenCode Plugin activation no longer deadlocks by entering its own session API before registration, which previously left the TUI and `debug info` blank and made Agent Connections repeatedly ask for a restart. Existing-session lineage discovery is now queued for the first task after activation while every session-bearing live hook waits behind the same gate, so startup completes and an already-running child Agent still cannot enter the desktop projection; content-free cleanup delivery remains asynchronous.

  OpenCode Plugin 激活不再在注册完成前进入它自己的会话 API，避免之前导致 TUI 与 `debug info` 空白、Agent 连接反复提示重启的死锁。现在会把已有会话的父子关系解析排到激活后的第一个任务，同时让所有携带会话的实时 Hook 共用同一道门；因此启动可以完成，已运行的子 Agent 仍不会进入桌面投影，不含内容的清理回传保持异步。

- Codex connection verification now recognizes the ChatGPT-bundled `0.147.0-alpha.1.2` after an exact local App Server schema audit confirmed the same 70 notifications and required `hooks/list`, `thread/list`, and `thread/read` surface. Other versions remain fail-closed until separately audited.

  对 ChatGPT 内置 `0.147.0-alpha.1.2` 进行精确的本地 App Server schema 审计、确认仍为相同的 70 个通知及必需的 `hooks/list`、`thread/list` 与 `thread/read` 接口后，Codex 连接验证现在会识别该版本；其他版本在单独审计前仍保持默认拒绝。

- Codex capability convergence now recognizes the exact Studio Skill shipped by the App-managed `0.4.6` plugin, so retrying an update can safely replace that unmodified bundle with `0.5.4` instead of misreporting a managed-path conflict. Customized or unsafe files remain protected.

  Codex 能力收敛现在会识别由本 App 管理的 `0.4.6` 插件所附带的精确 Studio Skill，因此重试更新可以安全地将未修改的旧能力包升级至 `0.5.4`，不再误报受管路径冲突；自定义或不安全文件仍会受到保护。

- Claude Code connection repair now converges when user settings also contain a preserved foreign or stale similarly named helper: repair and verification share the same strict App-ownership rule. The Agent Connections page also withholds its green repaired notice whenever the refreshed status still has blocking items.

  当用户设置中同时存在被保留的外部 Hook 或同名旧辅助程序时，Claude Code 连接修复现在仍能正确收敛；修复与验证共用同一套严格的 App 所有权规则。若刷新后的状态仍含阻塞项，Agent 连接页面也不会再显示绿色“已修复”提示。

- Completed Claude Code sessions now keep their latest Agent message in the desktop bubble. Claude appends a bookkeeping `last-prompt` record after the final Agent text, and the connector previously mistook that repeated prompt for a newer user turn when handling `SessionEnd`; the record is now only a missing-prompt fallback, while a real later user message still takes over normally.

  已完成的 Claude Code 会话现在会在桌宠气泡中保留最新 Agent 消息。Claude 会在最终 Agent 文本之后追加一条记账用的 `last-prompt` 记录，连接器此前在处理 `SessionEnd` 时误把这条重复提示词当成更新的用户轮次；现在该记录只在缺少真实提示词时用于回退，真正较新的用户消息仍会正常接管显示。

- Dragging the pet no longer lets the session bubble drift away from it, and releasing no longer snaps the pet across to where the bubble ended up. Each presented frame moved the panel by the offset from the previous frame, so anything that touched the panel mid-gesture — including the layout pass that re-rounds it — was carried into every later frame and grew the error, while the bubble kept re-anchoring to the true pointer position. Both the pet panel and the bubble are now placed absolutely from the pointer-anchored center and the pet's offset inside its panel, captured once when the gesture begins, and the gesture is the panel's only presentation owner. The grab point therefore stays under the pointer for the whole drag, on a mouse or a trackpad.

  拖动宠物时，会话气泡不再逐渐拉开距离，松手后宠物也不再横跨过去落到气泡的位置。此前每一帧都用相对上一帧的位移来移动面板，因此手势中途任何改动过面板的操作（包括重新取整的布局流程）都会被后续每一帧继承并不断放大，而气泡却始终按真实指针位置重新定位。现在宠物面板与气泡都由手势开始时捕获的指针锚点中心和宠物在面板内的偏移绝对计算，并且手势期间面板只有这一个呈现所有者；无论使用鼠标还是触控板，抓取点在整个拖动过程中都保持在指针下方。

- The session bubble now stays attached to the pet's top or bottom edge at a fixed distance instead of swinging out to its side or sliding over it near a screen edge. Placement previously also offered left and right positions and clamped the bubble into the safe area, which changed the pet-to-bubble distance — and could overlap them — exactly when the pet was dragged toward an edge. The side now flips between above and below when the current one no longer fits, a screen edge changes only the horizontal attachment, and the vertical distance never changes.

  会话气泡现在固定贴在宠物的上方或下方，不再甩到宠物左右两侧，也不会在靠近屏幕边缘时滑到宠物身上。此前的放置逻辑还提供左右两个位置，并会把气泡夹回安全区，这恰好会在把宠物拖向边缘时改变宠物与气泡的距离甚至造成重叠。现在当前一侧放不下时会在上下之间切换，屏幕边缘只改变左右贴靠方向，竖直间距始终不变。

- The pet now reacts again while an Agent keeps calling tools, instead of running its tool action once and then sitting idle for the rest of a long turn. Every tool event shared one animation identity, so after the bounded entry burst finished, continued tool work could never start a new one — and hosts like Claude Code publish no other event between calls. A `tool` identity now covers one tool activity run: continued traffic for the same closed activity subtype, including the tool-after edge of a call, still keeps its identity and does not restart the animation, while a different activity or an interrupting event begins a new run that plays the entry burst again.

  Agent 持续调用工具时，宠物会重新有反应，不再只播放一次工具动作、之后整轮长任务都停在 idle。此前所有工具事件共用同一个动画身份，有界的进入动作播完后，后续工具工作再也无法开启新的动画身份，而 Claude Code 等宿主在两次调用之间不会发送其他事件。现在一个 `tool` 身份对应一段工具活动：同一封闭活动子类型的后续事件（包括一次调用的结束边）仍保持同一身份、不重启动画；活动子类型改变或出现打断事件时则开始新的一段，并重新播放进入动作。

- Claude Code sessions started from the Claude desktop app now show their real session name and current message in the desktop bubble instead of a generic "Claude session" with no context. That host emits session and tool lifecycle hooks but never `UserPromptSubmit` or `Stop` — the only Claude hooks carrying a message — and its `session_title` only rides `SessionStart`, which fires before a title exists, so such a session stayed anonymous for its whole life. The connector now recovers the session title, latest prompt, and latest Agent text from a bounded tail of the transcript the hook itself names, under the same sanitization and length bounds as a hook-supplied field. It fills only fields the host left absent, excludes tool results and subagent turns, and requires a regular user-owned file without following symlinks. Codex, Pi, and OpenCode already publish these fields directly and are unchanged.

  从 Claude 桌面应用发起的 Claude Code 会话现在会在桌面气泡里显示真实会话名与当前消息，不再是没有上下文的通用「Claude 会话」。该宿主只发送会话与工具生命周期 Hook，从不发送 `UserPromptSubmit` 或 `Stop`（Claude 仅有的两个携带消息的 Hook），其 `session_title` 也只随 `SessionStart` 发送，而该 Hook 在标题生成前就已触发，因此这类会话会一直保持匿名。连接器现在从 Hook 自身给出的对话记录文件尾部有界读取会话标题、最新用户消息与最新 Agent 文本，并套用与 Hook 字段完全相同的脱敏与长度限制；只填补宿主缺失的字段，排除工具结果与子代理轮次，且要求目标是当前用户拥有的普通文件并且不跟随符号链接。Codex、Pi 与 OpenCode 本就直接上报这些字段，保持不变。

- A completed Agent session that has been opened or hidden no longer reappears when a later snapshot temporarily omits that session—even while other Agents remain visible—and then projects the exact same completion again. The App preserves the last local activation identity and dismissal per session; only a genuinely newer activation clears that dismissal and reopens the row.

  已打开或收起的已完成 Agent 会话，不再因为后续快照暂时遗漏该会话（即使其他 Agent 会话仍在显示）、随后又投影完全相同的完成事件而重新出现在气泡中。App 现在按会话保留上一次本地激活身份与收起状态；只有真正更新的会话激活才会清除该状态并重新显示。

- Claude Code completion acknowledgement now covers every `Stop`, completion notification, and process-level `SessionEnd` tail in the same activity epoch. Repeated `SessionEnd` hooks therefore cannot revive an already opened completion without a new user/task activation. The same epoch also retains a trusted `claude_app` origin when a later tail hook loses the Claude Desktop marker, while a genuine next activation may still switch between App and CLI truthfully.

  Claude Code 的完成确认现在会覆盖同一活动轮次内的所有 `Stop`、完成通知与进程级 `SessionEnd` 尾事件；因此，没有新用户/任务激活时，重复的 `SessionEnd` Hook 不会再让已打开的完成会话回到气泡。同一轮次内，若后续尾 Hook 丢失 Claude Desktop 标记，也会保留已验证的 `claude_app` 来源；真正的下一次激活仍可如实切换 App 或 CLI。

- Dragging the desktop pet no longer slides the grab point across its body. Each pointer sample is now read in absolute screen coordinates from the event itself; the previous window-relative reading was expressed against the panel origin the sample was created with, and because the drag translates that same panel on every display tick, fast large drags accumulated the difference as visible pointer offset.

  拖动桌宠时，鼠标不再从最初按住的位置上滑开。每个指针采样现在直接按事件的绝对屏幕坐标读取；此前的窗口相对坐标以采样生成时的面板原点为基准，而拖动本身每个显示刷新都会移动同一个面板，因此大幅快速拖动会把两者的差值累积成可见的指针偏移。

- The session bubble now follows and re-anchors while the pet is dragged, instead of holding its start-of-drag placement and correcting once on release. Bubble and menu panels are re-anchored on the same display tick as the pet, using the stack size measured when the gesture began so no session text is re-measured per frame, and both the above/below/left/right anchor and the attached horizontal edge stay put until they no longer fit — so crossing the screen midline no longer jumps the bubble by its own width.

  会话气泡现在会在拖动过程中跟随并实时调整位置，不再保持拖动开始时的位置、直到松手才一次性纠正。气泡与菜单面板与宠物在同一个显示刷新内重新定位，并复用手势开始时测得的气泡尺寸，因此不会逐帧重新测量会话文本；上/下/左/右锚定方向与横向贴边方向都会保持到确实放不下为止，越过屏幕中线不再让气泡整体跳动一个气泡宽度。

- Dragging is smoother under fast movement. The display link stays armed for the whole gesture instead of being paused and re-armed per pointer sample, screen geometry and refresh cadence are captured once per gesture rather than queried from the window server inside every event, and the drag view is resolved once instead of by walking the hosted view tree on every presented frame.

  快速拖动时更顺滑：显示刷新回调在整个手势期间保持启用，不再每次指针采样都暂停并重新启用；屏幕几何与刷新率按手势采集一次，不再在每个事件里向窗口服务器查询；拖动视图只解析一次，不再每帧遍历宿主视图树。

- Opening a Claude Code session from a desktop bubble no longer creates a duplicate, title-less thread in Claude. Claude Desktop's `claude://resume` link imports the CLI transcript as an additional Desktop session instead of returning to the existing one, and the transcript UUID a hook reports is not the Desktop session's own identity, so no exact-session return was ever possible. Claude Code App sessions now activate Claude at host level and say so on the action, matching how OpenCode already behaves; Codex exact-task and Warp exact-session routing are unchanged.

  从桌面气泡打开 Claude Code 会话不再在 Claude 中产生无标题的重复会话。Claude Desktop 的 `claude://resume` 链接会把 CLI 对话记录导入为一个新的桌面会话，而不是回到已有会话，且 Hook 上报的对话记录 UUID 并非桌面会话自身的标识，因此精确回到原会话从来不可能实现。Claude Code 的 App 会话现在按宿主级别激活 Claude 并在操作文案中如实说明，与 OpenCode 的现有行为一致；Codex 的精确任务跳转与 Warp 的精确会话跳转不受影响。

- Desktop-bubble controls now act on release instead of on press. Pressing a session row, a group toggle, or the close control—or starting a pointer movement on one—no longer activates it; the action runs only when the release lands on the same control it was pressed on.

  桌面气泡控件现在在松开时触发，不再在按下时触发：按住会话行、分组折叠或关闭控件，或在其上开始移动指针，都不会立即触发；只有在同一控件上松开时才会执行对应操作。

- Control Center, desktop-pet, and bubble interactions are no longer blocked by repeated resource work on the main thread. Localized strings are parsed once per locale instead of re-reading and re-parsing the whole `Localizable.strings` property list on every lookup; the session-bubble projection is memoized across the several reads in one SwiftUI pass; its redundancy-normalization regular expression is compiled once; and pet cover images are decoded once per on-disk version instead of on every view-body evaluation. Measured on the same machine, a single navigation press went from about 535 ms to about 109 ms, one display-size step from about 212 ms to about 22 ms, a bubble expand/collapse from about 253 ms to about 21 ms, and idle App CPU from roughly 35% of a core to under 5%.

  控制中心、桌宠与气泡交互不再被主线程上重复的资源工作阻塞：本地化文案按语言只解析一次，不再每次取值都重新读取并解析整份 `Localizable.strings`；会话气泡投影在同一次 SwiftUI 渲染的多处读取间做记忆化；其冗余判定正则只编译一次；宠物封面图按磁盘版本只解码一次，不再每次视图求值都重新解码。同机实测：一次导航点击约从 535 毫秒降至约 109 毫秒，显示尺寸单步约从 212 毫秒降至约 22 毫秒，气泡展开/收起约从 253 毫秒降至约 21 毫秒，空闲时 App CPU 约从单核 35% 降至 5% 以内。

- PetCore no longer adds a fixed delay to every local request. The Unix socket accept loop now waits on the listener itself instead of sleeping a fixed 20 ms slice, so a connecting client is served as soon as it arrives, and the `state.wait` long poll reuses one SQLite connection instead of reopening the database on every tick. Measured on the same machine, `petcore.health` went from about 29 ms to about 0.25 ms and `behavior.get` from about 47 ms to about 0.85 ms at the median.

  PetCore 不再为每个本地请求附加固定延迟：Unix socket 的 accept 循环改为在监听套接字上等待，不再固定睡眠 20 毫秒，连接到达即可被受理；`state.wait` 长轮询复用同一个 SQLite 连接，不再每轮重新打开数据库。同机实测中位数：`petcore.health` 约从 29 毫秒降至约 0.25 毫秒，`behavior.get` 约从 47 毫秒降至约 0.85 毫秒。

- Reading a PetCore response no longer rescans the whole accumulated buffer for the frame boundary after each chunk, which made framing quadratic in response size on large snapshot and history payloads.

  读取 PetCore 响应时不再在每个数据块后重新扫描整个已累积缓冲区来寻找帧边界，该行为此前使大体积快照与历史响应的分帧开销随响应大小呈平方增长。

- Desktop-pet dragging now keeps the pet, bubble, and menu as one reattached AppKit composition through hide/show cycles; applies the exact mouse-up frame once even before the first display tick; preserves transparent-pixel passthrough with a typed active pointer lease; and performs one stable adaptive bubble reflow after release. Placement coordinates share a 1/256 pt Swift/Rust contract, idempotent PetCore writes create no revision churn, and failed/conflicting saves stop after five attempts while retaining the latest visible position and recovery journal. Privacy-safe local signposts and opt-in aggregate performance summaries quantify responsiveness without recording coordinates, identities, paths, payloads, or user text.

  桌宠拖动现在会在反复隐藏/显示后仍将宠物、气泡与菜单维持为重新挂载的同一 AppKit 组合；即使首次显示刷新尚未到达，也只应用一次 mouse-up 精确最终帧；通过类型化活动指针租约同时保留透明像素穿透；释放后仅进行一次稳定的自适应气泡重排。位置坐标统一使用 Swift/Rust 共享的 1/256 pt 契约；PetCore 幂等写入不再制造 revision 抖动；保存失败或持续冲突最多尝试五次，并保留最新可见位置与恢复 journal。隐私安全的本地 signpost 与显式启用的聚合性能摘要可量化响应速度，且不记录坐标、标识、路径、payload 或用户文本。

- Pet Library and first-run action previews no longer leave the static cover visible underneath Metal animation frames after an action switch. Loading now uses the selected action's authored representative pose; fallback visibility is scoped to the exact pet revision and action, changes only after a frame reaches the display, and ignores stale callbacks from a replaced renderer, preventing thumbs-up covers or two poses from appearing at once.

  宠物库及首次体验的动作预览在切换动作后，不再把静态封面留在 Metal 动画帧下方。加载期间现在使用所选动作的创作代表姿势；回退图可见性绑定到精确的宠物 revision 与动作，只会在帧真正呈现后切换，并忽略已替换渲染器的过期回调，从而避免点赞封面或两个姿势同时出现。

- Valid `.petpack` imports no longer fail when their final SQLite commit overlaps high-frequency Agent event writes. The immutable pet-revision commit retries only bounded transient database contention while preserving pointer/revision rollback for persistent or non-contention failures; the App also distinguishes a local-service failure from an invalid package instead of always blaming the selected file.

  有效 `.petpack` 的最终 SQLite 提交与高频 Agent 事件写入重叠时不再导入失败。不可变宠物 revision 提交现在只会对有界的临时数据库争用进行重试；持续争用或其他错误仍保留指针与 revision 回滚。同时 App 会区分本地服务失败和无效宠物包，不再一律把问题归咎于所选文件。

- Managed V2 runtime installation now carries the App bundle's build-bound `interaction-attestation.json`, and both the App-bundle and versioned-runtime CLI layouts resolve that proof automatically. Portable Maker finalization therefore retains the four official Swift interaction suites after PetCore handoff instead of failing with an empty `interaction_evidence` list; published V1 rollback runtimes remain compatible.

  受管 V2 运行时安装现在会携带 App bundle 中与构建绑定的 `interaction-attestation.json`，App bundle 与版本化运行时两种 CLI 布局也都会自动解析该证明。PetCore 接管后，便携 Maker 最终封包因此仍能获得四项官方 Swift 交互测试证据，不再因 `interaction_evidence` 为空而失败；已发布的 V1 回滚运行时继续保持兼容。

- Ordinary Agent activity can no longer leave the desktop pet stuck in an old thinking or tool pose when a connector misses its terminal callback. PetCore now bounds `session_active` hints by the configured session-message window, and the App refuses to animate from an expired canonical state after the last visible session is acknowledged; persistent waiting and failed attention states are unchanged.

  当连接器遗漏终止回调时，普通 Agent 活动不再让桌宠永久停在旧的思考或工具动作。PetCore 现在会按配置的会话消息时限约束 `session_active` 提示，App 也不会在最后一个可见会话被确认后继续使用已过期的规范状态驱动动画；持续等待与失败提醒语义保持不变。

- Codex plugin release validation now blocks packaging when a changed Studio Skill omits the previous shipped Skill's exact ownership digest. PetCore and the release gate share one structured, append-only history; removed or unrelated digests and the current Skill are rejected, preventing future managed upgrades from repeating the v0.4.5 ownership conflict while continuing to preserve customized files.

  Codex 插件发布校验现在会在 Studio Skill 发生变化却未保存上一发布版本精确所有权摘要时阻止打包。PetCore 与发布门禁共用一份结构化、只能追加的历史清单；删除或加入无关摘要、把当前 Skill 标记为历史内容都会被拒绝，从而防止后续受管升级重演 v0.4.5 所有权冲突，同时继续保护用户自定义文件。

- Fixed Codex plugin upgrades from v0.4.5 to v0.4.6 by recognizing the exact previously shipped Studio Skill as App-managed content. Setup/repair can now replace that unmodified old Skill while still preserving customized files and unsafe paths.

  修复 Codex 插件从 v0.4.5 升级到 v0.4.6 时对旧 Studio Skill 的所有权误判；设置/修复现在可替换字节完全一致的旧版 Skill，同时仍保护用户自定义文件与不安全路径。

- Clicking the desktop pet now only expands or collapses its session bubble; Agent navigation is reserved for concrete session rows. A double-click performs the first toggle once and ignores the later release, so pet clicks can no longer launch ChatGPT/Codex, another Agent host, or the same route repeatedly.

  单击桌宠现在只会展开或收起会话气泡，Agent 跳转仅由具体会话行触发；双击只执行第一次切换并忽略后续抬起事件，因此点击宠物不再启动 ChatGPT/Codex、其他 Agent 宿主或重复打开同一路由。

- Completed Codex task rows remain openable after their message-detail window expires: PetCore now separates raw unarchived task membership from recent `thread/read` hydration, repairs stale synthetic closures when a task is still listed, and never treats a paginated omission as closure proof. Every bubble row also exposes hover/focus feedback; a genuinely unavailable destination responds with an explicit notice instead of behaving like inert content.

  Codex 已完成任务在消息详情时限结束后仍可打开：PetCore 现在将原始未归档任务成员关系与近期 `thread/read` 详情读取分开，在任务仍位于列表中时修复陈旧的合成关闭记录，并且不再把分页遗漏当作关闭证据。每个气泡会话行也都会提供悬停/焦点反馈；真正不可跳转的目标会明确提示原因，不再表现为无响应内容。

- Completed sessions now leave the active pet and desktop bubble immediately when the Agent explicitly reports them archived or closed. Their bounded audit events remain available, while completed sessions that are still open continue to show and navigate normally.

  Agent 明确上报已归档或关闭后，已完成会话现在会立即退出桌宠活跃状态与桌面气泡；对应的有界审计事件仍会保留，而尚未归档的已完成会话仍会正常显示并支持跳转。

- Desktop Codex bubbles now keep every session badge on one trailing alignment and suppress the App's title-only internal suggestion threads, including already retained rows, so background `suggestions` work no longer appears as an unidentified conversation.

  Codex 桌宠气泡现在会将每个会话状态标识统一靠右对齐，并过滤仅暴露标题的 App 内部建议线程（包括已保留的历史记录），后台 `suggestions` 工作不再显示为无法识别的会话。

- Existing pre-V3 pets—including V1/V2 timing rows, legacy render-size collisions, and retired `ultra` or `original` tiers—do not make PetCore or the App appear offline, masquerade as V3, or block runtime handoff after upgrade. Replacement safety is checked through a pet-independent preflight; the runtime quarantines every row outside the exact V3 render and nine-action contract, preserves legacy metadata and owned files, and activates the first valid V3 pet when needed.

  升级后，pre-V3 历史宠物（包括 V1/V2 时序行、旧画质尺寸冲突及停用的 `ultra`、`original` 档）不会导致 PetCore 或 App 显示离线、冒充 V3 宠物或阻塞运行时接管；替换安全性由不依赖宠物投影的轻量预检确认，运行时会隔离不满足精确 V3 画质与九动作契约的行，保留旧元数据与自有文件，并在需要时自动启用首个有效 V3 宠物。

- Runtime replacement now stops the old service, creates or crash-recovers an exact build-bound SQLite checkpoint, and only then runs the candidate's sole read-only database preflight. Incompatible active V1 generation forms are rejected without writing; candidate failure stops the candidate and restores the checkpoint before one of the exact published v0.1.0, v0.1.1, or v0.2.1 last-known-good runtimes can start. Checkpoint creation/restoration failures stay fail-closed, and phase tracking prevents a later App crash from replaying stale data over post-rollback writes.

  运行时替换现在会先停止旧服务，创建或恢复与源构建及候选构建精确绑定的 SQLite 检查点，再执行候选版本唯一一次只读数据库预检；不兼容的活动 V1 制作表单会在不写入的情况下被拒绝。候选失败时会先停止候选并恢复检查点，之后才允许启动精确匹配已发布 v0.1.0、v0.1.1 或 v0.2.1 身份的上一可用运行时；检查点创建或恢复失败会安全关闭，阶段标记也会防止后续 App 崩溃把陈旧数据覆盖到回滚后的新写入上。

- Upgrades now canonicalize the one exact legacy overlay `{x, y, scale, display_id}` setting before strict V2 snapshots: its center and display are preserved, the removed multiplier becomes the 112 pt default width, and malformed or extended legacy objects still fail closed. Persisted current-shape values also reject non-finite coordinates, widths outside 100–300 pt, and empty display identities instead of letting PetCore and the App disagree.

  升级现在会在严格 V2 快照前规范化唯一允许的旧版桌宠位置 `{x, y, scale, display_id}`：保留中心点与显示器，将已移除的倍率替换为 112 pt 默认宽度；畸形或带额外字段的旧对象仍会安全拒绝。持久化的当前格式也会拒绝非有限坐标、超出 100–300 pt 的宽度与空显示器标识，避免 PetCore 与 App 状态不一致。

- Agent session bubbles now preserve and display the actual App-versus-CLI origin across Codex, Claude Code, OpenCode, and CLI-only Pi. Clicking a validated ChatGPT/Codex App or Claude App UUID returns to the exact session; Warp keeps exact CLI routing, known terminals and OpenCode App use truthful host-level activation, and unknown or mismatched historical targets remain unavailable. URL rejection, App activation, and launch completion are checked explicitly: a failed exact link may open the matching host as a recovery aid, but it keeps the session visible with a localized retryable error and never acknowledges it as reached. Host-level action copy names the real destination, and updated Codex/Claude/OpenCode connector contracts make stale managed adapters repairable.

  Agent 会话气泡现在会在 Codex、Claude Code、OpenCode 及仅支持 CLI 的 Pi 中保留并显示真实的 App/CLI 来源。点击通过校验的 ChatGPT/Codex App 或 Claude App UUID 可返回精确会话；Warp 保留精确 CLI 跳转，已知终端与 OpenCode App 使用符合实际能力的宿主级唤起，未知或来源不匹配的历史目标则保持不可用。URL 被拒、App 激活与启动完成结果都会被明确检查；精确链接失败后可以把对应宿主作为恢复辅助打开，但会保留会话并显示本地化、可重试的错误，绝不会把它误记为已到达。宿主级操作文案会标明真实目的地，Codex/Claude/OpenCode 连接器契约也已更新，使旧版受管适配器可被识别并修复。

- Claude Code desktop bubbles no longer use leading file-attachment `@"/absolute/path"` references as the session title or render the host's structured `tool_response` object as raw JSON. The connector keeps the textual prompt for the first-message title fallback and projects a concise tool description, command/input, or semantic result/error instead; the read-only display projection also cleans existing local sessions without rewriting their audit records.

  Claude Code 桌宠气泡不再把文件附件的前导 `@"/绝对路径"` 引用当作会话标题，也不再将宿主的结构化 `tool_response` 对象以原始 JSON 展示；连接器会保留提示词正文用于首条消息标题回退，并改为投影简洁的工具说明、命令/输入或有语义的结果/错误；只读展示投影也会清理已有本地会话，但不会改写其审计记录。

- `petcore-cli petpack build` and portable Maker finalization now keep the staged archive under a private sibling directory with a normal leaf filename, remove its temporary link before final metadata handling, and hold a bounded visibility-settling window before reporting completion. This clears macOS Finder's immediate or delayed `UF_HIDDEN` reapplication to a normally named `.petpack` while preserving atomic replacement, archive bytes, and all unrelated BSD flags.

  `petcore-cli petpack build` 与便携 Maker 最终化现在会把暂存归档放在同级私有目录中并使用正常文件名，在处理最终元数据前移除临时链接，并在报告完成前保留一段有界的可见性稳定窗口；这会清除 macOS Finder 立即或延迟重新施加到正常命名 `.petpack` 上的 `UF_HIDDEN` 标志，同时保持原子替换、归档字节及其他 BSD flags 不变。

- Completed Agent sessions that the user opens now remain consumed after App/PetCore replacement or relaunch instead of reappearing in the desktop bubble. PetCore persists a bounded opaque acknowledgement shared by Codex, Claude Code, Pi, and OpenCode; a later activity event for the same session produces a new identity and makes it visible again.

  用户打开已完成的 Agent 会话后，即使 App/PetCore 被替换或重新启动，该会话也不会再次弹回桌宠消息气泡。PetCore 现在为 Codex、Claude Code、Pi 与 OpenCode 持久保存同一套有界不透明确认标识；同一会话出现后续活动事件时会生成新标识并重新显示。

- External `.petpack` validation and runtime-frame preparation no longer hold the exclusive pet-library mutation lock. State snapshots remain responsive during large imports, and the App confirms lightweight PetCore health before treating a state-stream timeout during protected user work as a service outage.

  外部 `.petpack` 的校验与运行帧准备不再占用宠物库独占写锁；大型导入期间状态快照仍可响应，App 在受保护的用户操作中遇到状态流超时时，也会先确认 PetCore 轻量健康状态，再判断是否属于服务离线。

- Desktop bubbles now keep the latest concrete Codex reasoning or tool detail while a lossy App Server refresh only proves that hidden activity continued, instead of replacing useful text with an empty inferred tool category. When concrete activity exists, the Agent reply and activity use one line each; when no concrete activity exists, the Agent reply uses both available detail lines.

  当有损的 Codex App Server 刷新只能确认隐藏活动仍在继续时，桌宠气泡现在会保留最近一条具体 reasoning 或工具详情，不再用无文本的推断工具类别覆盖有用内容；有具体活动时 Agent 回复和活动各占一行，没有具体活动时 Agent 回复使用全部两条详情行。

- A current concrete Codex reasoning or tool item now supersedes an older same-turn running hook, while content-free inferred activity still preserves the hook-backed detail. Live per-session `thread/read` hydration no longer queues behind the background recent-thread scan or connection work, and a changed display cache now wakes `state.wait` immediately instead of waiting for another timeout cycle.

  当前具体的 Codex reasoning 或工具条目现在会覆盖同一轮中更旧的运行中 Hook；无文本的推断活动仍会保留 Hook 详情。实时单会话 `thread/read` 水合不再排队等待后台最近会话扫描或连接检查，展示缓存发生变化时也会立即唤醒 `state.wait`，不再多等一轮超时。

- Codex sessions that are stopped and then archived now produce an explicit audit-only closed completion and leave both the active App Server projection and desktop bubble immediately. A successful, complete `thread/list` disappearance is required, so a transient, paginated, or per-thread detail read failure cannot falsely close an active task.

  用户停止并归档 Codex 会话后，现在会生成一条仅供审计的明确关闭完成事件，并立即退出活跃 App Server 投影与桌宠气泡。只有成功且完整的 `thread/list` 确认会话消失时才会执行该收束，因此临时失败、分页结果或单会话详情读取失败不会误关仍活跃的任务。

- Desktop-pet dragging now coalesces high-frequency samples inside the overlay, avoids duplicate pointer-monitor delivery, preserves sub-point movement, and commits exactly the final hard-clamped center on normal or lost release. There is no projected, rubber-banded, or settling movement after the pointer stops.

  桌宠拖动现在会在悬浮层内合并高频样本，避免指针监视器重复分发并保留亚像素移动；无论正常释放还是丢失释放事件，都会准确提交最终硬边界约束后的中心。指针停止后不再出现投影、橡皮筋或回落位移。

- Agent-session disclosure now uses one coordinated, interruptible transition without an extra three-row presentation cap.

  Agent 会话展开与折叠现在使用统一且可中断的过渡，不再额外限制为三行。

- Closing the control-center window no longer makes an enabled desktop pet disappear until another regular App window opens. The resident close lifecycle is now distinguished from macOS Show Desktop while preserving ordinary reopen and explicit Quit behavior.

  关闭控制中心窗口后，已启用的桌宠不再消失并等待其他普通 App 窗口打开后才恢复；现在会区分常驻窗口关闭与 macOS“显示桌面”，同时保留原有的重新打开及明确退出行为。

- Rebuilt all nine V3 actions for bundled `星雾团子`, `Bytebud 字节芽`, and `桃蕾` with crisp independent poses, stable character identity, authored per-frame timing, bounded semantic playback, restrained acknowledge/drag interactions, and reduced-motion frames. App upgrades install changed trusted assets as a new immutable revision without replacing ordinary same-ID pets or changing the active selection.

  重新制作内置 `星雾团子`、`Bytebud 字节芽` 与 `桃蕾` 的全部九种 V3 动作，提供清晰独立姿势、稳定角色身份、逐帧制作时序、有界语义播放、克制的点击回应/拖动交互与减弱动态效果代表帧。App 升级会把变化后的可信资源安装为新的不可变修订，不替换普通同 ID 宠物，也不改变当前选择。

- Agent sessions now keep the bounded first user message as their display-title fallback until a later explicit title arrives, then update to that title across Codex, Claude Code, Pi, and OpenCode without replacing the latest-message context.

  Agent 会话现在会在显式标题到达前使用有界的首条用户消息作为显示标题；之后 Codex、Claude Code、Pi 与 OpenCode 都会更新为显式标题，同时保留独立的最新消息上下文。

- Long Pet Studio turns now wait through App Server errors that explicitly promise an automatic retry and never start a second helper turn after a permanent failure, preventing a recoverable reconnect from discarding an in-progress image-generation run.

  长时间运行的宠物制作任务现在会在 App Server 明确承诺自动重试时继续等待，并且永久失败后不会再提前启动第二个辅助 turn，避免可恢复的重连中断正在进行的图像生成。

- Pet Studio terminal failures now surface the bounded App Server provider message before reporting diagnostics for an incomplete source tree, so usage limits and other permanent causes are no longer hidden behind a secondary package-validation error.

  宠物制作的终止失败现在会先展示有界的 App Server 提供方消息，再补充未完成源码树的诊断；用量上限及其他永久原因不再被次生的宠物包校验错误遮蔽。

- Pet Studio now waits for the authoritative App Server `turn/completed` boundary instead of treating an intermediate Agent message as completion, keeps state-row generation serial in the owning turn, and safely materializes the required empty reference directory when a no-reference Skill source omits it. This prevents long motion generation from being validated while its frame rows are still being written.

  Pet Studio 现在会等待 App Server 权威的 `turn/completed` 边界，不再把阶段性 Agent 消息误当作完成；各状态帧行会在所属 turn 内串行生成，无参考图的 Skill source 若遗漏必需的空引用目录也会安全补建，从而避免长时间动作生成仍在写入帧行时就提前校验产物。

- Agent Connections now keeps typed setup/repair entries available after a successful repair, turns unavailable states into concise recovery guidance, and keeps persistent operation feedback. Connection tests now have a dedicated three-second bound and finish without waiting for an unrelated full state refresh, preventing the Claude Code test action—or the same action for any other Agent—from making the App appear frozen.

  Agent 连接现在会在修复成功后保留类型化设置/修复入口，将不可用状态收敛为简洁处理指引，并持续显示操作结果；连接测试改用独立的三秒上限，且不再等待无关的完整状态刷新，避免 Claude Code 或其他 Agent 的同类测试让 App 看起来卡死。

- Agent compatibility checks now recognize the schema-verified ChatGPT-bundled Codex `0.146.0-alpha.3.1` and `0.146.0-alpha.9.2`, Claude Code `2.1.212–2.1.216`, and OpenCode `1.18.0–1.18.4`; Codex must report one canonical `codex-cli <version>` line rather than merely contain an allowlisted token, and Pi remains fail-closed below `0.80.10` because older hosts do not expose the required settled-session and title events.

  Agent 兼容性检查现在会识别已完成协议复核的 ChatGPT 内置 Codex `0.146.0-alpha.3.1` 与 `0.146.0-alpha.9.2`、Claude Code `2.1.212–2.1.216` 及 OpenCode `1.18.0–1.18.4`；Codex 必须返回唯一规范的 `codex-cli <版本>` 行，而不是仅包含白名单版本片段；Pi 低于 `0.80.10` 时仍安全判定为不兼容，因为旧宿主尚未提供所需的会话稳定完成与标题事件。

- Fixed GitHub Release apps crashing shortly after launch on newer macOS versions when the desktop pet presents its first Metal frames.

  修复 GitHub Release App 在较新 macOS 上启动后、桌宠首次呈现 Metal 帧时发生闪退的问题。

- Restored typed per-Agent install/repair actions when unrelated host verification still needs a recheck, and added an explicitly confirmed one-click setup or repair action to first run and Agent Connections. The exact App-managed retired V1 Studio Skill signature can be replaced during a Codex connector upgrade, while customized or merely similar files remain preserved conflicts. Policy restrictions and missing Agent dependencies still fail closed.

  当无关的宿主验证仍待复核时，恢复按 Agent 提供的类型化安装/修复操作，并在首次体验与 Agent 连接页新增需明确确认的一键设置或修复操作；Codex 连接器升级时可以替换具有精确 App 管理签名的停用 V1 Studio Skill，自定义或仅相似的文件仍会作为冲突保留。策略限制及 Agent 依赖缺失仍会安全禁用写入。

- Upgrade-preserved pets with either included manifest ID remain selectable during first run without being granted bundled read-only authority; empty or damaged included-pet states now offer restore, repair, and diagnostics instead of false completion or import instructions.

  升级时保留下来的宠物只要具有任一内置 manifest ID，首次体验中仍可选择，但不会因此获得内置只读权限；内置宠物为空或资源损坏时现在提供恢复、修复与诊断，不再错误宣告完成或引导导入。

### Removed / 移除

- Removed the unsupported Agent `review` event and its badge, persistence, priority, filter, action, and connector mappings. The portable pet action formerly named `start` is now `thinking`; old `review` action assets are not part of V3. PetCore discards persisted removed-event rows, rewrites the behavior event map to the current allowlist, and quarantines stored packages with removed state names instead of aliasing old semantics.

  移除无真实宿主事件依据的 Agent `review` 事件，以及对应标识、持久显示、优先级、筛选、动作与连接器映射；宠物包中原名 `start` 的动作改名为 `thinking`，旧 `review` 动作素材不属于 V3。PetCore 会清除已持久化的废弃事件、将行为事件开关收敛到当前白名单，并隔离仍含废弃状态名的已存宠物包，不会把旧语义偷偷映射为新动作。

- Removed the overlay resize handle, resize hit region, hover control, keyboard resize action, and all momentum, projection, rubber-band, and settling drag behavior.

  移除桌宠悬浮层缩放手柄、缩放命中区域、悬停控件、键盘缩放操作，以及全部惯性、投影、橡皮筋和回落拖动行为。

- Removed Standard/Smooth playback profiles, package-wide native FPS and fixed-duration controls, runtime frame sampling, unsupported `ultra`/`original` quality tiers, and `.petpack` V1/V2 reading. Source-capacity qualification rejects 576×624 production only for ChatGPT/Codex built-in `imagegen` and the Codex-backed in-App Studio; multiple batches cannot substitute for that producer's missing source pixels. V1/V2 packages are rejected with guidance to recreate them through the V3 maker; no migration shim is provided.

  移除标准/流畅播放档位、包级原生 FPS 与固定时长控件、运行时抽帧、不受支持的 `ultra`/`original` 画质档，以及 `.petpack` V1/V2 读取。来源容量核验只针对 ChatGPT/Codex 内置 `imagegen` 与 App 内基于 Codex 的 Studio 拒绝 576×624 制作，多批次也不能替代该制作方缺失的来源像素。V1/V2 宠物包会被拒绝并提示通过 V3 Maker 重新制作，不提供迁移兼容层。

## [0.2.1] - 2026-07-24

### Fixed / 修复

- Restored release-runner compatibility for the App update lifecycle tests across the supported Swift toolchains; product behavior and the `0.2.0` feature set are unchanged.

  恢复 App 更新生命周期测试在受支持 Swift 工具链上的发行 runner 兼容性；产品行为及 `0.2.0` 功能集保持不变。

## [0.2.0] - 2026-07-24

### Added / 新增

- Added quiet, ETag-aware automatic checks for GitHub's latest stable Release plus manual **Check for Updates…** actions in the App menu and About window. Update discovery validates a strict `vX.Y.Z` Release, exact dual-architecture asset inventory, official download URL, size, and GitHub SHA-256 metadata without downloading or installing the App.

  新增安静且支持 ETag 的 GitHub latest stable Release 自动检查，以及 App 菜单和“关于”窗口中的手动“检查更新…”操作。更新发现会校验严格的 `vX.Y.Z` 正式版本、精确双架构资产清单、官方下载地址、大小与 GitHub SHA-256 元数据，但不会自动下载或安装 App。

- Added one bilingual three-step manual replacement guide beside the update action, at the top of every Release, and when a release App is opened outside Applications: download and unzip, quit and replace in Applications, then open from Applications.

  在更新操作旁、每个 Release 顶部，以及正式版从非“应用程序”位置启动时，新增同一份中英双语三步手动替换引导：下载并解压、退出旧版并在“应用程序”中替换、最后从“应用程序”打开。

### Changed / 变更

- After a manual App replacement, the new bundled identity now drives one resumable convergence across PetCore, `petcore-cli`, the runtime manifest, missing bundled pets, previously managed Agent connectors, the Codex plugin, and both pet-making Skills. Core failure restores the compatible last-known-good runtime, while one failed Agent remains isolated and repairable.

  用户手动替换 App 后，新版随包身份会通过同一套可恢复流程收敛 PetCore、`petcore-cli`、runtime manifest、缺失的内置宠物、此前已受管的 Agent 连接器、Codex 插件与两个宠物制作 Skills。核心失败会恢复上一套兼容运行时，单个 Agent 失败则保持隔离且可修复。

- Bumped the bundled Codex plugin to `0.3.0` and made plugin, `agent-pet-studio`, and `agent-pet-maker` content changes require a strict plugin version increase from the comparison base.

  将随包 Codex 插件提升至 `0.3.0`，并要求插件、`agent-pet-studio` 或 `agent-pet-maker` 内容变化时，相对比较基线严格提升插件版本。

- Removed the repository-level GitHub Immutable Releases requirement while retaining protected release tags, exact stable-version and asset validation, downloaded-asset revalidation, and published SHA-256 checks.

  移除仓库级 GitHub Immutable Releases 要求，同时保留受保护的发布 tag、严格稳定版本与资产校验、下载后复验及公开 SHA-256 校验。

### Fixed / 修复

- App replacement handoff now waits for pending settings and overlay-placement writes, revalidates the canonical candidate immediately before quitting, and keeps the old App open with recovery actions if download opening, validation, or relaunch scheduling fails. Bundled-pet convergence also rejects malformed, partial, duplicate, or mismatched seed results instead of recording a false success.

  App 替换交接现在会等待尚未完成的设置与桌宠位置写入，在退出前重新校验正式安装位置中的候选包，并在下载地址打开、校验或重启安排失败时保留旧版运行及恢复操作。内置宠物收敛也会拒绝格式错误、不完整、重复或 ID 不匹配的返回，不再记录虚假成功。

### Security / 安全

- GitHub Release publication now fails closed unless the published result is the latest non-prerelease Release and all three API asset digests match the trusted build outputs; the Release notes lead with the exact bilingual replacement guidance consumed by the App experience.

  GitHub Release 发布现在会安全失败，除非公开结果是 latest 非预发布版本，且三个 API 资产摘要都与可信构建输出一致；Release notes 顶部也会提供与 App 体验一致的中英双语替换引导。

## [0.1.1] - 2026-07-23

### Changed / 变更

- Made GitHub Releases the only official V1 distribution channel, with exactly two ad-hoc-signed thin `arm64`/`x86_64` ZIPs and a two-entry checksum file. The release is bound to the full commit and validated on native GitHub-hosted architectures before its three downloaded assets are revalidated; installation now clearly explains the required macOS first-open approval and does not require Apple signing credentials.

  GitHub Releases 现在是 V1 唯一正式分发渠道，固定提供两个采用 ad-hoc 签名的 `arm64`/`x86_64` thin ZIP 与一份两行校验和文件。发布身份绑定完整 commit，并在 GitHub 托管原生双架构上验收后重新校验三个实际下载资产；安装说明会明确 macOS 首次打开授权，且不需要 Apple 签名凭据。

- Desktop bubbles now preserve a bounded session title or latest user context plus the current-turn Agent message, use stable content-free labels for anonymous concurrent sessions, and distinguish exact-session return from host-only or unavailable navigation.

  桌宠气泡现在保留有界会话标题或最近用户上下文及当前轮 Agent 消息，为匿名并发会话使用稳定且不含内容的标签，并准确区分返回具体会话、仅打开 Agent 宿主与不可导航。

- Refocused the five management pages around one job and one contextual action: Pet Library centers the selected pet, AI Pet Maker follows describe/create/use, healthy service details stay disclosed on demand, and the toolbar remains quiet while the service is healthy.

  五个管理页面均收敛为一个核心任务与一个上下文操作：宠物库以所选宠物为中心，AI 宠物制作遵循描述、创建、使用流程，健康服务详情按需展开，服务正常时工具栏保持安静。

- Kept first-run Agent detection in the background so a slow host check never blocks the local desktop-pet demo, and bounded the demo and Library stages so large motion assets remain fully visible.

  首次体验中的 Agent 检测改为后台进行，缓慢的宿主检查不再阻塞本地桌宠演示；演示与宠物库舞台也限制在稳定高度内，确保大尺寸动作素材完整可见。

- Simplified Pet Configuration to an in-page Appearance/Messages switch with product-level visibility, theme, Standard/Smooth motion, and three message-attention presets; source, individual-event, timeout, grouping, transparency, idle, context-menu, and pointer controls now stay under Advanced Settings.

  将宠物配置简化为页面内“外观/消息”切换，默认只呈现显示、主题、标准/流畅动效与三档消息提醒预设；来源、逐事件、收起时间、分组、透明度、空闲行为、右击菜单与指针控制统一收进高级设置。

- Reduced Agent Connections to one aggregate health state and one contextual action per Agent; local checks, managed-connector details, real-task evidence, channel testing, and managed-only uninstall now remain under Technical Details, while project and runtime information stay out of ordinary and accessibility presentation.

  将 Agent 连接页收敛为每个 Agent 一个聚合健康状态与一个上下文操作；本地检查、受管连接器详情、真实任务证据、通道测试与仅限受管文件的卸载统一收进“技术详情”，项目及运行时信息不再进入普通界面与无障碍输出。

- Added a resumable three-scene first-run experience for choosing an included companion, connecting Agents, and seeing a clearly labeled local state demo; completion leaves the pet visible, while the local demo never enters Agent history or diagnostics. The menu-bar summary now keeps only the current pet and recent Agent activity instead of exposing PetCore runtime information.

  新增可恢复的三幕首次体验：选择内置桌宠、连接 Agent、观看明确标注的本地状态演示；完成后桌宠保持显示，本地演示不会进入 Agent 历史或诊断。菜单栏摘要现在只保留当前桌宠与最近 Agent 活动，不再展示 PetCore 运行信息。

## [0.1.0] - 2026-07-23

### Added / 新增

- Added bundled `星雾团子` and `Bytebud 字节芽` pets to the first-launch library.

  首次打开即可在宠物库中看到内置的 `星雾团子` 与 `Bytebud 字节芽`。

- Added privacy-filtered diagnostics ZIP export with bounded App/PetCore logs and environment metadata.

  新增经过隐私过滤的诊断 ZIP 导出，包含有界的 App/PetCore 日志与环境元数据。

- Added the approved transparent Agent Pet Companion brand mark across App surfaces.

  App 各处统一使用已确认的透明 Agent Pet Companion 品牌图标。

### Changed / 变更

- GitHub Releases now provide separate ad-hoc-signed `arm64` and `x86_64` App archives with a shared SHA-256 checksum file; Developer ID signing, Apple notarization, stapling, Gatekeeper assessment, universal binaries, full Xcode, and separate physical-device acceptance are no longer development-stage release gates.

  GitHub Release 现在分别提供采用 ad-hoc 签名的 `arm64` 与 `x86_64` App 归档，并附共享的 SHA-256 校验和文件；Developer ID 签名、Apple 公证、staple、Gatekeeper 评估、universal 二进制、完整 Xcode 与不同物理设备验收不再是当前开发阶段的发布门槛。

- Replaced the ambiguous 12/20 FPS playback contract with authored 10/20 FPS tiers and fixed one- or two-second action durations: the creation brief can select the authored timing, high-rate pets can render at either tier without changing action speed, low-rate pets cannot be promoted at runtime, and AI edits create a new immutable revision when timing changes. Bundled pets now exercise both native tiers, while package details and configuration show each pet's supported playback and fixed durations.

  将含糊的 12/20 FPS 播放契约改为制作阶段固定的 10/20 FPS 两档与一秒或两秒动作时长：创作需求可选择制作时序；高帧率宠物可在不改变动作速度的前提下选择两档渲染，低帧率宠物不能在运行时升档，AI 修改时序会生成新的不可变 revision；两只内置宠物分别覆盖两档原生帧率，宠物详情与配置也会显示其可用播放档位和固定动作时长。

- Moved the enlarged Agent Pet Companion brand into the fixed control-center toolbar without a shared glass background, widened and increased the row height of the primary navigation, and unified nested navigation and pet-preview backgrounds with the surrounding App surfaces.

  将放大后的 Agent Pet Companion 品牌移至控制中心的固定工具栏并去除共享玻璃背景，加宽主导航并增大选项行高，同时将嵌套导航与宠物预览背景统一为 App 周边界面样式。

- Development builds now produce only the ad-hoc-signed local App by default; the verified handoff ZIP is available through explicit `--archive`.

  开发构建默认仅生成 ad-hoc 签名的本机 App；已校验的交接 ZIP 改为通过显式 `--archive` 生成。

- Rebuilt the control center with native sidebar, content, inspector, and toolbar-action layouts across Pet Library, AI Pet Maker, Pet Configuration, Agent Connections, and Service & Diagnostics; each pane now keeps one contextual heading instead of repeating the selected navigation title.

  控制中心重构为原生侧边栏、内容区、检查器与工具栏操作布局，覆盖宠物库、AI 宠物制作、宠物配置、Agent 连接和服务与诊断；各区域只保留一个上下文标题，不再重复当前导航名称。

- Reduced Agent Connections to a stable Agent-list and check-detail split: App/PetCore runtime identities, capability metadata, duplicate verification summaries, install-path exposition, repeated empty-state actions, and the obsolete project-folder scope were removed; connection management and desktop bubbles now consistently present the Agent/session model across all projects.

  Agent 连接页收敛为稳定的 Agent 列表与检查详情双栏：移除 App/PetCore 运行身份、能力元数据、重复验证摘要、安装路径展示、空状态重复操作和过时的项目目录范围；连接管理与桌宠气泡统一按 Agent/会话模型覆盖所有项目。

- Reduced default information density across the remaining control-center pages: Pet Library technical details are disclosed on demand, AI Pet Maker keeps fixed contracts in contextual help, Pet Configuration removes repeated headings and preview summaries, and Service & Diagnostics consolidates archive metadata.

  其余控制中心页面同步降低默认信息密度：宠物库技术详情改为按需展开，AI 宠物制作的固定合同收进上下文帮助，宠物配置移除重复标题与预览摘要，服务与诊断合并归档元数据。

- Refined desktop-pet bubbles with per-Agent session groups, attention-state pinning, regular Liquid Glass on macOS 26, accessible hover controls, and a 24 pt bottom-right resize handle.

  桌宠气泡改为按 Agent 分组，并加入需关注状态置顶、macOS 26 原生 regular Liquid Glass、无障碍悬停控件与 24 pt 右下缩放手柄。

- Waiting and failed Agent sessions now remain visible until their session advances or the user dismisses them, independent of the ordinary message timeout.

  等待确认与失败的 Agent 会话现在不受普通消息超时影响，会保持显示到会话推进或用户收起。

- Pet details now show the verified current immutable revision ID and bounded owned-revision count reported by PetCore.

  宠物详情现在会显示由 PetCore 校验并报告的当前不可变 revision ID 与有界自有修订数量。

- Revision history can select an older validated App-owned revision as an immutable edit baseline, and edit retries preserve that exact submitted baseline instead of following a later head.

  修订历史现在可选择更早的、已校验的 App 自有 revision 作为不可变修改基线；修改重试会保留确切的已提交基线，不会跟随之后变化的 head。

- Made bundled pets read-only while allowing a new-ID customization draft, and allowing App-created and imported pets to start revision-based edit sessions.

  内置宠物改为只读并可准备新 ID 定制草稿；App 创建与外部导入宠物可通过 revision 模型发起修改会话。

- Agent connector repair, path-conflict, and managed-uninstall actions now follow typed PetCore capabilities, while each check row uses its own typed recovery action and a distinct VoiceOver label; policy, legacy, unknown, or incomplete responses fail closed instead of enabling repair.

  Agent 连接器的修复、路径冲突与托管卸载动作现在使用 PetCore 类型化能力，每个检查项也使用独立的类型化恢复动作与可区分的 VoiceOver 标签；策略项、旧版、未知或字段不完整的响应会安全禁用修复，而不会误启用破坏性控件。

- Claude Hooks policy checks now use a dedicated typed presentation with localized manual-policy guidance, so Install or Repair is never suggested for `disableAllHooks`, `allowManagedHooksOnly`, or administrator-managed restrictions.

  Claude Hooks 策略检查现在使用独立的类型化展示与本地化手动处理指引；对于 `disableAllHooks`、`allowManagedHooksOnly` 或管理员管理的限制，不再建议“安装或修复”。

- Completed AI Pet Maker sessions with a durable result remain visible with the exact pet ID, immutable revision ID, and validation counts until the user opens the library or starts a new brief; legacy completed records without a result pet remain `succeeded` but show an incomplete-history warning without a library action or inferred metadata.

  带有持久结果的 AI 宠物制作完成后会保留准确的宠物 ID、不可变 revision ID 与校验计数，直到用户主动打开宠物库或开始新需求；缺少结果宠物的旧完成记录仍保持 `succeeded` 协议态，但只显示历史不完整提示，不提供宠物库入口或推断元数据。

- The most recent AI Pet Maker session now returns after an App restart, including failed or canceled creates that never produced a pet ID, while an in-progress new brief is never overwritten.

  App 重启后会恢复最近一次 AI 宠物制作会话，包括尚未产生宠物 ID 的失败或取消任务；已开始填写的新需求不会被覆盖。

- Review-ready Agent sessions now remain visible until opened, dismissed, or advanced; when more than eight sessions are active, the overlay provides a bounded summary that opens Control Center.

  等待查看的 Agent 会话现在会持续显示到用户打开、收起或会话推进；活跃会话超过八个时，桌宠会提供可打开控制中心的有界汇总入口。

- Added localized VoiceOver actions for opening or hiding individual sessions, closing a bubble, and expanding or collapsing a session group.

  为打开或收起单个会话、关闭气泡及展开或收起会话组新增本地化 VoiceOver 动作。

- Desktop-pet sessions and the resize handle can be explicitly moved into Full Keyboard Access from the App menu, MenuBarExtra, `Command-Shift-B`, or `Command-Shift-R`, without making ordinary overlay updates steal focus.

  可通过 App 菜单、MenuBarExtra、`Command-Shift-B` 或 `Command-Shift-R` 显式将桌宠会话与缩放手柄移入全键盘控制，普通桌宠状态更新不会抢占焦点。

- The Service & Diagnostics action now refreshes healthy status without restarting PetCore, while unhealthy states continue to offer explicit recovery.

  “服务与诊断”在健康状态下只刷新状态而不重启 PetCore，异常状态下则继续提供明确的恢复操作。

- AI Pet Maker now enforces four PNG/WebP references, per-file and combined byte/pixel budgets, and the shared 8,000-scalar brief boundary before a job starts.

  AI 宠物制作现在会在任务启动前执行最多四张 PNG/WebP、单文件与总字节/像素预算，以及统一的 8,000 Unicode scalar 需求边界。

### Fixed / 修复

- Codex convergence no longer mistakes an exact Studio Skill from the App's last verified installation for a user customization when a later development build carries different bundled content. The verified installation result now binds the source and active-cache Studio digests, the exact transient App-managed `0.5.3` digest is recoverable, and the changed bundle advances to `0.5.4`; genuinely customized or unsafe files still fail closed.

  当后续开发构建携带不同的内置内容时，Codex 收敛不再把 App 上一次已验证安装的精确 Studio Skill 误判为用户定制。已验证安装结果现在会绑定插件源与活动缓存的 Studio 摘要，曾由 App 管理的临时 `0.5.3` 精确摘要可被安全恢复，同时变更后的能力包升级为 `0.5.4`；真正经过定制或路径不安全的文件仍会安全拒绝覆盖。

- Pet Library's Metal preview now defers its initial content replay beyond the active `NSViewRepresentable` update, invalidates delayed callbacks when a renderer is replaced, and ignores unchanged or stale render identities. Native bubble glass also avoids reapplying unchanged AppKit appearance properties, eliminating view-update state writes and redundant layout invalidation.

  宠物库 Metal 预览现在会把首次内容回放延迟到当前 `NSViewRepresentable` 更新结束之后，在渲染器被替换时使延迟回调失效，并忽略未变化或已过期的渲染身份；原生气泡玻璃也不再重复写入未变化的 AppKit 外观属性，从源头消除视图更新期间的状态写入与冗余布局失效。

- Restored the full Rust validation gate by encoding JPEG test fixtures from RGB data, matching JPEG's supported color model. Bubble regression tests now inspect the current production source and render waiting, completed, and failed foreground symbols independently of `NSGlassEffectView`'s unsupported offscreen backdrop capture, while separate tests retain coverage of the native glass composition.

  JPEG 测试夹具现改用其支持的 RGB 色彩模型编码，恢复 Rust 全量验证门禁；气泡回归测试改为检查当前生产源码，并在不依赖 `NSGlassEffectView` 不受支持的离屏背景采样时验证等待、完成与失败前景图标，同时由独立测试继续覆盖原生玻璃组合关系。

- AI Pet Maker now gives explicit creation sessions an interactive App Server startup budget, so ordinary CI or workstation scheduling pressure no longer sends a healthy request through the development-only local fallback.

  AI 宠物制作的显式创建会话现在使用交互式 App Server 启动预算，避免 CI 或工作站的正常调度压力把健康请求误切换到仅供开发使用的本地回退。

- Restored useful desktop-bubble context: each session can again show its bounded title or user context without synthetic multi-session numbering, plus the latest current-turn Agent reply, while typed activity/status copy remains the fallback.

  恢复桌宠气泡的有效上下文：每个会话会原样显示有界的会话标题或用户上下文，不再为同一 Agent 的多会话追加合成编号；同时显示当前轮次的最新 Agent 回复，缺少消息时仍使用类型化活动与状态文案兜底。

- Fixed the control-center chrome so the Agent Pet brand remains stable while feature actions use the native toolbar and content avoids redundant page headings, kept the longest English configuration label fully visible at the default width, and exposed a direct reference-image reselection action when a recovered Maker session cannot retry yet.

  修复控制中心标题栏，使 Agent Pet 品牌保持固定，功能操作进入原生工具栏且内容区不再重复页面标题；默认宽度下最长的英文配置标签现在可完整显示，恢复后的 Maker 会话若尚不能重试，也会直接提供重新选择参考图的操作。

- Desktop-pet bubbles now distinguish a result that is ready to review from a task that has already completed, in both the safe summary and status badge.

  桌宠气泡现在会在安全摘要与状态 badge 中明确区分“待查看结果”和“任务已完成”。

- Fixed Release app-bundle assembly so the Swift build keeps its required `build` subcommand when selecting the release configuration.

  修复 Release App 包组装脚本，选择 release 配置时会保留 Swift 所需的 `build` 子命令。

- Fixed desktop-pet hit testing so transparent pixels pass pointer events through, the per-frame alpha mask follows the drawable that actually reached the display, and the pet's geometric region remains hoverable and draggable while a mask is briefly unavailable during launch or a state transition.

  修复桌宠命中测试：透明像素会透传指针事件，逐帧 alpha 蒙版跟随真正显示到屏幕上的 drawable；启动或状态切换期间蒙版短暂不可用时，宠物几何区域仍可悬停和拖动。

- Fixed AI Pet Maker's Clear action so timing-only drafts can be cleared and native FPS plus every authored state duration return to their defaults.

  修复 AI 宠物制作的“清空”操作：仅修改时序的草稿现在也可清空，原生 FPS 与每个动作状态时长都会恢复默认值。

- Aligned the documented default validation entrypoint with CI by running Rust formatting and strict Clippy before workspace tests.

  将文档中的默认验证入口与 CI 对齐：工作区测试前会先执行 Rust 格式检查与严格 Clippy。

- Corrected the diagnostics archive scope copy to match the bounded retention contract of up to 14 days.

  修正诊断归档范围文案，使其与最长 14 天的有界保留契约一致。

- Fixed launch hydration so the library no longer flashes a false empty state, persisted appearance is applied before window chrome is revealed with a bounded system fallback, recovery paths cannot race the first bootstrap, and the desktop overlay waits for the first complete state snapshot.

  修复启动水合过程：宠物库不再短暂误报为空，窗口标题栏显示前会先应用已保存外观并提供有界系统回退，恢复操作不会与首次启动流程竞态，桌宠浮层也会等待首个完整状态快照。

- Fixed Dock, second-instance, MenuBarExtra, and overlay reopen actions so an open About window can no longer be mistaken for the control center.

  修复 Dock、二次启动、MenuBarExtra 与桌宠重新打开控制中心时可能误选 About 窗口的问题。

- Fixed the default-width AI Pet Maker workspace to keep its brief and session side by side, and allowed long Agent names and health summaries to wrap instead of being truncated.

  修复默认窗口宽度下 AI 宠物制作需求区与会话区未并排的问题，并让较长的 Agent 名称与健康摘要换行显示而不再截断。

- Fixed the Pet Library inspector so the default 1120 pt window keeps the complete three-column layout inside its bounds, while long metadata, protocol-state lists, frame-rate profiles, and revision IDs wrap within the available width.

  修复宠物库检查器：默认 1120 pt 窗口现在会将完整三栏布局保持在窗口边界内，长宠物元数据、协议状态列表、帧率档位与 revision ID 也会在可用宽度内换行。

- Made the pet-level session toggle compact: one session shows only a chevron, multiple sessions show only the count, and zero sessions hide the control entirely.

  宠物层会话开关恢复为紧凑尺寸：单会话仅显示箭头，多会话仅显示数量，无会话时完全隐藏。

- Fixed the pet-level session bubble control so first clicks and clicks after moving the pet reliably expand or collapse the bubble.

  修复宠物层会话气泡控件首击及移动宠物后的点击偶发无法展开或收起问题。

- Fixed the resize handle remaining visible after the pointer leaves the pet area.

  修复鼠标离开宠物区域后缩放手柄仍然显示的问题。

- Fixed App/PetCore runtime identity synchronization during App launch and explicit development relaunch.

  修复 App 启动与显式开发重启时 App/PetCore 运行时版本不同步的问题。

- Fixed Maker terminal failures being rendered as ordinary AI conversation cards; failures now appear only through the structured session notice.

  修复 Maker 终止失败被渲染成普通 AI 对话卡的问题；失败现在只通过结构化会话提示呈现。

- Fixed modification retry races that could resend a locally stale form or silently change an unversioned submitted baseline.

  修复修改重试可能回传本地过期表单，或静默更换无 revision ID 已提交基线的竞态。

- Fixed historical-revision edits so the Maker immediately shows the selected baseline timing, follow-up edits retain the latest committed timing unless explicitly changed, and timing revisions reject copied interpolation, naive downsampling, padding, truncation, or retiming of the old motion.

  修复历史 revision 修改的时序一致性：Maker 会立即显示所选基线的制作时序，后续修改会保留最近已提交时序，除非用户明确要求改变；同时拒绝复制补帧、非确定性降采样、填充、截断或简单重定时旧动作的伪时序 revision。

### Security / 安全

- Maker reference images are staged as bounded validated snapshots and consumed with no-follow, digest-checked reads so later path replacement cannot change the bytes used for generation.

  Maker 参考图以有界、已校验快照暂存，并通过禁止跟随符号链接且校验摘要的读取方式消费，后续路径替换无法改变生成所用字节。

- Maker restart recovery no longer returns original reference-image paths; only safe job-local copies cross the RPC boundary, otherwise the App receives a bounded reselection count.

  Maker 重启恢复不再返回参考图原始路径；RPC 只传递安全的任务内副本，否则向 App 返回有界的重新选择数量。
