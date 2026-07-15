# ChatGPT / Codex 合并影响与落地记录（2026-07-13）

> 2026-07-14 同步说明：本文记录 ChatGPT/Codex 合并的专项影响；当前代码验证和发布阻塞项以[项目状态](../PROJECT_STATUS.md)为准。下表“已完成”表示本地实现或契约已落地，不等于真实 ChatGPT/Codex 环境验收已完成。

## 结论 / Conclusion

新的 ChatGPT 桌面 App 在同一产品壳中提供 Chat、Work 与 Codex；既有 Codex task/project 会保留，Codex 本地任务仍使用本地文件、仓库、终端与开发工具。此次合并是产品入口和桌面运行时的整合，不是向第三方桌宠开放 Chat、Work、Codex 全部会话的全局事件订阅。

The new ChatGPT desktop app combines Chat, Work, and Codex in one shell while preserving existing Codex tasks and projects. This is a product/runtime consolidation, not a public global conversation feed for third-party desktop companions.

## 官方 Pets 基线 / Official Pets baseline

- 状态：Running、Needs input、Ready、Blocked。
- 多任务优先级：Needs input > Blocked > Ready > Running。
- 桌面宠物可浮于其他窗口之上；点击宠物回到 ChatGPT，点击活动打开任务。
- 官方公开文档没有提供让第三方应用订阅 ChatGPT 桌面 App 全部内部 task/activity tray 的 API。

Agent Pet Companion 对齐上述状态和优先级，并在用户要求下增加最近一条受控 Agent 回复的持续展示。同一 Agent 的会话只在一个气泡内做有界分组（最多 8 条），V1 不复制官方多任务 activity tray，也不扩展为任务控制台。

## 已完成影响项 / Completed impact items

| 优先级 | 风险 | 落地结果 |
|---|---|---|
| P0 | 30 秒 lease 使仍在运行的会话退回空闲文案 | 新 adapter 写入 `session_active`；活动态无 lease，直到 Stop/失败/idle |
| P0 | 旧 PetCore 守护进程健康但协议/行为过期 | health 返回 `rpc_protocol`、`build_id` 与 `instance_id`；App 只复用协议和构建均匹配的进程，并用 instance-bound shutdown 与 LaunchAgent 重载完成交接 |
| P0 | 连接自检发送 strict schema 禁止字段 | 自检改为完整 allowlist envelope，diagnostic 事件可真实 round-trip |
| P0 | 新 ChatGPT 内嵌 Codex 比 PATH CLI 新 | App Server、plugin 检查与安装优先使用 ChatGPT bundle CLI |
| P0 | ChatGPT 桌面有活跃 Codex task，但插件 hooks 未触发时本 App 完全不显示 | 增加 App Server 有界近期活动同步：`thread/list(useStateDbOnly=true)` 只取配置时限内最多 8 个交互任务，再以 `thread/read` 提取标题、turn 状态与有界最新消息；原始响应和工具内容不落盘 |
| P1 | 气泡只有通用标题，没有会话内容 | 提取 bounded UserPromptSubmit prompt 与 Stop final assistant message；Codex 按显式 session_id 只读补全真实标题和最近 Agent 回复，工具参数/输出仍丢弃 |
| P1 | 工具事件覆盖用户/Agent 消息 | 展示状态分别保留 `latest_user_message` 与 `latest_message`，按 source/session/role 持久化回查 |
| P1 | 等待确认不明显 | PermissionRequest 映射 Needs input/approval_required，显示交互提示和处理入口 |
| P1 | 状态优先级与官方 Pets 不一致 | 改为 Needs input > Blocked > Ready > Running |
| P1 | 点击气泡只打开本项目窗口、误触收起或把 CLI 会话错送到 ChatGPT | 每个会话行拥有独立、无重叠命中区域；CLI 优先使用捕获到的终端 session target，Codex 仅在确认属于 ChatGPT 桌面 surface 时使用 `codex://threads/<session_id>`，其余退回对应 App |
| P1 | 多个会话互相覆盖或无限常驻 | 每个 Agent 一个气泡，同 Agent 最多 8 个会话分行；普通会话默认 15 分钟收起，新用户消息重激活，active 的 Needs input/Blocked 持续显示，已关闭 Waiting 不占历史位置 |
| P1 | installed/enabled 被误判为 hooks 已信任 | ON_INSTALL 不再判定为 trusted，要求用户在 ChatGPT Codex 中 review/trust |
| P1 | 有损 turn 把已完成 `fileChange` 当成当前 Shell/读取活动，旧思考在工具阶段滞留 | App Server 同步改为 1 秒；只接受 `inProgress` 状态项为当前工具，按 `commandActions` 区分读取/搜索/Shell，同一 turn 用稳定状态记录原位更新；可见 revision 未变但 `updatedAt` 推进时清除旧内容并显示通用活动，不泄露参数 |
| P2 | ChatGPT 合并边界不清导致读取本地私有状态 | 明确禁止读取 auth/token/cookie/transcript 和 ChatGPT 私有数据库，只使用 hooks/App Server 显式通道 |

