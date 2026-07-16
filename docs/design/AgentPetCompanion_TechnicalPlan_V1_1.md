# Agent Pet Companion 技术方案 V1.1

> 基于 V5 产品设计：macOS 原生桌宠 App；只做宠物制作、宠物库、启用与行为、Agent 连接；支持 Codex、Claude Code、Pi Coding Agent、OpenCode；不做公共素材库，不兼容导出 Codex 内置宠物包。
>
> 当前实现、验证结果和尚未完成的发布硬化以 [当前项目状态](../PROJECT_STATUS.md) 为准。本文件描述目标架构与验收要求，不把目标条目自动视为已通过。

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
9. 桌宠尺寸不在设置页配置，用户通过悬浮层宠物右侧缩放手柄直接调整；缩放手柄与气泡开关共用右侧控制列。
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
│ macOS UI Host                              │
│ SwiftUI + AppKit（单实例、轻量常驻）       │
│ - 按需控制中心                             │
│ - 菜单栏状态项                             │
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

控制中心（主窗口）使用 `NavigationSplitView`、系统 sidebar list 和 unified compact toolbar。业务内容以统一的 `GlassEffectContainer` 组织相邻面板；macOS 26 的所有自定义 surface 使用 `Glass.clear`，可点击 surface 使用 interactive clear glass，macOS 14–15 统一退回 `ultraThinMaterial`。这些 macOS 26 SDK 符号同时受 `compiler(>=6.2)` 编译门禁保护：Xcode 26 构建保留完整 Liquid Glass，Xcode 16 构建完全排除新符号并使用材质回退。主操作采用 `.borderedProminent`，次操作采用 `.bordered`，由系统负责选中、禁用、键盘焦点、高对比度和 Reduce Transparency，不再手工绘制按钮阴影与不透明卡片。

### 4.3 桌宠悬浮层

悬浮层使用 `NSPanel`，行为固定如下：

| 功能 | 实现 |
|---|---|
| 置顶显示 | floating window level |
| 不抢焦点 | non-activating panel |
| 拖动 | AppKit 处理拖拽 |
| 缩放 | 宠物右侧 resize handle，与气泡开关纵向排列在同一控制列 |
| 透明背景 | premultiplied alpha texture |
| 消息气泡材质 | macOS 26 使用无 tint、无附加 opacity 的 `NSGlassEffectView.Style.clear`，完整 SwiftUI 气泡作为其 `contentView`；macOS 14–15 原生 `ultraThinMaterial` 回退 |
| 桌宠控制材质 | 缩放手柄、缩放值和气泡开关共享 clear glass；不显示拖动标签、不绘制脚下底座，宠物帧位于无遮挡内容层；视觉控件紧凑但命中区独立保留 |
| 右击菜单 | 原生 `NSMenu` + SF Symbols，不自绘菜单背景 |
| 动画播放 | Metal texture swap |
| 鼠标穿透 | 行为页开关控制 |
| 收起 | 菜单栏或悬浮层按钮 |

宠物本体与消息气泡分别由透明、无边框、non-activating `NSPanel` 承载；气泡开关和缩放手柄进一步各自使用与 36/38 pt 命中区等大的透明控制 panel，避免宠物主体的鼠标穿透状态让首个点击或拖拽落到下层 App。所有 panel 都属于同一个 macOS App 进程；Rust PetCore LaunchAgent 只负责状态、事件与数据，不绘制桌宠。气泡 panel 保持 `isOpaque=false` 和透明背景，SwiftUI 内容不再铺不透明白底：macOS 26 使用公开 API 中最高透明度的 `NSGlassEffectView.Style.clear`，保持 `tintColor=nil`、无填充、无边框、无事后 opacity，并把完整 SwiftUI 气泡通过 `NSHostingView` 放入系统保证层级正确的 `contentView`，避免玻璃光学层覆盖文字。透明 Panel 中不再包裹会提升后代玻璃层级的 `GlassEffectContainer`。旧系统使用系统超薄材质；Reduce Transparency 与 Increase Contrast 使用与当前外观匹配的高对比回退，保证语义前景可读。

宠物输入由最小 `NSViewRepresentable` 桥接：左键按下/拖动/抬起只维护移动生命周期，未发生拖动的左键单击不执行额外动作；只有 `rightMouseDown` 在开关允许时构造原生 `NSMenu`。菜单不再同时挂在 SwiftUI 根视图，避免左右键语义重复或一次右击出现两个入口。

悬浮层不使用 SwiftUI 高频重绘。SwiftUI 只负责控制面板，宠物动画由 Metal 层单独绘制。

---

## 5. 宠物资源格式 `.petpack`

`.petpack` 是 zip 包，内部结构固定：

