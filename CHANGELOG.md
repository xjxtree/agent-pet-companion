# Changelog / 版本变更记录

This file records user-visible changes. Every GitHub Release must correspond to exactly one version section named `[x.y.z] - YYYY-MM-DD`; its Git tag must be `vx.y.z`. During development, changes accumulate under `[Unreleased]`. When publishing, rename that section to the released version and create a new empty `[Unreleased]` section above it.

本文件记录用户可见变化。每个 GitHub Release 必须对应且只对应一个 `[x.y.z] - YYYY-MM-DD` 版本段，Git tag 使用 `vx.y.z`。开发中的变化统一写入 `[Unreleased]`；发布时将其改为实际版本，并在上方新建空的 `[Unreleased]`。

Use the `Added`, `Changed`, `Fixed`, `Deprecated`, `Removed`, and `Security` categories only when they apply. Do not store test logs, implementation diaries, pending-work lists, or release evidence here; those belong in CI and the GitHub Release notes for the exact artifact.

仅在适用时使用 `Added`、`Changed`、`Fixed`、`Deprecated`、`Removed` 与 `Security` 分类。不要在这里保存测试日志、实现过程、待办列表或发布证据；这些内容应进入对应产物的 CI 与 GitHub Release notes。

## [Unreleased]

### Added / 新增

- Added bundled `星雾团子` and `Bytebud 字节芽` pets to the first-launch library. / 首次打开即可在宠物库中看到内置的 `星雾团子` 与 `Bytebud 字节芽`。
- Added privacy-filtered diagnostics ZIP export with bounded App/PetCore logs and environment metadata. / 新增经过隐私过滤的诊断 ZIP 导出，包含有界的 App/PetCore 日志与环境元数据。
- Added the approved transparent Agent Pet Companion brand mark across App surfaces. / App 各处统一使用已确认的透明 Agent Pet Companion 品牌图标。

### Changed / 变更

