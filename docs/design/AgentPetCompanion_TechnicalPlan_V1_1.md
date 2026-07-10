# Agent Pet Companion 技术方案 V1.1

> 基于 V5 产品设计：macOS 原生桌宠 App；只做宠物制作、宠物库、启用与行为、Agent 连接；支持 Codex、Claude Code、Pi Coding Agent、OpenCode；不做公共素材库，不兼容导出 Codex 内置宠物包。

---

## 1. 技术目标

Agent Pet Companion 是一个 **高画质、高自由度、AI 生成、多 Agent 响应的 macOS 桌宠 App**。

V1 技术目标固定为：

1. macOS 原生 App，使用 SwiftUI + AppKit 实现主界面与桌宠悬浮层。
2. Rust Core 作为本地常驻服务，负责宠物资源、Agent 事件、AI 生成会话、状态聚合、配置检查。
3. 宠物 Studio 通过初始表单发起 AI 会话，后续制作流程在会话窗口中完成。
4. AI 生成固定使用 Codex App Server + 内置 Pet Studio Skill。
5. Agent 状态感知支持 Codex、Claude Code、Pi Coding Agent、OpenCode。
6. 宠物格式使用自研 `.petpack`，只服务本 App，不生成 Codex 内置宠物兼容包。
7. 宠物素材支持四档实机渲染分辨率：标清、高清、超清、原画。
8. 动作帧率提供两档：**标准动效 12 FPS** 与 **流畅动效 20 FPS**。
9. 桌宠尺寸不在设置页配置，用户通过悬浮层右下角缩放手柄直接调整。
10. App 不读取任何 Agent 的 auth、token、cookie、API Key 文件。

---

## 2. 分辨率与帧率推演

### 2.1 图像画质定义

图像画质表示 **实机桌宠渲染分辨率**，不是素材源文件分辨率，也不是导出兼容包分辨率。

| 图像画质 | 单帧尺寸 | 像素量 | RGBA 单帧内存 | 定位 |
|---|---:|---:|---:|---|
| 标清 | 192×208 | 0.04 MP | 0.15 MB | 小尺寸、低占用 |
| 高清 | 384×416 | 0.16 MP | 0.61 MB | 默认推荐 |
| 超清 | 768×832 | 0.64 MP | 2.44 MB | 高画质桌面显示 |
| 原画 | 1536×1664 | 2.56 MP | 9.75 MB | 大尺寸、收藏级显示 |

计算方式：

```text
RGBA 单帧内存 = width × height × 4 bytes
```

### 2.2 为什么帧率不做 24 FPS

桌宠常驻在桌面上，用户对它的要求是“好看、有响应、长期低打扰”，不是游戏角色那样持续高帧率。若做 24 FPS，原画档 2 秒循环需要 48 帧：

```text
1536 × 1664 × 4 × 48 ≈ 468 MB
```

这只是单个状态的预解码纹理内存。若再考虑状态切换、预热缓存、生成中预览、多个窗口动画，容易造成不必要的内存与解码压力。

因此 V1 不把 24 FPS 作为用户可选档位。帧率固定为两档：

| 档位 | 帧率 | 每 2 秒循环帧数 | 用途 |
|---|---:|---:|---|
| 标准动效 | 12 FPS | 24 帧 | 默认档，长期开启 |
| 流畅动效 | 20 FPS | 40 帧 | 更顺滑，资源仍可控 |

选择 20 FPS 的原因：

1. 20 FPS 在 60Hz 屏幕上约每 3 个显示帧更新一次，观感明显优于 12 FPS。
2. 相比 24 FPS，原画档单状态缓存减少约 17%。
3. 对桌宠动作来说，20 FPS 已足够表现衣摆、头发、表情、工具响应等细节。
4. 可以通过 Metal 渲染 + 环形缓存把 CPU 和内存控制在可接受范围内。

### 2.3 不同画质下的单状态解码内存

按 2 秒循环计算：

| 画质 | 12 FPS / 24 帧 | 20 FPS / 40 帧 |
|---|---:|---:|
| 标清 | 3.7 MB | 6.1 MB |
| 高清 | 14.6 MB | 24.4 MB |
| 超清 | 58.5 MB | 97.5 MB |
| 原画 | 234 MB | 390 MB |