完整规范、producer profile、资源预算、路径安全、修订语义和未来兼容策略见 [Agent Pet Companion `.petpack` Whitepaper V1](../specifications/AgentPetCompanion_Petpack_Whitepaper_V1.md)。本技术方案只摘要运行链路；实现与白皮书冲突时必须记录差距，不能把未实现门禁写成已完成。

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

### 5.3 导入、导出与不可变修订

所有生产者共用 `petcore-cli`/PetCore 的同一套 V1 校验器。导入先校验，再写入 App 自有存储的隐藏 staging revision；archive、运行时帧和数据库指针全部成功后才原子切换 `active.json`。相同 `manifest.id` 表示同一宠物的新 revision，不创建第二条逻辑宠物；导入不会让原本非活跃的宠物抢占当前桌宠。

`petpack.export { id, path }` 只导出当前不可变 archive：目标必须位于 App 自有宠物存储之外，先在目标同目录 staging、前后两次校验，再原子替换。导出不重新编码 archive，因此导出文件可重新导入并保持原字节内容。`apc.runtime-manifest.v1` 同时公开 `petpack_read_versions` 与 `petpack_write_version`；当前均为 `apc.petpack.v1`，未知版本 fail closed。

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

正式 App 的生成环境固定启用 `APC_REQUIRE_SKILL_FULL_SOURCE=1` 与 `APC_REQUIRE_EXTERNAL_SKILL_SOURCE=1`。turn 最长允许 20 分钟，辅助重试最长 10 分钟，取消仍以 100 ms 周期响应；图像生成开始、图像完成后的透明化/分帧/构建都会写入 Studio 会话进度。超时、缺少完整 source 或 `validation.ok != true` 均诚实失败，不导入半成品。

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

严格外部 source 至少包含七个固定状态、每状态两张透明帧、预览、manifest、brief、`source/source.json`、Skill 会话记录与校验结果。`generator=codex-app-server-skill`、`provenance=skill-full-source` 且不存在 preview/materializer/repair 标记时才可记为已验证 Skill 来源；确定性 helper、CLI materializer 和 PetCore materializer 都不能满足该门禁。

### 6.5 任意库内宠物修改

`generation.edit { pet_id, instruction }` 为 App 内 Codex 修改入口。PetCore 校验并安全展开当前 revision 到隔离 job workspace，记录基线 archive SHA-256、manifest 与状态哈希；包内 prompt/metadata 一律按不可信数据处理。结果必须保持同一 ID、`created_at`、quality、render size、FPS 与七状态目录/loop 结构，校验后以新 revision 提交。提交前再次核对当前 archive SHA-256，避免 AI 工作期间用户导入的新版本被旧结果覆盖。修改原非活跃宠物时保持非活跃，不擅自切换桌宠。

### 6.6 外部 Agent 的可移植技能

`skills/agent-pet-maker` 是 provider-neutral 的 Agent Skills 包，可交给具备真实图像理解与生成/编辑能力的 Claude Code、Pi、Hermes、OpenCode 等宿主。helper 只负责安全 workspace、基线哈希、结构约束、隐私元数据、PetCore 校验和构建，不生成或伪造视觉资产。修改模式保持 ID，并要求未声明修改的状态逐文件 byte-identical；缺少真实图像能力时输出 `capability_missing` sidecar。

默认流程只产出 `.petpack`。用户明确要求导入/启用时，技能才通过当前 App runtime 的在线 `petcore-cli` 调用 daemon 导入，核对返回 ID，再选择性 `pet activate`；禁止静默使用 `--offline`。激活只表示 PetCore 的唯一 active pet 已切换，是否正在屏幕渲染仍取决于 UI Host 与全局 `behavior.enabled`，技能不得为追求“显示成功”而擅自启动 App 或修改该开关。

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
    "diagnostic": false,
    "turn_id": "turn_xxx",
    "session_active": true,
    "message_role": null,
    "message_content": null,
    "activity_kind": "command",
    "activity_content": null,
    "interaction_kind": null,
    "project_label": "agent-pet-companion"
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

外部 `title`/`detail` 不作为展示文案或数据库内容；`title` 始终由 `event_type` 生成，`detail` 在 V1 归一化记录中为 `null`。`source_event` 只保留已知官方 lifecycle 名称及 App 自有的 `app_server_activity` 内部同步标识，未知值变为 `unclassified`；工具名只归为 `shell`、`filesystem`、`editor`、`search`、`network`、`agent`、`other`；结果只保留 Schema 中的有限枚举，未知值变为 `unknown`。