## 能力边界 / Capability boundary

外部 ChatGPT Codex task 以官方 hooks 作为精确生命周期来源；纯推理阶段、hooks 尚未获信任或 hooks 未覆盖时，由 App Server 的有界近期任务查询兜底。跨进程 App Server 会把外部任务报告为 `notLoaded`，未完成 turn 也可能重载为 `interrupted`，而持久化 ThreadItems 明确可能省略 command execution；所以兜底只按最近 `updatedAt` 建立默认 15 分钟的有限租约，明确的 `activeFlags`、`completed`、`failed` 才直接映射 Needs input、Ready、Blocked，不能把已完成文件项或旧思考伪装成实时 Shell。PetCore 自己创建的 Pet Studio 会话可通过自己的 App Server 连接读取 streamed events。三者不能被宣称为等价，也不能连接到 Chat/Work 私有历史。

External ChatGPT Codex tasks use supported hooks for exact lifecycle events and a bounded, read-only App Server recent-task query as fallback. Cross-process `notLoaded`/`interrupted` values are treated as finite recency leases rather than exact official runtime state. Only PetCore-owned Pet Studio App Server sessions have a first-party stream owned by this app.

## 当前剩余验收 / Remaining acceptance

- 当前仅剩用户控制的持久 Hook review/trust：配置存在和一次 bypass-trust canary 不能代替用户在 ChatGPT 中确认长期信任；精确 PreToolUse 等能力继续按“未验证”展示。
- 真实 `codex app-server` 近期任务轮询、标题/消息/公开活动、完成/失败及跨进程有限租约 gate 已完成；后续仅需随 ChatGPT 更新重复 canary。
- ChatGPT 内嵌 Codex CLI、connector contract、App/PetCore/CLI、数据库/事件 schema 和 `.petpack` 读写版本已统一进入 `apc.runtime-manifest.v1`，并实现候选预检、last-known-good 回滚与稳定 connector CLI 入口。
- 每次 ChatGPT/Codex 更新后运行真实 canary，并把“已验证版本”和“未验证但已安装”分开显示。

## 维护观察点 / Maintenance watchpoints

- ChatGPT bundle 内嵌 CLI 路径、hooks 字段和 App Server 协议发生官方变更时，升级 connector contract 并运行真实事件 canary。
- 持续验证 ChatGPT 注册的 `codex://threads/<session_id>` 路由，但只用于已确认的桌面任务；CLI/未知 surface 不盲用该深链。Warp 通过严格 allowlist 的 `WARP_FOCUS_URL` 精确聚焦原 pane，失效时仅激活 Warp App。若协议变化，只更新显式适配，不解析私有状态。
- 若官方后续开放跨任务 activity API，仍保持 V1 导航不变，并只在现有 8 条有界气泡列表内适配，不演变为 mission-control 平台。

## 官方资料 / Official sources

- [Pets](https://learn.chatgpt.com/docs/pets)
- [ChatGPT desktop app](https://learn.chatgpt.com/docs/app)
- [Moving to the new ChatGPT desktop app](https://help.openai.com/en/articles/20001276/)
- [ChatGPT Work and Codex](https://help.openai.com/en/articles/20001275/)
- [Codex hooks](https://developers.openai.com/codex/hooks)
- [Codex App Server](https://developers.openai.com/codex/app-server/)