结论：

1. 标清、高清、超清可以完整预解码当前状态帧。
2. 原画档不能长期完整预解码多个状态。
3. 原画档必须使用 **环形帧缓存**，只缓存当前播放窗口附近的帧。
4. 所有画质都只预热当前状态与即将切换状态，不预解码全宠物所有状态。

### 2.4 V1 运行时性能预算

V1 以 Apple Silicon MacBook 为主要优化目标，性能预算固定为：

| 场景 | CPU 平均占用 | Renderer 内存 | 说明 |
|---|---:|---:|---|
| 悬浮层隐藏 | < 1% | < 80 MB | 暂停动画 |
| 12 FPS 标清/高清/超清 | ≤ 4% | ≤ 180 MB | 默认路径 |
| 20 FPS 标清/高清/超清 | ≤ 7% | ≤ 260 MB | 流畅路径 |
| 12 FPS 原画 | ≤ 6% | ≤ 320 MB | 环形缓存 |
| 20 FPS 原画 | ≤ 9% | ≤ 420 MB | 环形缓存 |

预算的验收口径固定如下，避免用理论像素缓存替代真实运行时测量：

1. CPU 是悬浮层进入稳定状态后至少 30 秒内的进程累计 CPU time 增量除以实测窗口；重复采样同时记录瞬时峰值，但以上述窗口平均值执行上表门禁。
2. “Renderer 内存”是同一 App 进程在“悬浮层隐藏、无活动帧”的稳定 RSS 中位数之上，播放目标画质时的 RSS 峰值增量；同时单独记录绝对 App RSS。
3. 验收必须同时记录驻留解码帧缓存、Metal device 当前分配、drawable texture 实际分配与进程 RSS 增量。`width × height × 4 × frames` 只用于容量规划，不能单独证明满足预算。
4. 隐藏悬浮层单独验证 CPU 平均占用 `< 1%`。流畅档还要求 20 FPS 时间线的实测播放帧率不低于 18 FPS。

超过预算时，内部自动执行保护策略：

```text
优先丢弃非当前状态缓存
然后降低预读帧数
再跳过重复纹理上传
最后按时间轴跳帧，保持动作时长不变
```

这不是用户可见配置，属于运行时资源保护。

---

## 3. 总体架构

```text
┌────────────────────────────────────────────┐
│ macOS Native App                           │
│ SwiftUI + AppKit                           │
│ - 宠物 Studio                              │
│ - 宠物库                                   │
│ - 启用与行为                               │
│ - Agent 连接                               │
│ - 桌宠悬浮层                               │
└───────────────────┬────────────────────────┘
                    │ Unix Domain Socket JSON-RPC
                    ▼
┌────────────────────────────────────────────┐
│ PetCore Rust Daemon                        │
│ - AI 生成会话管理                          │
│ - .petpack 构建/校验/安装                  │
│ - Metal 资源索引与缓存策略                 │
│ - Agent 事件聚合                           │
│ - 配置检查与修复                           │
│ - SQLite 状态存储                          │
└───────────────────┬────────────────────────┘
                    │
      ┌─────────────┼────────────────┬─────────────┐
      ▼             ▼                ▼             ▼
┌──────────┐  ┌────────────┐  ┌──────────┐  ┌────────────┐
│ Codex    │  │ Claude Code│  │ Pi Agent │  │ OpenCode   │
│ Plugin   │  │ Hooks      │  │ Extension│  │ Plugin     │
│ AppServer│  │            │  │ V1 observe│ │            │
└──────────┘  └────────────┘  └──────────┘  └────────────┘
```

V1 不把 MCP 作为必需组件。Agent 状态感知走各 Agent 官方支持的 hook、plugin、extension 或 event stream；宠物生成走 Codex App Server。

---

## 4. macOS App 技术设计

### 4.1 技术栈

```text
UI: SwiftUI
窗口与悬浮层: AppKit / NSPanel
渲染: Metal-backed Layer
动画调度: CVDisplayLink + 自定义 frame scheduler
IPC: Unix Domain Socket JSON-RPC
后台服务: Rust petcore daemon
```

### 4.2 页面结构

```text
宠物 Studio
  ├─ 新建
  └─ 宠物库

启用与行为

Agent 连接
```