会话展示文本只能通过显式 allowlist 字段进入：`UserPromptSubmit.prompt -> message_role=user`、最终 Agent 文本 `-> message_role=assistant`，最大 4096 UTF-8 bytes，并清理控制字符。运行中的公开活动另使用 `activity_kind` 与 `activity_content`：kind 仅允许 `thinking/plan/command/file/file_change/tool/subagent/search/network/image/compaction`，content 最大 1024 UTF-8 bytes；Codex 只允许官方 `reasoning.summary`/`plan.text` 进入 content，绝不读取 reasoning content、命令正文、工具参数或工具输出。其他 Agent 没有公开摘要文本时只发送类别，由 App 本地化为「正在搜索」「正在修改文件」等提示。`PermissionRequest` 只写入有限枚举 `interaction_kind=approval_required`，不复制 tool input。完整 cwd 只提炼为不超过 128 bytes 的末级 `project_label`。命令、工具参数、工具输出、transcript、认证信息、任意 metadata alias 和任意环境变量仍不得跨过 adapter 边界；唯一例外是用于本地导航的闭集字段 `session_surface`、`terminal_app`、`session_open` 与严格校验后的 `session_open_url`。当前 URL 只接受 `warp://session/<32 hex>` 或 `warppreview://session/<32 hex>`，绝不接受通用 URL 或完整环境快照。

对于事件已明确给出 UUID `session_id` 的 Codex 会话，PetCore 优先使用官方 App Server `thread/read` 做单会话只读展示补全。为覆盖 ChatGPT 桌面 App 中 hooks 尚未触发或尚未获信任、但官方 Pets 已能看到的交互任务，守护进程另启用有界近期活动同步：每 1 秒至多调用一次 `thread/list`，固定 `useStateDbOnly=true`、仅查询非归档交互来源、按 `updated_at` 倒序取最多 24 个候选，再只对行为设置的收起时限内最多 8 个候选调用 `thread/read`。响应只提取用户可见 `name`/`preview`、最新 turn 状态、最新 `userMessage`/`agentMessage` 文本，以及发生在最后一条用户或 Agent 消息之后的最新公开活动：`reasoning.summary`、`plan.text` 或结构化 item 类别。标题限制 160 UTF-8 bytes、消息限制 4096 UTF-8 bytes、活动摘要限制 1024 UTF-8 bytes并清理控制字符。`reasoning.content`、`path`、cwd、命令正文、工具参数、工具输出及完整 turns/transcript 不进入 RPC、事件库或日志；较早的活动项不能覆盖较新的正式 Agent 消息。同步器仅在进程内检查 cwd：`generation-jobs/job_*` 下由 Pet Studio 自己创建的 Codex task 在 `thread/list` 与 `thread/read` 两层排除，cwd 本身不持久化，内部生成提示与结果 JSON 不进入 Agent 气泡。

App Server 持久化 turn 明确是有损视图，命令执行等交互可能完全不进入 `thread/read`。因此解析器只把最后一条公开活动当作候选：`commandExecution.commandActions` 全为 `read/listFiles` 时映射文件读取、全为 `search` 时映射搜索，含 `unknown` 或混合动作时映射 Shell 命令；`fileChange`、命令、MCP、图像生成和协作调用只有 `status=inProgress` 才能作为当前活动，`completed/failed/declined` 只表示历史，不能继续显示「正在修改文件」或覆盖后续信息。同一 turn 的 App Server 状态使用稳定事件 ID 原位更新，避免思考/工具切换产生多条旧记录竞争。若 `updatedAt` 已推进但安全显示 revision 未变化，说明实时 item 被持久化层省略：同步器终止旧摘要并显示无参数的「正在思考」或「正在调用工具」；若连 `updatedAt` 也没有新信号，则保留最近公开信息，不凭空伪造具体工具类别。

App Server 的运行状态是进程局部状态：另一个 App Server 查询 ChatGPT 桌面任务时可能返回 `notLoaded`，正在运行的未完成 turn 也可能在重载视图中表现为 `interrupted`。因此同步器以 `activeFlags`/明确 `failed`/`completed` 为强信号；对近期 `inProgress` 或 `interrupted` 仅生成 `session_active=false` 的有限活动租约，租约长度等于「会话消息收起时间」（默认 15 分钟），每次真实 `updatedAt` 变化都会续期，过期自然收起，不制造永久运行状态。`waitingOnApproval`/`waitingOnUserInput` 映射为 `Needs input`，`completed` 映射为 `Ready`，`failed`/`systemError` 映射为 `Blocked`。同步结果按安全事件信封持久化为有界标题、最新用户/Agent 文本和导航 surface，以唤醒正在长轮询的悬浮层；原始 App Server 响应不落盘。

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