- Development builds now produce only the ad-hoc-signed local App by default; the verified handoff ZIP is available through explicit `--archive`. / 开发构建默认仅生成 ad-hoc 签名的本机 App；已校验的交接 ZIP 改为通过显式 `--archive` 生成。
- Rebuilt the control center with native sidebar, content, inspector, and page-action layouts across Pet Library, AI Pet Maker, Pet Configuration, Agent Connections, and the new Service & Diagnostics entry. / 控制中心重构为原生侧边栏、内容区、检查器与页面动作布局，并调整为宠物库、AI 宠物制作、宠物配置、Agent 连接和新增的服务与诊断五个入口。
- Refined desktop-pet bubbles with per-Agent session groups, attention-state pinning, regular Liquid Glass on macOS 26, accessible hover controls, and a 24 pt bottom-right resize handle. / 桌宠气泡改为按 Agent 分组，并加入需关注状态置顶、macOS 26 原生 regular Liquid Glass、无障碍悬停控件与 24 pt 右下缩放手柄。
- Waiting and failed Agent sessions now remain visible until their session advances or the user dismisses them, independent of the ordinary message timeout. / 等待确认与失败的 Agent 会话现在不受普通消息超时影响，会保持显示到会话推进或用户收起。
- Pet details now show the verified current immutable revision ID and bounded owned-revision count reported by PetCore. / 宠物详情现在会显示由 PetCore 校验并报告的当前不可变 revision ID 与有界自有修订数量。
- Revision history can select an older validated App-owned revision as an immutable edit baseline, and edit retries preserve that exact submitted baseline instead of following a later head. / 修订历史现在可选择更早的、已校验的 App 自有 revision 作为不可变修改基线；修改重试会保留确切的已提交基线，不会跟随之后变化的 head。
- Made bundled pets read-only while allowing a new-ID customization draft, and allowing App-created and imported pets to start revision-based edit sessions. / 内置宠物改为只读并可准备新 ID 定制草稿；App 创建与外部导入宠物可通过 revision 模型发起修改会话。
- Agent connector repair, path-conflict, and managed-uninstall actions now follow typed PetCore capabilities, while each check row uses its own typed recovery action and a distinct VoiceOver label; policy, legacy, unknown, or incomplete responses fail closed instead of enabling repair. / Agent 连接器的修复、路径冲突与托管卸载动作现在使用 PetCore 类型化能力，每个检查项也使用独立的类型化恢复动作与可区分的 VoiceOver 标签；策略项、旧版、未知或字段不完整的响应会安全禁用修复，而不会误启用破坏性控件。
- Claude Hooks policy checks now use a dedicated typed presentation with localized manual-policy guidance, so Install or Repair is never suggested for `disableAllHooks`, `allowManagedHooksOnly`, or administrator-managed restrictions. / Claude Hooks 策略检查现在使用独立的类型化展示与本地化手动处理指引；对于 `disableAllHooks`、`allowManagedHooksOnly` 或管理员管理的限制，不再建议“安装或修复”。
- Completed AI Pet Maker sessions with a durable result remain visible with the exact pet ID, immutable revision ID, and validation counts until the user opens the library or starts a new brief; legacy completed records without a result pet remain `succeeded` but show an incomplete-history warning without a library action or inferred metadata. / 带有持久结果的 AI 宠物制作完成后会保留准确的宠物 ID、不可变 revision ID 与校验计数，直到用户主动打开宠物库或开始新需求；缺少结果宠物的旧完成记录仍保持 `succeeded` 协议态，但只显示历史不完整提示，不提供宠物库入口或推断元数据。
- The most recent AI Pet Maker session now returns after an App restart, including failed or canceled creates that never produced a pet ID, while an in-progress new brief is never overwritten. / App 重启后会恢复最近一次 AI 宠物制作会话，包括尚未产生宠物 ID 的失败或取消任务；已开始填写的新需求不会被覆盖。
- Review-ready Agent sessions now remain visible until opened, dismissed, or advanced; when more than eight sessions are active, the overlay provides a bounded summary that opens Control Center. / 等待查看的 Agent 会话现在会持续显示到用户打开、收起或会话推进；活跃会话超过八个时，桌宠会提供可打开控制中心的有界汇总入口。
- Added localized VoiceOver actions for opening or hiding individual sessions, closing a bubble, and expanding or collapsing a session group. / 为打开或收起单个会话、关闭气泡及展开或收起会话组新增本地化 VoiceOver 动作。
- Desktop-pet sessions and the resize handle can be explicitly moved into Full Keyboard Access from the App menu, MenuBarExtra, `Command-Shift-B`, or `Command-Shift-R`, without making ordinary overlay updates steal focus. / 可通过 App 菜单、MenuBarExtra、`Command-Shift-B` 或 `Command-Shift-R` 显式将桌宠会话与缩放手柄移入全键盘控制，普通桌宠状态更新不会抢占焦点。
- The Service & Diagnostics action now refreshes healthy status without restarting PetCore, while unhealthy states continue to offer explicit recovery. / “服务与诊断”在健康状态下只刷新状态而不重启 PetCore，异常状态下则继续提供明确的恢复操作。
- AI Pet Maker now enforces four PNG/WebP references, per-file and combined byte/pixel budgets, and the shared 8,000-scalar brief boundary before a job starts. / AI 宠物制作现在会在任务启动前执行最多四张 PNG/WebP、单文件与总字节/像素预算，以及统一的 8,000 Unicode scalar 需求边界。

### Fixed / 修复