### 4.3 桌宠悬浮层

悬浮层使用 `NSPanel`，行为固定如下：

| 功能 | 实现 |
|---|---|
| 置顶显示 | floating window level |
| 不抢焦点 | non-activating panel |
| 拖动 | AppKit 处理拖拽 |
| 缩放 | 右下角 resize handle |
| 透明背景 | premultiplied alpha texture |
| 动画播放 | Metal texture swap |
| 鼠标穿透 | 行为页开关控制 |
| 收起 | 菜单栏或悬浮层按钮 |

悬浮层不使用 SwiftUI 高频重绘。SwiftUI 只负责控制面板，宠物动画由 Metal 层单独绘制。

---

## 5. 宠物资源格式 `.petpack`

`.petpack` 是 zip 包，内部结构固定：

```text
manifest.json
brief.json
assets/
  frames/
    idle/
    start/
    tool/
    waiting/
    review/
    done/
    failed/
  preview/
    cover.png
    animated_preview.webp
source/
  prompt.md
  source.json
  references/
  skill_session.jsonl
build/
  validation.json
```

### 5.1 manifest.json

```json
{
  "schema_version": "apc.petpack.v1",
  "id": "pet_01jz...",
  "name": "粉色古风少女",
  "style": "半写实",
  "quality": "ultra",
  "render_size": { "width": 768, "height": 832 },
  "fps_profiles": {
    "standard": 12,
    "smooth": 20
  },
  "default_fps_profile": "standard",
  "states": [
    { "name": "idle", "frames_dir": "assets/frames/idle", "loop": true },
    { "name": "start", "frames_dir": "assets/frames/start", "loop": false },
    { "name": "tool", "frames_dir": "assets/frames/tool", "loop": true },
    { "name": "waiting", "frames_dir": "assets/frames/waiting", "loop": true },
    { "name": "review", "frames_dir": "assets/frames/review", "loop": true },
    { "name": "done", "frames_dir": "assets/frames/done", "loop": false },
    { "name": "failed", "frames_dir": "assets/frames/failed", "loop": true }
  ],
  "created_at": "2026-07-07T00:00:00Z"
}
```

### 5.2 状态定义

V1 固定生成 7 个状态：

| 状态 | 对应事件 | 说明 |
|---|---|---|
| idle | 无 Agent 事件 | 默认状态 |
| start | 开始处理 | 短动作 |
| tool | 执行工具 | 循环动作 |
| waiting | 等待确认 | 循环动作 |
| review | 待查看 | 循环动作 |
| done | 完成 | 短动作 |
| failed | 失败 | 循环动作 |

行为页中的事件开关只控制这 6 类 Agent 事件：

```text
开始处理
执行工具
等待确认
待查看
完成
失败
```

---

## 6. 宠物 Studio AI 生成流程

### 6.1 初始表单

用户只在新建开始时填写一次表单：

| 字段 | 说明 |
|---|---|
| 宠物描述 | 自然语言描述角色、气质、动作偏好 |
| 风格预设 | 写实 / 半写实 / 现代 / 像素 / 动漫 / 不指定 |
| 图像画质 | 标清 / 高清 / 超清 / 原画 |
| 参考图 | 可上传多张 |

点击「开始生成」后，App 创建 AI 会话。

### 6.2 AI 会话

后续流程全部在 Studio 的 AI 会话窗口中完成：

```text
表单提交
  ↓
PetCore 创建 generation job
  ↓
PetCore 启动 Codex App Server 会话
  ↓
Codex 加载内置 Pet Studio Skill
  ↓
Skill 读取表单与参考图
  ↓
AI 在 Studio 会话中推进制作
  ↓
生成 brief、动作方案、图像帧
  ↓
PetCore 校验并打包 .petpack
  ↓
宠物自动进入宠物库
```

不再设计独立的“概念确认”步骤。用户已在初始表单中指定风格；若信息不足，AI 在会话中提问，用户在会话里回答。

### 6.3 Codex App Server 用途

Codex App Server 用于在 App 内嵌入 Codex 会话能力，包括认证、会话历史、approval 和 streamed agent events。其 V1 边界是逐行 JSON 的 stdio request/notification 协议，不假定标准 JSON-RPC `jsonrpc` header，也不宣称未实现的 Unix socket/WebSocket transport；进程由 PetCore 启动和管理。