PetCore 先通过 SQLite window query 按 `source + normalized session` 选出每个会话的最新事件。宠物动画继续按 ChatGPT 官方 Pets 语义 `Needs input > Blocked > Ready > Running`、事件时间、sequence 仲裁唯一 `active_agent_state`；状态气泡另由有界 `active_agent_sessions`（最多 8 条）驱动。映射为：`waiting -> Needs input`、`failed -> Blocked`、`review/done -> Ready`、`start/tool -> Running`。

支持生命周期的 adapter 必须写入 `session_active`。值为 `true` 时唯一动画状态不使用活动 lease；`Stop`、失败或明确 idle 写入 `false` 并关闭动画状态。缺少该字段的旧事件继续采用兼容 lease：`start/tool/waiting/review` 30 秒，`done/failed` 5 秒。终态过期后不会让同会话旧工作态“复活”。

气泡展示窗口以同一 `source + session` 最近一次用户激活时间与最近可观测活动时间中的较新者为起点：普通 Running/Ready 会话超过 `session_message_timeout_minutes` 后从 `active_agent_sessions` 收起，新 `start` 或 App Server `updatedAt` 活动到达时重新出现；仍为 active 的 Needs input 与 Blocked 不受普通超时影响。`session_active=false` 的 Waiting 已明确关闭，不得作为待处理历史长期占位；缺少生命周期字段的 Waiting 只使用 30 秒兼容 lease。最近 Agent 回复和最近用户消息按 source/session 与 role 单独从持久化事件回查，不受快照扫描窗口影响。macOS 只负责按 source 分组、绘制和命中，不自行重算超时或状态优先级。

每个会话行的内容按状态选择，避免“活动时间刷新但正文仍停留在上一条回复”：Running/Tool 优先 `session_activity.content`，其次按 `session_activity.kind` 显示本地化活动提示，再退回最近 Agent 回复或「思考中」；Ready/Done 优先最终 Agent 回复；Needs input 与 Blocked 优先当前交互/错误提示，不显示旧 Agent 回复冒充当前状态。活动项只更新当前会话，不改变同 Agent 其他会话的内容；会话排序仍按各自最近可观测活动时间处理。

会话打开与 Agent 工作状态分离：`session_active` 表示当前 turn 是否运行，`session_open` 表示原运行页面是否仍可尝试打开。按钮统一为「打开」，不提供 resume 或代答。路由顺序为：经过闭集校验的精确会话 URL > 已知原终端 App > 已确认 ChatGPT 桌面 surface 的 `codex://threads/<id>` > 对应 App 激活。Hook 事件中，Codex CLI 一旦带有终端证据就不得走 ChatGPT 任务深链；App Server 近期同步按官方 `source` 分类路由：`cli -> cli_terminal`，`vscode/appServer -> chatgpt_app`，其余保持 `unknown` 并只激活目标 App，不盲猜 thread 页面。收到 Pi `session_shutdown`、Claude `SessionEnd` 或 OpenCode `session.deleted` 后写入 `session_open=false`，气泡可保留消息但不再提供跳转。异常退出或退出事件延迟不做重型心跳，允许一次过期跳转由目标 App 自行报错。

Warp CLI 会话由 Warp 注入的 `WARP_FOCUS_URL` 精确定位。PetCore CLI 只读取该单一变量并按 `warp/warppreview://session/<32 hex>` 校验后持久化；macOS 通过 `NSWorkspace` 打开时 Warp 会聚焦包含对应 session UUID 的 window/tab/pane。URL 缺失、失效或 pane 已关闭时退回激活 Warp App。该路径满足产品“完整支持”定义，不在连接页显示有限支持；`WARP_TERMINAL_SESSION_UUID` 和其他环境内容不采集。

### 8.3 Codex 接入

Codex 接入由本 App 安装 `agent-pet-companion` Codex plugin：

```text
agent-pet-companion/
  .codex-plugin/plugin.json
  hooks/hooks.json
  skills/agent-pet-studio/SKILL.md
```

运行时状态感知使用 plugin-bundled hooks。Codex 官方 hooks 文档说明：插件启用后，Codex 可以从插件根目录加载 lifecycle hooks；默认会查找 `hooks/hooks.json`，也可在 `.codex-plugin/plugin.json` 指定 hooks 路径。插件 hooks 仍需用户 review/trust 后才会运行。

V1 仅注册当前官方 hook 名称。`PreToolUse`、`Pre/PostCompact`、`SubagentStart/Stop` 等事件产生受限活动类别，`PostToolUse` 只证明工具活动完成，不等同于用户 review；Codex hooks 没有独立失败事件，因此 hook 能力不宣称 `review`/`failed`，这些状态只能由受支持的 App Server/event stream 补足。ChatGPT 桌面任务通过 App Server 额外读取公开 `reasoning.summary`/`plan.text`；精确的实时 Shell/读取/搜索切换必须来自用户已 review/trust 的 `PreToolUse` hook，因为跨进程持久化视图会省略命令执行。连接页必须把 Hook Trust 单独显示为待确认，并说明未信任时只能使用有损近期任务快照。这些公开摘要都不是隐藏思维链。

