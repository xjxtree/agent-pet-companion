# Agent Pet Companion 产品方案 V5

## 1. 产品定位

**Agent Pet Companion** 是一款 macOS 原生高画质桌宠 App。

它的核心不是 Agent 管理平台，也不是公共宠物图库，而是：

- 通过 AI 生成高自由度桌宠。
- 在桌面显示高画质宠物悬浮层。
- 让宠物响应 Codex、Claude Code、Pi Coding Agent、OpenCode 的工作状态。
- 在 App 内完成宠物制作、启用、行为配置和 Agent 连接检查。

V5 中，新建宠物只在初始表单中指定风格、画质和参考要求；后续制作全部进入内置 Skill 驱动的 AI 会话中完成。

---

## 2. V5 信息架构

主导航只保留三个入口：

```text
宠物 Studio
启用与行为
Agent 连接
```

「宠物 Studio」内部只保留两个页签：

```text
新建
宠物库
```

「宠物库」不再作为侧栏入口，只展示用户历史创建的宠物。

---

## 3. 宠物 Studio

### 3.1 新建宠物

新建宠物只在开始时填写一个预设表单。表单字段固定为：

| 字段 | 说明 |
|---|---|
| 描述 | 用户对宠物外观、气质、动作的自然语言要求 |
| 风格预设 | 写实、半写实、现代、像素、动漫、不指定 |
| 图像画质 | 实机宠物渲染分辨率 |
| 参考图 | 可选，用于角色形象或风格参考 |

风格预设中的「不指定」表示 AI 根据用户描述自行决定视觉方向。

图像画质定义为实机桌宠帧分辨率：

| 画质 | 单帧分辨率 | 用途 |
|---|---:|---|
| 标清 | 192×208 | 低占用、小尺寸显示 |
| 高清 | 384×416 | 默认推荐 |
| 超清 | 768×832 | 高清桌面显示 |
| 原画 | 1536×1664 | 高质量显示与二次生成 |

![宠物 Studio 新建](images/01_pet_studio_create.png)

### 3.2 AI 会话式生成

用户点击「发起 AI 会话」后，App 启动内置 Skill，并在 Studio 右侧展示会话窗口。

后续流程全部在 AI 会话中进行：

```text
读取表单
→ 必要时补充追问
→ 生成主形象
→ 生成状态动作
→ 渲染实机帧
→ 保存 .petpack
→ 出现在宠物库
```

用户可以在会话中继续提出调整意见，例如“裙摆更轻一点”“等待确认动作更明显”“换成像素风”。

![AI 会话生成](images/02_pet_studio_session.png)

### 3.3 宠物库

宠物库只展示用户历史创建的宠物。新建完成后，宠物自动进入宠物库。

宠物库支持：

- 查看历史宠物。
- 启用某个宠物。
- 查看资源信息。
- 删除本地宠物。
- 导出 `.petpack`。

不做公共素材库、分享社区、Petdex 类图库。

![宠物库](images/03_pet_library.png)

---

## 4. 启用与行为

「启用与行为」用于控制桌宠是否运行，以及响应哪些 Agent 和事件。

页面包含：

| 模块 | 功能 |
|---|---|
| 启用 | 桌宠开关、状态气泡、点击菜单 |
| 响应来源 | Codex、Claude Code、Pi Coding Agent、OpenCode |
| 响应事件 | 开始处理、执行工具、等待确认、待查看、完成、失败 |
| 桌宠交互 | 拖动移动、悬停显示缩放手柄、右下角拖拽缩放 |

显示尺寸不在设置页配置。用户把鼠标放在桌宠区域后，直接拖拽右下角缩放手柄调整大小。

![启用与行为](images/04_behavior_settings.png)

---

## 5. Agent 连接

「Agent 连接」只检查桌宠响应所必需的连接条件。

每个 Agent 检查项固定为：

| Agent | 检查内容 |
|---|---|
| Codex | CLI、插件、Hook、事件通道 |
| Claude Code | CLI、Hooks、事件通道 |
| Pi Coding Agent | CLI、Extension、RPC 通道 |
| OpenCode | Server、Plugin、事件流 |

该页提供「检查」和「一键修复」。修复范围仅限安装或更新连接所需的本地插件、Hook、Extension、服务配置。

![Agent 连接](images/05_agent_connections.png)

---

## 6. 桌宠悬浮层

桌宠悬浮层负责实际显示宠物和状态气泡。

固定交互：

- 拖动宠物区域移动位置。
- 鼠标悬停显示右下角缩放手柄。
- 拖拽缩放手柄调整显示大小。
- 点击宠物打开快捷菜单。
- Agent 事件触发对应动作。

![桌宠悬浮层](images/06_overlay_resize.png)

---

## 7. 宠物资源格式

App 内部只使用自己的 `.petpack`，不再生成 Codex 内置宠物素材包。

`.petpack` 是 App 自有的 ZIP 格式，以下条目直接位于归档根目录；导入与安装由 App/PetCore 完成，不作为 Codex 内置宠物兼容包：

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

核心状态：

```text
idle
start
tool
waiting
review
done
failed
```

其中 Agent 事件到宠物状态的映射为：

| Agent 事件 | 宠物状态 |
|---|---|
| 开始处理 | start |
| 执行工具 | tool |
| 等待确认 | waiting |
| 待查看 | review |
| 完成 | done |
| 失败 | failed |

---

## 8. 借鉴 Petdex 的技术点

产品层不做 Petdex 类公共图库。仅借鉴这些实现思路：

- 本地 sidecar 接收 Agent 事件。
- Hook / Plugin / Extension 写入事件。
- 本地连接 doctor 检查。
- 本地事件接口使用 token 或 socket 权限保护。
- 宠物资源包本地化管理。

---

## 9. V1 验收标准

V1 完成时必须满足：

1. App 主导航只有「宠物 Studio」「启用与行为」「Agent 连接」。
2. 宠物 Studio 只有「新建」「宠物库」。
3. 新建宠物初始表单包含描述、风格预设、图像画质、参考图。
4. 点击「发起 AI 会话」后，后续制作流程在会话窗口内完成。
5. 生成完成后，宠物自动进入宠物库。
6. 用户可以从宠物库启用历史宠物。
7. 启用与行为页只配置响应来源与 Agent 事件。
8. 显示大小通过悬浮层右下角缩放手柄调整。
9. 支持 Codex、Claude Code、Pi Coding Agent、OpenCode 的连接检查。
10. 不生成 Codex 内置宠物兼容包。