### 6.4 Pet Studio Skill

内置 Skill 名称固定为：

```text
agent-pet-studio
```

职责：

1. 读取表单与参考图。
2. 按风格预设生成宠物 brief。
3. 为 7 个状态生成动作设计。
4. 调用 Codex 可用的图像生成能力输出帧素材。
5. 调用 `petcore-cli petpack validate` 校验素材。
6. 调用 `petcore-cli petpack build` 打包。
7. 把生成进度写入会话与 PetCore。

---

## 7. 渲染与缓存策略

### 7.1 渲染路径

```text
.petpack
  ↓
PetCore 解包索引
  ↓
macOS App 请求当前宠物 manifest
  ↓
Renderer 按状态加载帧
  ↓
ImageIO 解码 PNG/WebP
  ↓
上传为 Metal texture
  ↓
CVDisplayLink 调度帧切换
```

V1 运行时帧素材固定使用 PNG 序列，原因是：

1. alpha 通道稳定。
2. 生成和校验简单。
3. 不依赖视频透明通道兼容性。
4. 便于逐帧修复。

后续可在不改变 `.petpack` 逻辑结构的前提下，把 runtime cache 编译为更高效的纹理格式。

### 7.2 缓存规则

| 画质 | 缓存策略 |
|---|---|
| 标清 | 当前状态完整预解码 |
| 高清 | 当前状态完整预解码 |
| 超清 | 当前状态完整预解码，下一状态预热一半 |
| 原画 | 环形缓存，只缓存当前播放窗口附近帧 |

全局只允许一个 active pet。宠物库预览使用低分辨率 preview，不加载完整帧。

### 7.3 帧率调度

Renderer 不依赖 SwiftUI 动画。它按时间轴计算当前帧：

```text
frame_index = floor(elapsed_seconds × target_fps) % frame_count
```

当系统压力升高时，不改变动画总时长，只跳过部分帧，避免动作变慢。

---

## 8. Agent 连接设计

### 8.1 统一事件模型

事件管线固定分成三个不可混用的边界：

| 边界 | Schema | 规则 |
|---|---|---|
| Agent 原始 Hook 输入 | `schemas/agent-hook-input.schema.json` | 只存在于 source-specific adapter 进程内，可包含上游扩展字段，不得直接进入 PetCore 或落库 |
| 严格 ingest | `schemas/agent-event-ingest.schema.json` | 只接受固定顶层字段与小型 envelope；未知顶层/嵌套字段 fail closed；`title`、`detail`、`payload_json` 仅作旧客户端类型兼容，仍会重新归一化 |
| 归一化/持久化/对外展示 | `schemas/agent-event.schema.json` | 完整 closed-world record；显示文案、生命周期、工具类别和结果均使用有限词表 |

所有 Agent 事件最终统一转换为：

```json
{
  "id": "evt_01jz...",
  "source": "codex",
  "project_path": null,
  "session_id": "session_xxx",
  "event_type": "tool",
  "title": "执行工具",
  "detail": null,
  "payload_json": {
    "schema_version": "apc.agent-event.v1",
    "external_event_id": "evt_01jz...",
    "source_event": "PreToolUse",
    "tool_name": "shell",
    "outcome": "started",
    "diagnostic": false
  },
  "created_at": "2026-07-07T00:00:00Z"
}
```

`event_type` 固定为：

```text
start
工具执行 tool
waiting
review
done
failed
```

外部 `title`/`detail` 不作为展示文案或数据库内容；`title` 始终由 `event_type` 生成，`detail` 在 V1 归一化记录中为 `null`。`source_event` 只保留已知官方 lifecycle 名称，未知值变为 `unclassified`；工具名只归为 `shell`、`filesystem`、`editor`、`search`、`network`、`agent`、`other`；结果只保留 Schema 中的有限枚举，未知值变为 `unknown`。这使 prompt、命令、参数、输出、路径别名和任意上游字符串不能借显示字段或 metadata alias 回流到 event/recent-visible record。

### 8.2 事件到宠物状态映射