宠物生成使用 Codex App Server。Codex App Server 是 Codex rich clients 使用的深度集成接口，适合认证、会话历史、approval 和 streamed agent events。

2026-07 的 ChatGPT/Codex 桌面合并后，Codex 作为 ChatGPT 桌面 App 的模式继续存在。PetCore 的自动 App Server 发现顺序固定为：显式 `CODEX_APP_SERVER_CMD`、`/Applications/ChatGPT.app/Contents/Resources/codex`、旧 `/Applications/Codex.app` 内嵌 CLI、PATH `codex`。Agent 连接检查与 plugin 安装同样优先使用新 ChatGPT 内嵌 CLI。合并不代表第三方进程获得 Chat/Work/Codex 的内部实时任务流：用户已 review/trust 的官方 hooks 仍是外部任务的精确生命周期来源；App Server 近期活动同步只作为只读、有界兜底，用结构化任务元数据和最新可见消息恢复气泡，不把跨进程 `notLoaded/interrupted` 宣称为官方精确状态。PetCore 自己启动的 Pet Studio 会话继续使用 App Server streamed events。

### 8.4 Claude Code 接入

Claude Code 接入使用 hooks。Claude Code hooks 是在生命周期事件中自动执行的 shell command、HTTP endpoint 或 LLM prompt；V1 区分代表 API turn 失败的 `StopFailure` 与代表可恢复单次工具失败的 `PostToolUseFailure`，后者继续显示 Running，不能误报 Blocked。`PostToolBatch`、`PermissionDenied`、`Elicitation/ElicitationResult`、`Pre/PostCompact`、`SubagentStart/Stop` 与 `TaskCreated/Completed` 补齐工具批次、用户交互恢复、压缩和子 Agent 活动；没有公开摘要正文时只同步活动类别。command hook 使用 quiet、async、5 秒上限配置。

V1 安装方式：

```text
${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json 写入 Agent Pet Companion hooks
hook command 调用 petcore-cli agent hook；原始 prompt/args/output 仅在进程内提炼，不写入事件 payload
```

### 8.5 Pi Coding Agent 接入

Pi V1 使用 Extension 观察现有会话。用户消息来自 `before_agent_start.prompt`；Agent 回复优先从 Pi 0.80.6 的正式 `message_end.message` 事件提取 assistant 文本，同时从 `agent_end.messages` 复核并在 `agent_settled` 终态重发缓存文本，避免连续生命周期事件投递时正文丢失。Extension 串行等待本地事件 CLI 完成，并为每轮生成 `turn_id`，防止内容相同的不同轮次被错误去重。`agent_end` 后仍可能重试、压缩或继续队列，因此保持 Running，只有 `agent_settled` 才产生稳定 Ready/Blocked。`tool_execution_end.isError` 只表示单次工具调用失败，Agent 仍可能恢复并正常回复，因此保持 Tool/Running；只有最终 assistant 的 `stopReason=error` 且运行进入 `agent_settled`，才映射为 Failed/Blocked。`session_before_compact/session_compact` 显示压缩/继续思考活动。`session_shutdown` 只表示原页面关闭并撤销跳转，不伪造为 Agent 成功。Pi 未产生独立交互请求事件时，Agent 的提问仍按最终 assistant 消息显示为 Ready，点击「打开」返回原会话。

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

Plugin 固定兼容 OpenCode v1.17.18：通用事件读取 `{type, properties}`，direct tool before 读取 `input.{tool,sessionID,callID}` 与 `output.args`，after 不假定存在 `output.error`。`permission.asked/updated/replied` 与 `question.asked/replied/rejected` 采用显式兼容映射，回复事件会清除 waiting。assistant 文本完成不代表整个 session 已 idle，因此先保留 Running 并显示该文本，只有 `session.idle` 或 `session.status=idle` 才进入 Ready；工具开始/结束和 busy/retry 状态同步受限活动类别。Server 健康只在显式 opt-in 后，由有界进程实际取得 `/global/health` 的有效 JSON 才标记为 runtime verified。

---

## 9. PetCore 本地服务

### 9.1 进程形态

```text
AgentPetCompanion.app  # 单实例 UI Host：控制中心、菜单栏状态项、桌宠与消息气泡
petcore                # 独立常驻 LaunchAgent：数据、事件、状态与 RPC
petcore-cli            # hook/extension/plugin 调用入口
```