- Fixed the control-center title so it follows the selected top-level page, kept the longest English configuration label fully visible at the default width, and exposed a direct reference-image reselection action when a recovered Maker session cannot retry yet. / 修复控制中心标题未随顶层页面切换的问题；默认宽度下最长的英文配置标签现在可完整显示，恢复后的 Maker 会话若尚不能重试，也会直接提供重新选择参考图的操作。
- Desktop-pet bubbles now distinguish a result that is ready to review from a task that has already completed, in both the safe summary and status badge. / 桌宠气泡现在会在安全摘要与状态 badge 中明确区分“待查看结果”和“任务已完成”。
- Fixed Release app-bundle assembly so the Swift build keeps its required `build` subcommand when selecting the release configuration. / 修复 Release App 包组装脚本，选择 release 配置时会保留 Swift 所需的 `build` 子命令。
- Fixed desktop-pet hit testing so transparent pixels pass pointer events through, while the per-frame alpha mask follows the drawable that actually reached the display across skipped frames, failures, state changes, and renderer teardown. / 修复桌宠命中测试：透明像素现在会透传指针事件；逐帧 alpha 蒙版会跟随真正显示到屏幕上的 drawable，并在跳帧、渲染失败、状态切换与渲染器销毁时保持正确。
- Corrected the diagnostics archive scope copy to match the bounded retention contract of up to 14 days. / 修正诊断归档范围文案，使其与最长 14 天的有界保留契约一致。
- Fixed launch hydration so the library no longer flashes a false empty state, persisted appearance is applied before window chrome is revealed with a bounded system fallback, recovery paths cannot race the first bootstrap, and the desktop overlay waits for the first complete state snapshot. / 修复启动水合过程：宠物库不再短暂误报为空，窗口标题栏显示前会先应用已保存外观并提供有界系统回退，恢复操作不会与首次启动流程竞态，桌宠浮层也会等待首个完整状态快照。
- Fixed Dock, second-instance, MenuBarExtra, and overlay reopen actions so an open About window can no longer be mistaken for the control center. / 修复 Dock、二次启动、MenuBarExtra 与桌宠重新打开控制中心时可能误选 About 窗口的问题。
- Fixed the default-width AI Pet Maker workspace to keep its brief and session side by side, and allowed long Agent names and health summaries to wrap instead of being truncated. / 修复默认窗口宽度下 AI 宠物制作需求区与会话区未并排的问题，并让较长的 Agent 名称与健康摘要换行显示而不再截断。
- Fixed the Pet Library inspector so the default 1120 pt window keeps the complete three-column layout inside its bounds, while long metadata, protocol-state lists, frame-rate profiles, and revision IDs wrap within the available width. / 修复宠物库检查器：默认 1120 pt 窗口现在会将完整三栏布局保持在窗口边界内，长宠物元数据、协议状态列表、帧率档位与 revision ID 也会在可用宽度内换行。
- Made the pet-level session toggle compact: one session shows only a chevron, multiple sessions show only the count, and zero sessions hide the control entirely. / 宠物层会话开关恢复为紧凑尺寸：单会话仅显示箭头，多会话仅显示数量，无会话时完全隐藏。
- Fixed the pet-level session bubble control so first clicks and clicks after moving the pet reliably expand or collapse the bubble. / 修复宠物层会话气泡控件首击及移动宠物后的点击偶发无法展开或收起问题。
- Fixed the resize handle remaining visible after the pointer leaves the pet area. / 修复鼠标离开宠物区域后缩放手柄仍然显示的问题。
- Fixed App/PetCore runtime identity synchronization during App launch and explicit development relaunch. / 修复 App 启动与显式开发重启时 App/PetCore 运行时版本不同步的问题。
- Fixed Maker terminal failures being rendered as ordinary AI conversation cards; failures now appear only through the structured session notice. / 修复 Maker 终止失败被渲染成普通 AI 对话卡的问题；失败现在只通过结构化会话提示呈现。
- Fixed modification retry races that could resend a locally stale form or silently change an unversioned submitted baseline. / 修复修改重试可能回传本地过期表单，或静默更换无 revision ID 已提交基线的竞态。

### Security / 安全

- Desktop overlay projections are now content-free and type-allowlisted: prompts, assistant replies, paths, file contents, command arguments, activity detail, and credentials never enter the bubble payload or its Swift display fallbacks. / 桌宠气泡投影改为无内容、类型白名单契约：提示词、Agent 回复、路径、文件内容、命令参数、活动详情与凭据不会进入气泡 payload，也不会通过 Swift 显示回退泄漏。
- Maker reference images are staged as bounded validated snapshots and consumed with no-follow, digest-checked reads so later path replacement cannot change the bytes used for generation. / Maker 参考图以有界、已校验快照暂存，并通过禁止跟随符号链接且校验摘要的读取方式消费，后续路径替换无法改变生成所用字节。
- Maker restart recovery no longer returns original reference-image paths; only safe job-local copies cross the RPC boundary, otherwise the App receives a bounded reselection count. / Maker 重启恢复不再返回参考图原始路径；RPC 只传递安全的任务内副本，否则向 App 返回有界的重新选择数量。