| AgentEvent | 宠物状态 |
|---|---|
| start | start |
| tool | tool |
| waiting | waiting |
| review | review |
| done | done |
| failed | failed |

若行为页关闭某个事件类型，该事件只入库，不触发宠物动作。

PetCore 先按 `source + normalized session` 使用事件时间与持久化 sequence 选出各会话最新事件，再在未过期候选中按 `failed > waiting > review > tool > start > done`、事件时间、sequence 仲裁唯一 `active_agent_state`。`start/tool/waiting/review` lease 为 30 秒，`done/failed` 为 5 秒；终态过期后不会让同会话的旧工作态“复活”。macOS 只消费该 canonical state，不再自行按本地数组时间/优先级重算。

### 8.3 Codex 接入

Codex 接入由本 App 安装 `agent-pet-companion` Codex plugin：

```text
agent-pet-companion/
  .codex-plugin/plugin.json
  hooks/hooks.json
  skills/agent-pet-studio/SKILL.md
```

运行时状态感知使用 plugin-bundled hooks。Codex 官方 hooks 文档说明：插件启用后，Codex 可以从插件根目录加载 lifecycle hooks；默认会查找 `hooks/hooks.json`，也可在 `.codex-plugin/plugin.json` 指定 hooks 路径。插件 hooks 仍需用户 review/trust 后才会运行。

V1 仅注册当前官方 hook 名称。`PostToolUse` 只证明工具活动完成，不等同于用户 review；Codex hooks 没有独立失败事件，因此 hook 能力不宣称 `review`/`failed`，这些状态只能由受支持的 App Server/event stream 补足。

宠物生成使用 Codex App Server。Codex App Server 是 Codex rich clients 使用的深度集成接口，适合认证、会话历史、approval 和 streamed agent events。

### 8.4 Claude Code 接入

Claude Code 接入使用 hooks。Claude Code hooks 是在生命周期事件中自动执行的 shell command、HTTP endpoint 或 LLM prompt；V1 区分代表 API turn 失败的 `StopFailure` 与代表工具失败的 `PostToolUseFailure`。command hook 使用 quiet、async、5 秒上限配置。

V1 安装方式：

```text
${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json 写入 Agent Pet Companion hooks
hook command 调用 petcore-cli agent hook；原始 prompt/args/output 仅在进程内提炼，不写入事件 payload
```

### 8.5 Pi Coding Agent 接入

Pi V1 只使用 Extension 观察现有会话。完成状态来自 `agent_settled`，工具失败来自 `tool_execution_end.isError`；`session_shutdown` 和 `agent_end` 都不被误判为完成。等待确认必须由真实 `tool_call` + `ctx.ui.confirm()`/RPC UI 子协议桥表达，V1 尚未提供该桥时明确报告 unsupported。

V1 安装方式：

```text
~/.pi/agent/extensions/agent-pet-companion.ts
```

Extension 监听 Pi lifecycle events，并把事件发送到 PetCore 本地事件接口。

Pi 的 strict LF JSONL RPC client 尚未实现，V1 不把 `pi --help` 中出现 RPC 文案当作已实现或健康探测。

### 8.6 OpenCode 接入

OpenCode 接入使用 Plugin。OpenCode 官方 plugin 能 hook into various events 并扩展行为；OpenCode Server 可以通过 `opencode serve` 暴露 HTTP API，SDK 可基于该 server 进行程序化控制。

V1 安装方式：

```text
~/.config/opencode/plugins/agent-pet-companion.js
```

Plugin 固定兼容 OpenCode v1.17.18：通用事件读取 `{type, properties}`，direct tool before 读取 `input.{tool,sessionID,callID}` 与 `output.args`，after 不假定存在 `output.error`。`permission.asked/updated/replied` 采用显式兼容映射，replied 会清除 waiting。Server 健康只在显式 opt-in 后，由有界进程实际取得 `/global/health` 的有效 JSON 才标记为 runtime verified。

---

## 9. PetCore 本地服务

### 9.1 进程形态

```text
petcore        # 常驻 daemon
petcore-cli    # hook/extension/plugin 调用入口
```

macOS App 启动时注册用户级 LaunchAgent：

```text
~/Library/LaunchAgents/dev.agentpet.petcore.plist
```

### 9.2 本地通信