macOS App 启动时注册用户级 LaunchAgent：

```text
~/Library/LaunchAgents/dev.agentpet.petcore.plist
```

App UI（控制中心、菜单栏入口和桌宠 `NSPanel`）始终属于同一个 App 进程。控制中心使用单场景 `Window` 而不是可重复实例化的 `WindowGroup`；Dock 图标、状态栏、Finder 或命令行的重复打开请求只会取消最小化并置前这一个控制中心，不创建新窗口。

App 进程是轻量 UI Host，控制中心只是其中一个按需显示的单例窗口。关闭窗口或按 `⌘W` 只关闭控制中心，不终止 App；菜单栏状态项、桌宠、消息气泡和 PetCore 订阅继续运行。用户可通过菜单栏状态项、桌宠右击菜单、Dock、Finder 或再次打开 App 恢复并置前同一个控制中心窗口。控制中心关闭后释放其可重建的视图与临时渲染资源，权威数据仍由 PetCore 保存。

`⌘Q`、Dock 的「退出」以及状态栏菜单中的「退出 Agent Pet」遵循标准 macOS Quit 语义，终止整个 UI Host，因此控制中心、菜单栏状态项、桌宠与气泡一并退出；独立 LaunchAgent PetCore 不随之退出。再次启动 App 时重新连接匹配版本的 PetCore，并从快照恢复当前宠物、配置和仍在展示时限内的会话。「隐藏桌宠」只隐藏桌宠与气泡 panel 并暂停动画，不退出 App 或 PetCore；状态栏菜单始终作为恢复入口。

App 在 `APC_HOME/run/app-instance.lock` 持有非阻塞文件锁；包括 `open -n` 在内的第二实例只发送激活通知并退出。通知同时携带被点击 App 副本的路径和 `APCBuildID`：同版本只激活旧实例；不同版本在验证 App 路径、磁盘构建 ID 和 bundle identifier 后，由旧实例退出并在锁释放后打开被请求的新 App，不允许两个主 UI 进程并行。主实例被重新打开或重新激活时，也会比较进程启动时的 `APCBuildID` 与当前磁盘 App 的 `APCBuildID`；若原路径的安装包已被替换，执行同样的强制交接，避免旧桌宠 UI 长期滞留。

每次 `.app` 打包都会生成一个同时写入 Info.plist 和内嵌 PetCore 二进制的 `APCBuildID`。`petcore.health` 同时返回 RPC 协议版本与 `build_id`；App 只有在两者都匹配时才沿用常驻服务。构建不一致时，App 使用健康响应中的 `instance_id` 请求受约束的 `petcore.shutdown`，等待旧 Unix socket 释放后再由 LaunchAgent（或受控直启回退）接管；LaunchAgent 配置也携带期望构建 ID，并以 `kickstart -k`/bootout + bootstrap 强制换用新二进制。PetCore 启动时会拒绝与 App 期望构建 ID 不一致的二进制。

`APCBuildID` 与 RPC 精确握手是进程兼容的第一道门禁；当前实现另携带 `apc.runtime-manifest.v1`，绑定 App semantic version/build、`APCBuildID`、PetCore RPC/build、PetCore CLI、数据库 schema、Agent event schema、`.petpack` 可读版本列表/当前写入版本和 Codex/Claude/Pi/OpenCode connector contract version。manifest 作为 App 签名范围内的资源随 bundle 分发。App 在停止旧 Core 前检查 manifest、迁移方向、数据库只读兼容性和最低/最高 schema 范围；旧 App 尝试打开未来数据库或不兼容 runtime 时拒绝静默降级。

当前更新交接分两阶段：先将 bundle 中的 PetCore、CLI 与 manifest 原子 stage 到 `APC_HOME/runtime/versions/<build-id>` 并执行候选二进制 `preflight`；随后对旧实例执行带 `instance_id` 的受约束 shutdown，使用候选重建 LaunchAgent（隔离验证使用 direct child），并只在 exact health/build/manifest 通过后写入 `current.json` 与 `last-known-good.json`。候选启动或健康检查失败时，启动前一个 last-known-good runtime 并恢复 current 指针，UI 显示可恢复的启动错误。该实现避免新旧 App/Core 静默混用；正式安装器层面的原子替换与 Developer ID 分发仍属于 P2。

健康提交还会原子更新 `APC_HOME/runtime/current -> versions/<build-id>`。四类连接器统一写入稳定的 `runtime/current/petcore-cli`，App 在交接后执行有界的 `connections refresh-installed`：只刷新已经存在的本项目 Codex source、Claude hook、Pi extension 与 OpenCode plugin 引用，不安装未授权连接器，也不覆盖用户的其他 Claude/Codex 配置。回滚提交会同步切回该稳定入口。

### 9.2 本地通信

App 与 PetCore 使用 Unix Domain Socket：

```text
~/Library/Application Support/AgentPetCompanion/run/petcore.sock
```

Agent hooks、plugins、extensions 优先调用 `petcore-cli agent hook`，由版本化 adapter 在内存中把原始 Hook 输入提炼为严格 ingest envelope；只有受控、截断后的用户 prompt/最终 assistant message 和上述闭集会话导航字段可进入事件记录，args、command、tool output、transcript、任意 environment/URL 和未知扩展字段不会跨过 adapter 边界。诊断/测试可使用显式 `agent ingest`，但同样按严格 Schema 对未知字段 fail closed；对不方便调用 CLI 的 JS 插件，PetCore 同时提供 loopback HTTP endpoint：

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

`generation_messages` 是 Pet Studio 生成会话消息的唯一真相源；JSONL 只是兼容迁移和有界诊断镜像。Agent 状态事件中的会话展示消息属于独立的 bounded event envelope，只用于桌宠状态气泡。事件原始记录按 10,000 行/30 天保留，按日来源/类型计数可在原始行淘汰后继续保留。旧事件隐私迁移先写持久 phase marker，再 checkpoint + `VACUUM` + truncate WAL；只有清理完成后才推进 SQLite `user_version`，中途崩溃会在下次启动重试。

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
  "session_message_timeout_minutes": 15,
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

行为修改只使用 `behavior.patch { expected_revision, changes }`。`expected_revision` 是 Behavior 自身的 CAS revision，不受 Agent 事件等无关全局写入影响；冲突返回明确错误，客户端刷新后按字段重试。通用 `settings.update` 不能写 product settings。`session_message_timeout_minutes` 默认 15，合法范围为 1–1440。`auto_hide` 只表示“没有可展示 Agent 会话时隐藏状态气泡”，不会隐藏 idle 宠物；宠物可见性始终由 `enabled` 控制。

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
| Pi Coding Agent | CLI 是否存在、extension 是否安装/真实加载、事件回传是否成功；会话标题、用户消息、Agent 回复与关闭状态均由结构化 Extension 事件提供 |
| OpenCode | CLI 是否存在、plugin 是否安装/加载、事件回传是否成功；Server 仅在 opt-in `/global/health` 探测后标记 runtime verified |

每个检查项使用六种互斥状态，阻断性状态仅为 `需修复` 与 `未检测到`：

```text
正常
需修复
未检测到
未验证
暂不支持
非必需
```

轻量检查、外部 CLI 覆盖导致的跳过以及 Codex 未公开的 Hook trust 结果必须标为“未验证”；标准 OpenCode 事件观察不依赖 Server，因此未显式探测时标为“非必需”。终端会话定位不使用“有限支持”产品标签：内部可记录 `exact_session` 或 `app_fallback` 诊断模式，但两者都满足「打开对应会话；无法精确定位时打开对应 App」的产品契约。`PetCore 通道自检` 是诊断事件，不进入最近事件、会话气泡或桌宠状态仲裁，也不能作为 Agent Hook 已触发的证据。

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
8. 会话展示消息按 Agent 事件保留策略保存在本地；UI 与文档明确其范围，且不把它扩展为 transcript 采集。

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
3. 宠物右侧缩放手柄可调整桌宠尺寸，并与气泡开关保持同列且命中区互不重叠。
4. 隐藏桌宠悬浮层后动画暂停，但 UI Host 和状态订阅继续运行。
5. 原画档不会预解码全状态帧。

### 14.3 Agent 响应