App 与 PetCore 使用 Unix Domain Socket：

```text
~/Library/Application Support/AgentPetCompanion/run/petcore.sock
```

Agent hooks、plugins、extensions 优先调用 `petcore-cli agent hook`，由版本化 adapter 在内存中把原始 Hook 输入提炼为严格 ingest envelope；原始 prompt、args、command、output、transcript、environment 和未知扩展字段不会跨过 adapter 边界。诊断/测试可使用显式 `agent ingest`，但同样按严格 Schema 对未知字段 fail closed；对不方便调用 CLI 的 JS 插件，PetCore 同时提供 loopback HTTP endpoint：

```text
http://127.0.0.1:<dynamic-port>/agent-events
```

HTTP endpoint 使用启动时生成的 capability token：

```text
~/Library/Application Support/AgentPetCompanion/run/update-token
权限: 0600
```

---

## 10. 数据存储

SQLite 路径：

```text
~/Library/Application Support/AgentPetCompanion/agent-pet.sqlite
```

核心表：

```sql
CREATE TABLE pets (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  style TEXT NOT NULL,
  quality TEXT NOT NULL,
  render_width INTEGER NOT NULL,
  render_height INTEGER NOT NULL,
  petpack_path TEXT NOT NULL,
  cover_path TEXT NOT NULL,
  origin TEXT NOT NULL,
  generator TEXT,
  provenance TEXT,
  active INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);

CREATE TABLE generation_jobs (
  id TEXT PRIMARY KEY,
  status TEXT NOT NULL,
  form_json TEXT NOT NULL,
  session_id TEXT,
  job_dir TEXT NOT NULL,
  result_pet_id TEXT,
  retry_of_job_id TEXT,
  owner_instance_id TEXT,
  heartbeat_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE generation_messages (
  id TEXT PRIMARY KEY,
  job_id TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  role TEXT NOT NULL,
  kind TEXT,
  content TEXT NOT NULL,
  progress REAL NOT NULL,
  created_at TEXT NOT NULL,
  diagnostic_json TEXT,
  UNIQUE(job_id, sequence)
);

CREATE TABLE agent_events (
  row_id INTEGER PRIMARY KEY AUTOINCREMENT,
  external_event_id TEXT NOT NULL,
  source TEXT NOT NULL,
  project_path TEXT,
  session_id TEXT,
  session_key TEXT NOT NULL,
  event_type TEXT NOT NULL,
  title TEXT,
  detail TEXT,
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE(source, session_key, external_event_id)
);

CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value_json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  revision INTEGER NOT NULL
);

CREATE TABLE state_revision (
  singleton INTEGER PRIMARY KEY,
  revision INTEGER NOT NULL
);
```

`generation_messages` 是生成会话消息的唯一真相源；JSONL 只是兼容迁移和有界诊断镜像。事件原始记录按 10,000 行/30 天保留，按日来源/类型计数可在原始行淘汰后继续保留。旧事件隐私迁移先写持久 phase marker，再 checkpoint + `VACUUM` + truncate WAL；只有清理完成后才推进 SQLite `user_version`，中途崩溃会在下次启动重试。

---

## 11. 启用与行为配置

配置结构：

```json
{
  "enabled": true,
  "status_bubble": true,
  "click_menu": true,
  "mouse_passthrough": true,
  "auto_hide": false,
  "fps_profile": "standard",
  "sources": {
    "codex": true,
    "claude_code": true,
    "pi": true,
    "opencode": true
  },
  "events": {
    "start": true,
    "tool": true,
    "waiting": true,
    "review": true,
    "done": true,
    "failed": true
  }
}
```

行为修改只使用 `behavior.patch { expected_revision, changes }`。`expected_revision` 是 Behavior 自身的 CAS revision，不受 Agent 事件等无关全局写入影响；冲突返回明确错误，客户端刷新后按字段重试。通用 `settings.update` 不能写 product settings。`auto_hide` 只表示“没有 canonical active Agent state 时隐藏状态气泡”，不会隐藏 idle 宠物；宠物可见性始终由 `enabled` 控制。

显示尺寸不进入设置。尺寸保存在 overlay placement：

```json
{
  "x": 0,
  "y": 0,
  "scale": 0.72,
  "display_id": "main"
}
```