1. Codex、Claude Code、Pi、OpenCode 四类来源能独立开关。
2. 开始处理、执行工具、等待确认、待查看、完成、失败六类事件能独立开关。
3. 开启事件会触发桌宠动作。
4. 关闭事件不会触发动作，但事件仍入库。
5. 每个 Agent 使用一个独立气泡；同一 Agent 的多个会话在气泡内按会话标题、右对齐状态和 Agent 回复正文分行展示，正文最多两行且布局测量使用同一限制，运行中尚无回复时显示「思考中」。连接器未提供标题时，PetCore 按事件时间和持久化序号读取该会话第一条 user 消息，折叠为空格并截为最多 80 个字符作为稳定标题；后续 user 消息只更新当前消息，不改写降级标题。若官方标题随后出现，始终覆盖该降级标题。
6. macOS 26 气泡使用最高透明度 `Glass.clear.interactive()` 且文字、图标、状态和操作必须位于玻璃内容层；明亮、暗色和混合背景上前景均可辨认，正常模式仍能识别气泡后的桌面内容。Reduce Transparency 与 Increase Contrast 下使用更强的系统/深色回退，不能出现白字白底。
7. 普通会话默认在最近用户激活 15 分钟后收起且能配置为 1–1440 分钟；新用户消息使其重新出现。仍 active 的 Needs input 与 Blocked 不因普通超时消失，已关闭 Waiting 不长期占位。
8. 宠物动作能区分 Running、Needs input、Ready、Blocked，并按 Needs input > Blocked > Ready > Running 仲裁唯一主状态；气泡同时显示最多 8 个会话。
9. Codex 气泡能显示会话标题及受控的最新 Agent 回复；UserPromptSubmit 提供标题回退，Stop 提供最终回复，缺失时可按明确 session_id 通过 App Server 只读补全；ChatGPT 桌面任务即使 hooks 暂未触发也能由有界近期活动同步在 1 秒轮询周期内出现；已完成工具不得继续显示为当前活动，持久化层省略实时 item 时不得复活旧摘要；PermissionRequest/`activeFlags` 显示明确交互提示且不泄露工具参数。精确实时工具类别的验收以用户已信任的 `PreToolUse` 为前提。
10. 点击或右击任一会话行都路由到该行的 source/session，按钮文案仅为「打开」，关闭热区与会话热区不重叠；Warp 优先精确聚焦原 pane，其他 CLI 至少激活原终端 App；Codex 只对确认属于 ChatGPT 桌面 surface 的任务使用 `codex://threads/<session_id>`，未知/CLI surface 不盲用深链；明确关闭的会话不再提供打开操作。
11. 新 ChatGPT 桌面 App 内嵌 Codex CLI 优先于 PATH 旧 CLI；PetCore RPC 协议或构建 ID 不匹配时 App 强制替换旧守护进程。

### 14.4 性能

1. 默认高清 + 12 FPS 下，稳定播放至少 30 秒的 CPU 采样平均值不超过 4%。
2. 超清 + 20 FPS 下，相对隐藏悬浮层稳定 RSS 基线的 Renderer RSS 峰值增量不超过 260 MB。
3. 原画 + 20 FPS 下，相对隐藏悬浮层稳定 RSS 基线的 Renderer RSS 峰值增量不超过 420 MB。
4. 控制中心滚动、切换页面不受悬浮层动画影响。
5. 性能验收同时保留隐藏基线、绝对 App RSS、RSS 峰值增量、CPU 平均/峰值、采样数、采样间隔、实测 FPS、驻留解码缓存与 Metal/drawable 实分配遥测；估算缓存不能代替实测门禁。

### 14.5 App 生命周期

1. 关闭控制中心或按 `⌘W` 后，菜单栏状态项、桌宠、气泡与事件同步继续工作。
2. 菜单栏与桌宠右击菜单均能重新打开并置前唯一控制中心窗口。
3. `⌘Q`、Dock「退出」和「退出 Agent Pet」会退出全部 UI，但 PetCore health 仍可用。
4. 再次启动 App 能复用匹配版本的 PetCore 并恢复快照。
5. 重复打开和 `open -n` 不会产生第二个 UI Host、桌宠或状态栏图标。
6. 磁盘 App 构建被替换时，旧 UI Host 和旧 PetCore 按 `APCBuildID` 完成交接。
7. 发布候选的 runtime manifest 同时锁定 App、PetCore、CLI、数据库/事件 schema 与四个 connector contract；不兼容或降级组合 fail closed。
8. 更新使用候选预检与两阶段切换；新 Core health/schema 验证失败时自动恢复 last-known-good，UI 不会长期运行无数据或不兼容的桌宠。

---

## 15. 参考依据

- OpenAI ChatGPT Pets：桌面宠物使用 Running、Needs input、Ready、Blocked 状态，多任务优先级为 Needs input > Blocked > Ready > Running。
- OpenAI Codex App Server：用于产品内深度集成 Codex，会话、approval、streamed agent events；V1 使用逐行 JSON stdio request/notification 边界，不要求标准 JSON-RPC `jsonrpc` header。
- OpenAI Codex Hooks：支持 plugin-bundled lifecycle hooks，默认读取 plugin root 下的 `hooks/hooks.json`。
- Claude Code Hooks：支持在 SessionStart、UserPromptSubmit、PreToolUse、PermissionRequest、PostToolUse、Stop 等生命周期点执行 hooks。
- Pi Coding Agent：V1 使用 Extension；RPC mode 的 strict LF JSONL/UI 子协议属于未实现能力，不作健康声明。
- OpenCode：V1 plugin 契约固定在 v1.17.18；headless server 只通过 opt-in `/global/health` 探测验证。