---

## 12. Agent 连接检查

Agent 连接页只检查宠物响应所需条件。

| Agent | 检查项 |
|---|---|
| Codex | CLI 是否存在、plugin 是否安装、hooks 是否启用、hooks 是否已信任、App Server 是否可启动、Pet Studio Skill 是否存在 |
| Claude Code | CLI 是否存在、settings hooks 是否写入、hook command 是否可执行、事件回传是否成功 |
| Pi Coding Agent | CLI 是否存在、extension 是否安装/真实加载、事件回传是否成功；RPC 与 waiting bridge 明确标注 unsupported |
| OpenCode | CLI 是否存在、plugin 是否安装/加载、事件回传是否成功；Server 仅在 opt-in `/global/health` 探测后标记 runtime verified |

每个检查项只有三种状态：

```text
正常
需修复
未检测到
```

---

## 13. 安全边界

V1 固定遵守：

1. 不读取 `auth.json`、API Key、OAuth token、cookie。
2. 不上传用户代码、Agent transcript、项目文件。
3. 参考图只用于本地 generation job 工作区与用户授权的 AI 生成会话。
4. 本地 HTTP endpoint 只监听 `127.0.0.1`。
5. 本地 HTTP endpoint 必须携带 capability token。
6. 所有 hook/plugin/extension 安装前在 App 中展示将写入的路径。
7. Agent 连接配置支持一键卸载。

---

## 14. V1 验收标准

### 14.1 宠物 Studio

1. 用户填写初始表单后能创建 AI 会话。
2. Studio 能显示 AI 会话消息、生成进度、错误提示。
3. AI 会话能保存明确标注的确定性本地预览；只有图像能力工具生成完整、可见差异的 7 状态帧并通过 provenance/参考图语义校验后，才标记为已验证 AI source 并生成 `.petpack`。
4. 生成完成后宠物自动进入宠物库。
5. 宠物库能启用、删除、查看基本信息。

### 14.2 渲染

1. 标清、高清、超清、原画四档宠物都能在悬浮层显示。
2. 12 FPS 与 20 FPS 两档都能正确播放。
3. 右下角缩放手柄可调整桌宠尺寸。
4. 关闭悬浮层后动画暂停。
5. 原画档不会预解码全状态帧。

### 14.3 Agent 响应

1. Codex、Claude Code、Pi、OpenCode 四类来源能独立开关。
2. 开始处理、执行工具、等待确认、待查看、完成、失败六类事件能独立开关。
3. 开启事件会触发桌宠动作。
4. 关闭事件不会触发动作，但事件仍入库。

### 14.4 性能

1. 默认高清 + 12 FPS 下，稳定播放至少 30 秒的 CPU 采样平均值不超过 4%。
2. 超清 + 20 FPS 下，相对隐藏悬浮层稳定 RSS 基线的 Renderer RSS 峰值增量不超过 260 MB。
3. 原画 + 20 FPS 下，相对隐藏悬浮层稳定 RSS 基线的 Renderer RSS 峰值增量不超过 420 MB。
4. App 主界面滚动、切换页面不受悬浮层动画影响。
5. 性能验收同时保留隐藏基线、绝对 App RSS、RSS 峰值增量、CPU 平均/峰值、采样数、采样间隔、实测 FPS、驻留解码缓存与 Metal/drawable 实分配遥测；估算缓存不能代替实测门禁。

---

## 15. 参考依据

- OpenAI Codex App Server：用于产品内深度集成 Codex，会话、approval、streamed agent events；V1 使用逐行 JSON stdio request/notification 边界，不要求标准 JSON-RPC `jsonrpc` header。
- OpenAI Codex Hooks：支持 plugin-bundled lifecycle hooks，默认读取 plugin root 下的 `hooks/hooks.json`。
- Claude Code Hooks：支持在 SessionStart、UserPromptSubmit、PreToolUse、PermissionRequest、PostToolUse、Stop 等生命周期点执行 hooks。
- Pi Coding Agent：V1 使用 Extension；RPC mode 的 strict LF JSONL/UI 子协议属于未实现能力，不作健康声明。
- OpenCode：V1 plugin 契约固定在 v1.17.18；headless server 只通过 opt-in `/global/health` 探测验证。
