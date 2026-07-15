# Agent Pet Companion `.petpack` Whitepaper V1

文档状态：V1 实现对齐规范

Document status: V1 implementation-aligned normative specification

规范版本：`apc.petpack.v1`

基线日期：2026-07-16

## 摘要 / Abstract

`.petpack` 是 Agent Pet Companion 自有的、可移植的桌宠资源容器。V1 使用 ZIP 容器，包含严格的 `manifest.json`、七个固定状态的 PNG 帧、静态与动态预览、简要创作说明、来源元数据、隐私安全的生命周期事件和校验结果。当前 PetCore 已对容器路径、资源预算、manifest、七状态、帧尺寸、预览和基础元数据进行强制校验，并以不可变修订方式原子导入。历史未标记包继续使用兼容性最低门禁；`source/source.json` 明确标记 `apc.pet-source.v1` 的包会启用四份严格元数据 schema、跨文件一致性和递归隐私门禁。本文同时定义读写版本、未知字段、扩展和后续迁移策略。

A `.petpack` is Agent Pet Companion's portable, app-owned desktop-pet asset container. V1 uses ZIP and carries a strict manifest, PNG frames for seven fixed states, static and animated previews, a concise creative brief, provenance metadata, privacy-safe lifecycle events, and a validation artifact. PetCore enforces container safety, resource budgets, manifest semantics, state and frame constraints, preview decoding, baseline metadata, and atomic immutable-revision import. Historical untagged packages remain on a compatibility minimum gate; packages whose `source/source.json` declares `apc.pet-source.v1` activate all four strict metadata schemas, cross-artifact consistency checks, and recursive privacy checks. This document also defines reader/writer versions, unknown-field behavior, extensions, and future migration policy.

## 1. 规范边界与状态标记

本文使用四个明确标记，不能相互替代：

- **[V1 已实现 / Enforced]**：当前 PetCore、CLI 或 macOS App 已执行的强制行为；不满足时会被拒绝或产生明确 warning。
- **[V1 生产者契约 / Producer]**：V1 外部生产者必须遵守的可移植性、视觉真实性和内容卫生规则。带 `apc.pet-source.v1` 标记的 JSON 子集由 PetCore 强制；涉及视觉质量、参考图语义或非 JSON 内容的规则仍可能需要生产者或人工审计。
- **[V1 历史兼容 / Legacy]**：只为旧 App 已经写出的、`source/source.json` 没有 `schema_version` 的 V1 包保留最低元数据门禁。它保证可重新导入，不代表 Safe Producer 合规。
- **[未来/推荐 / Future/Recommended]**：推荐方向或兼容策略，当前不得宣称已经实现。

除非另有说明，`MUST`、`MUST NOT`、`SHOULD` 和 `MAY` 只在其所属标记范围内生效。

### 1.1 V1 非目标

`.petpack` 不是 Codex 内置宠物兼容包，不承诺 Petdex、公共图库、社区分享、云账户、Windows UI 或任意脚本插件能力。包内容是数据，不是可执行扩展。

## 2. 文件标识、容器和媒体类型

| 项目 | V1 状态 | 规则 |
|---|---|---|
| 扩展名 | [V1 已实现] | `.petpack`，大小写不敏感的 App 文件名检查 |
| 容器 | [V1 已实现] | ZIP；归档内统一使用 `/` 分隔路径 |
| 开发输入 | [V1 已实现] | 校验、构建和导入内部也可接收一个解包目录 |
| UTI | [V1 已实现] | `dev.agentpet.petpack`，代码与 App bundle 均声明 conform to `public.data` |
| Finder 文档关联 | [未来/推荐] | 当前尚未注册完整 `CFBundleDocumentTypes`，不能保证双击关联 |
| 专用 MIME | [V1 已实现的项目声明] | App bundle 的 UTI tag 使用 `application/vnd.agentpet.petpack+zip`；尚未向外部标准机构注册 |
| 通用 MIME | [未来/推荐] | `application/zip` 可作传输回退，但不能表达 `.petpack` 语义 |

ZIP 是交换格式；目录输入是开发与构建便利能力，不是跨应用交换时的规范载体。

## 3. V1 目录结构

### 3.1 规范结构

```text
<pet-id>.petpack
├── manifest.json
├── brief.json
├── assets/
│   ├── frames/
│   │   ├── idle/
│   │   │   └── *.png
│   │   ├── start/
│   │   │   └── *.png
│   │   ├── tool/
│   │   │   └── *.png
│   │   ├── waiting/
│   │   │   └── *.png
│   │   ├── review/
│   │   │   └── *.png
│   │   ├── done/
│   │   │   └── *.png
│   │   └── failed/
│   │       └── *.png
│   └── preview/
│       ├── cover.png
│       └── animated_preview.webp
├── source/
│   ├── prompt.md
│   ├── source.json
│   ├── references/
│   │   └── <optional copied PNG or WebP files>
│   └── skill_session.jsonl
└── build/
    └── validation.json
```

### 3.2 当前强制程度

- **[V1 已实现]** 上述文件和七个状态目录全部必须存在；`source/references/` 即使为空也必须存在。
- **[V1 已实现]** 七个状态目录内部只能直接放文件，不能再嵌套子目录。
- **[V1 已实现]** 状态目录内只有扩展名为 `.png`（大小写不敏感）的文件被计为帧；其他直接文件当前会被忽略。因此生产者不能依赖“附带文件会被拒绝”这一行为。
- **[V1 已实现]** 包根当前允许未识别的额外文件，但明确拒绝 `.codex-plugin`、`hooks`、`skills`、`codex-pet.json`、`codex_pet.json` 和 `pet.json`，以避免把本格式伪装为 Codex 兼容包。
- **[V1 生产者契约]** 未声明的根级文件不得出现。扩展数据应放在 `extensions/<reverse-dns>/...`，并且必须是不可执行的数据。

## 4. `manifest.json`

`manifest.json` 是运行时权威描述，当前结构由 [`schemas/petpack.schema.json`](../../schemas/petpack.schema.json) 描述。

### 4.1 必填字段

| 字段 | [V1 已实现] 规则 |
|---|---|
| `schema_version` | 必须精确等于 `apc.petpack.v1` |
| `id` | 必须匹配 `^pet_[a-z0-9]+$`，总长度 1–128 字符 |
| `name` | 非空白字符串 |
| `style` | 非空白字符串 |
| `quality` | `standard`、`high`、`ultra`、`original` 之一 |
| `render_size` | 必须与 `quality` 的固定尺寸完全匹配 |
| `fps_profiles` | 必须且仅按语义提供 `standard: 12`、`smooth: 20` |
| `default_fps_profile` | 必须为 `standard` |
| `states` | 必须恰好包含七个唯一固定状态，目录和 loop 语义固定 |
| `created_at` | RFC 3339 时间字符串 |

未知 manifest 字段会被当前 Rust 反序列化器和 schema 拒绝；V1 不允许在 manifest 顶层自由扩展。

### 4.2 画质和画布

| `quality` | 宽 | 高 |
|---|---:|---:|
| `standard` | 192 | 208 |
| `high` | 384 | 416 |
| `ultra` | 768 | 832 |
| `original` | 1536 | 1664 |

帧画布尺寸固定不代表可见主体必须填满画布。为避免动作切换时桌宠抖动，生产者应保持同一宠物所有状态的逻辑锚点、基线和画布一致。

### 4.3 固定状态

| 状态 | `frames_dir` | `loop` | 语义 |
|---|---|---:|---|
| `idle` | `assets/frames/idle` | `true` | 空闲 |
| `start` | `assets/frames/start` | `false` | 开始处理/思考开始 |
| `tool` | `assets/frames/tool` | `true` | 工具执行/工作中 |
| `waiting` | `assets/frames/waiting` | `true` | 等待用户输入或确认 |
| `review` | `assets/frames/review` | `true` | 有结果待查看 |
| `done` | `assets/frames/done` | `false` | 完成过渡 |
| `failed` | `assets/frames/failed` | `true` | 失败或阻塞错误 |

状态数组顺序当前不是语义的一部分，但生产者 SHOULD 使用上表顺序以获得稳定 diff。

## 5. 帧、动画和可见性

### 5.1 通用导入门禁

- **[V1 已实现]** 每个状态至少一张可解码 PNG。
- **[V1 已实现]** 只有一张帧时仍可导入，但返回“动画为静态”的 warning。
- **[V1 已实现]** 每个状态最多 40 帧，全包最多 280 帧。
- **[V1 已实现]** 每张帧的像素尺寸必须与 manifest `render_size` 完全一致。
- **[V1 已实现]** macOS 渲染端按文件名自然排序读取帧。
- **[V1 生产者契约]** 文件名使用零填充 ASCII 序号，例如 `0000.png`、`0001.png`；不得依赖本地化排序差异。

### 5.2 透明度和真实动画

- **[V1 生产者契约]** 桌宠视觉帧应使用带 alpha 的 PNG，背景透明，主体在画布内可见且不能完全透明。
- **[V1 生产者契约]** 声明为真实 AI/Agent 完整视觉来源时，每状态至少两帧，至少存在一处解码后像素变化；七状态不能全部复用同一视觉序列。
- **[V1 已实现]** 严格外部 Studio full-source 路径已检查每状态至少两帧、帧内可见变化，并要求至少四个状态的首帧解码摘要不同。
- **[V1 已实现的限制]** 通用 `.petpack` 导入器目前不检查 alpha 通道、可见边界、帧命名、运动幅度或跨状态重复；普通导入成功不能被解释为艺术质量认证。
- **[未来/推荐]** 在通用校验器中加入 alpha/可见像素、稳定锚点、帧序、最小运动和 AppKit/ImageIO 双解码一致性检查。

## 6. 预览资源

- **[V1 已实现]** `assets/preview/cover.png` 与 `assets/preview/animated_preview.webp` 都必须存在并能被图像库完整解码。
- **[V1 已实现]** 每张预览同样受单图像像素预算限制。
- **[V1 已实现]** `384×416` 是推荐尺寸；其他尺寸仅产生 warning，不会拒绝导入。
- **[V1 生产者契约]** `cover.png` 应能在不播放动画时清楚识别宠物；动态预览应与实际帧风格一致，不得展示包内不存在的角色。

## 7. 元数据、来源和隐私

### 7.1 分层运行时校验

以下基础门禁对所有 V1 包执行，包括历史未标记包：

| 文件 | [V1 已实现] 基础门禁 |
|---|---|
| `brief.json` | 文件存在且是合法 JSON |
| `source/prompt.md` | 文件存在、UTF-8 可读且去空白后非空 |
| `source/source.json` | 合法 JSON，`generator` 与 `provenance` 为非空字符串 |
| `source/references/` | 目录存在 |
| `source/skill_session.jsonl` | 每个非空行是 JSON，至少一行包含字符串 `event` |
| `build/validation.json` | 合法 JSON，且 `ok` 精确为 `true` |

基础门禁之后按 `source/source.json.schema_version` 分流：

1. **[V1 历史兼容]** 字段不存在：完成基础门禁后继续导入。其他元数据文件即使单独出现 `schema_version`，也不会把历史包升级为 Safe Producer profile。
2. **[V1 已实现]** 字段精确为 `apc.pet-source.v1`：启用 7.2 的 tagged Safe Producer profile。
3. **[V1 已实现]** 字段存在但不是字符串、值未知、值较新或值较旧：拒绝；V1 不猜测兼容，也不静默退回历史门禁。

历史兼容只解决旧包重新导入。未标记元数据按不可信数据保存和展示，不得被 UI、Skill 或文档标成已通过 Safe Producer 隐私审计。

### 7.2 严格生产者 schema

| 文件 | Schema | 主要目标 |
|---|---|---|
| `source/source.json` | [`pet-source.schema.json`](../../schemas/pet-source.schema.json) | 有界来源声明、真实 provenance、相对参考图路径、full-source 条件 |
| `brief.json` | [`pet-brief.schema.json`](../../schemas/pet-brief.schema.json) | 角色简报、七状态动作说明、画质/尺寸/FPS 一致性 |
| `source/skill_session.jsonl` 每一行 | [`pet-source-event.schema.json`](../../schemas/pet-source-event.schema.json) | 仅记录隐私安全生命周期事件 |
| `build/validation.json` | [`pet-validation.schema.json`](../../schemas/pet-validation.schema.json) | 成功校验声明及有界诊断摘要 |

tagged Safe Producer profile 的四个版本字段全部是 MUST，且分别精确等于：

| Artifact | 必须声明的版本 |
|---|---|
| `source/source.json` | `apc.pet-source.v1` |
| `brief.json` | `apc.pet-brief.v1` |
| `source/skill_session.jsonl` 每个非空记录 | `apc.pet-source-event.v1` |
| `build/validation.json` | `apc.pet-validation.v1` |

当前 App Studio、`agent-pet-maker` 和示例写入器都写出上述标记。只要 source 选择 tagged profile，其他 artifact 缺少标记、使用未知版本或出现 schema 未声明字段都会拒绝；不能逐文件退回旧规则。

**[V1 已实现]** PetCore 对 tagged profile 依次执行：

1. 四份 Draft 2020-12 schema 校验；JSONL 对每个非空行逐条校验；
2. `brief` 的名称、风格、画质及可选运行尺寸与 `manifest.json` 一致；
3. `source` 中存在的 manifest ID、名称、风格、画质与 manifest 一致；
4. validation 中存在的 manifest ID 一致；若嵌入完整 manifest，还会再次使用 `petpack.schema.json` 校验并要求逐字段相同；
5. 对 `brief.json`、`source/source.json`、`build/validation.json` 和每条 session event 做递归隐私检查，包括开放的 `ai_brief` 与 `extensions` 值；
6. schema 失败最多返回八组有界的 instance/schema JSON Pointer，只报告位置和类别，不回显被拒绝的用户值、路径、credential 或 transcript。

`pet-validation.schema.json` 中的 `manifest` 只声明为对象；若存在，仍必须单独使用 `petpack.schema.json` 校验。校验 artifact 不能替代对实际包内容的重新校验。

四份严格 schema 顶层均为 `additionalProperties: false`；其封闭子对象同样拒绝未知字段。显式开放点只有 schema 中列出的有界字段，例如 `ai_brief` 和以反向域名 key 命名的 `extensions`。开放值仍接受递归隐私门禁，不能借扩展容器携带会话、命令、绝对路径、URL 或凭据。

### 7.3 来源声明不是签名

- `generator` 描述实际生成器或生产者。
- `provenance` 描述生成路径，例如 `skill-full-source`、`deterministic_preview`、`local_form`。
- `visual_source` 描述视觉来源；只有真实图像能力生成才能使用 `image-generation`，确实采用用户参考图时才能使用 `user-reference-derived`。
- `preview_only` 必须如实标记确定性预览或非正式结果。
- **[V1 已实现]** 严格 Studio full-source 路径拒绝 materializer 冒充 `skill-full-source`，并校验参考图来源语义。
- **[V1 已实现的限制]** 这些字段不是密码学签名，也没有受信任发行者证书；普通外部包可以自我声明。
- **[未来/推荐]** 可选内容摘要与签名清单，但不能破坏离线、本地优先和无账户导入。

### 7.4 隐私规则

**[V1 生产者契约]** 可移植包不得包含：

- 对话全文、用户/assistant 消息列表或隐藏思考内容；
- Codex/Claude/Pi/OpenCode 的 thread、turn、session、request 等运行标识；
- 命令、工具参数、工具输出、环境变量、终端内容；
- 绝对本地路径、用户名、主机名、工作区路径；
- token、cookie、API key、认证文件或任何 secret；
- 未经用户选择且与宠物视觉无关的源文件。

`source/skill_session.jsonl` 只记录如 `skill.loaded`、`states.rendered`、`petpack.validated` 的有界生命周期事件。`source/prompt.md` 应保存完成宠物所需的归一化创作请求，而不是整段会话。

参考图本身可能包含敏感内容。生产者 MUST 只复制实际使用且用户允许随包导出的参考图；V1 没有自动脱敏或人脸/EXIF 清理保证。

**[V1 已实现]** 当前 Studio 在打包前移除 App Server thread/turn/session/request/command-source 字段，并重写 `skill_session.jsonl` 为符合事件 schema 的有界生命周期记录；当前生成链路有自动测试逐条校验四份生产者 schema。tagged Safe Producer 包由通用 PetCore 导入器再次递归拒绝私有字段、绝对本地路径和外部 locator，扫描深度与节点数也有上限，错误不会回显敏感值。

**[V1 历史兼容]** 旧版本 App 已生成的未标记包可能仍含旧式执行元数据；为了保留原 archive 的可重新导入能力，基础门禁不会自动升级为严格隐私审计。用户重新导出这类 archive 也不会凭空获得 Safe Producer 身份。`source/prompt.md` 的自然语言语义和参考图二进制内容即使在 tagged profile 下也无法由 JSON schema 完整脱敏，生产者仍必须遵守本节内容卫生规则。

## 8. 参考图策略

- **[V1 已实现，Studio 输入边界]** 最多 4 张，仅 PNG/WebP；单文件最多 20 MiB，总计最多 40 MiB，单图最多 16,000,000 像素，并检查扩展名、实际格式和可解码性。
- **[V1 已实现的限制]** 通用外部 `.petpack` 导入对 `source/references/` 应用全包路径和资源预算；tagged profile 还校验 JSON 中的相对引用声明，但目前不逐个文件套用上述 Studio 媒体类型、单文件大小和 EXIF/语义边界。
- **[V1 生产者契约]** `source.json` 和 `brief.json` 最多引用 4 个包内参考文件；路径必须是 `source/references/...`，或兼容现有 helper 的该目录内 basename。禁止绝对路径和 `..`。
- **[未来/推荐]** 导入器逐文件验证包内参考图、清理不必要元数据，并让用户在导出时选择是否包含参考图。

## 9. 导入、安装、修订和 ID

### 9.1 校验与原子导入

**[V1 已实现]** 导入流程是：

1. 校验归档或目录输入；
2. 在 App 自有宠物存储区创建隐藏 staging revision；
3. 对目录输入构建 ZIP，对归档输入保留原始包字节；
4. 安全解包运行时帧和封面，并再次校验 staged package；
5. 同步文件，原子发布不可变 revision 目录和 `active.json`；
6. 提交数据库指针；任一步失败则回滚 staging、指针和数据库可见状态。

宠物库变更使用独立文件锁串行化；旧 revision 不会被新 revision 原地覆盖。

### 9.2 ID 与冲突行为

- `manifest.id` 是宠物的逻辑身份，也是本地修订根目录的安全文件名。
- 推荐生产者生成高熵、稳定的小写字母数字后缀，例如 `pet_` 加随机或内容派生标识；V1 不规定 UUID 文本格式。
- **[V1 已实现]** 导入一个已存在的相同 ID 会创建新的不可变 revision，并更新该 ID 的当前数据库记录；不会新建第二个同 ID 宠物。
- **[V1 已实现]** 如果旧记录是活跃宠物，新 revision 保持活跃；如果不是活跃宠物，不会因修订而抢占当前桌宠。宠物库第一次导入会自动成为活跃宠物。
- **[V1 已实现的限制]** 普通外部导入遇到相同 ID 时没有“替换/另存为/取消”用户确认，也没有来源所有权证明。
- **[未来/推荐]** 外部导入冲突 UI 应区分“同一宠物新修订”和“无关包碰撞”，允许生成新 ID；跨设备同步前需要更强的 revision lineage。

### 9.3 修订保留

- **[V1 已实现]** revision 目录不可变，活动指针和数据库只指向当前 revision。
- **[V1 已实现的限制]** 没有面向用户的完整版本历史、回退和保留策略；旧 revision 可能占用磁盘。
- **[未来/推荐]** 增加可审计 revision parent、回退、配额与垃圾回收，但删除必须避免破坏仍被数据库或任务引用的 revision。

## 10. 导出与往返

- **[V1 已实现]** 导出读取 App 自有存储中的当前不可变 archive，不重新编码内容，因此能保留来源和未知可选元数据的原始字节。
- **[V1 已实现]** 导出前校验已安装 archive，复制到目标目录内的临时文件，再次校验 staged copy，最后在同一文件系统原子 rename。
- **[V1 已实现]** 目标必须在 App 自有宠物存储区之外；现有 symlink 或非普通文件目标会被拒绝。目标父目录必须已存在。
- **[V1 已实现]** 导出返回字节数和完整校验结果；RPC 和 CLI 均提供 `petpack.export`/`petpack export` 路径。
- **[V1 已实现的边界]** “字节相同”适用于已安装 archive 到导出 archive；从目录重新构建 ZIP 不保证逐字节可复现。
- **[V1 已实现]** Rust 回归测试把导出 archive 导入第二个隔离 home，核对同一宠物 ID、名称和可校验 manifest；该测试与导出前后字节相同断言共同构成当前 new-home 往返门禁。
- **[未来/推荐]** 规范化 ZIP 条目排序、时间戳、权限和压缩参数，提供从目录构建时的可复现字节输出。

### 10.1 可移植 Agent 制作与显式安装

- **[V1 已实现]** `agent-pet-maker` 是 provider-neutral 的生产者 Skill：宿主必须具备真实图像理解与生成/编辑能力；helper 只负责安全 workspace、结构/哈希约束、元数据、PetCore CLI 校验和构建，不生成替代视觉素材。
- **[V1 已实现]** `create` 生成新 ID；`modify` 安全展开现有包，保持 ID 与结构契约，并验证未声明修改的状态逐文件 byte-identical。缺少真实图像能力时返回 `capability_missing`，不输出伪包。
- **[V1 已实现]** 默认只输出 `.petpack` 和 sidecar。只有用户明确要求导入或启用时，Skill 才能通过当前在线 PetCore daemon 再校验、导入并选择性激活；不得静默使用 `--offline` 写入用户库。
- **[V1 已实现的边界]** 激活表示 PetCore 中的唯一 active pet 已切换；是否此刻真实显示还取决于 macOS UI Host 正在运行且全局 `behavior.enabled` 为 true。Skill 只报告可观测状态，不擅自启动 App、抢占输入或改写全局桌宠开关。

## 11. 版本与兼容策略

### 11.1 当前行为

- **[V1 已实现]** 读取器只接受精确的 `apc.petpack.v1`；未知、较新或较旧版本全部拒绝。
- **[V1 已实现]** 当前没有 manifest migration，也没有兼容版本区间协商。
- **[V1 已实现]** `apc.runtime-manifest.v1` 同时公布 `petpack_read_versions=["apc.petpack.v1"]` 与 `petpack_write_version="apc.petpack.v1"`。单值 `petpack_schema_version` 作为当前 manifest 内的同值别名保留，并被要求等于 write version；App 与 PetCore 的运行时交接仍要求完整 runtime manifest 精确兼容，这个别名不承诺任意旧运行时可以读取未来 manifest。
- **[V1 已实现]** 对于早期同版 `apc.runtime-manifest.v1`，Rust 和 Swift 在读写字段缺失时从 `petpack_schema_version` 重建 `petpack_read_versions=[petpack_schema_version]` 与 `petpack_write_version=petpack_schema_version`；该兼容只适用于同 schema ID 的旧字段集，不放宽未知版本。
- **[V1 已实现]** manifest `additionalProperties: false`，所以不能通过向 V1 manifest 随意添加字段实现兼容扩展。

### 11.2 元数据 profile 与未知字段

| 输入 | 当前读取行为 | 当前写入行为 |
|---|---|---|
| `manifest.schema_version=apc.petpack.v1` | 继续完整 V1 校验 | 所有当前写入器只写 V1 |
| 未知/未来/旧 `manifest.schema_version` | fail closed | 不产生 |
| `source.json` 无 `schema_version` | 历史最低门禁；不授予 Safe Producer | 当前写入器不再省略 |
| `source.json.schema_version=apc.pet-source.v1` | 四份严格 metadata schema、交叉一致性和递归隐私门禁 | App 与 portable Skill 默认写出 |
| 未知/错误 source metadata 版本 | fail closed，不退回历史路径 | 不产生 |
| tagged source 搭配缺失/未知 brief、event 或 validation 版本 | fail closed | 不产生 |

V1 core manifest 的未知字段全部拒绝。tagged metadata 的未知顶层/封闭子对象字段也拒绝；可选扩展只能进入 schema 明确声明的 `extensions` 容器并满足 key、数量与隐私规则。历史未标记 metadata 的额外字段会随原 archive 保留，但不被解释为运行能力，也不证明安全。包根额外数据文件的兼容保留策略见 3.2 和 13.3。

### 11.3 后续版本规则

以下均为 **[未来/推荐]**：

1. `apc.petpack.vMAJOR` 的 MAJOR 表示破坏性结构版本；未知 MAJOR 必须拒绝。
2. 迁移必须先完整校验旧包，在新 staging revision 中生成新包，再原子切换；不得原地修改已安装 revision。
3. 读取旧版本可以迁移，写出只使用当前规范版本；导出原始旧 archive 或迁移后 archive 必须由用户明确选择。
4. 如果需要同 MAJOR 的兼容小版本，应新增独立 `format_revision` 或 capability 列表，不能改变 V1 `schema_version` 的现有精确语义。
5. 未来 manifest 扩展应使用显式 `extensions` 容器和反向域名 key，并发布新 schema；不能悄悄放宽 V1 schema。

## 12. 安全预算与路径策略

### 12.1 当前强制预算

| 预算 | [V1 已实现] 上限 |
|---|---:|
| ZIP archive | 1 GiB |
| ZIP/目录条目数 | 5,000 |
| 单条目/单文件 | 256 MiB |
| 解压/目录总文件字节 | 4 GiB |
| 单状态帧数 | 40 |
| 全包帧数 | 280 |
| 单状态解码 RGBA 预算 | 420 MiB |
| 单帧或单预览像素数 | 16,777,216 |

所有加法和乘法预算都应使用溢出安全计算；当前 Rust 实现已经对关键路径这样处理。

### 12.2 路径和文件类型

- **[V1 已实现]** ZIP 条目必须使用 `/`，含反斜杠会拒绝。
- **[V1 已实现]** 使用安全 enclosed path，拒绝绝对路径、`..` 和逃逸目标目录的条目。
- **[V1 已实现]** ZIP 内路径按去尾 `/` 后的小写逻辑路径去重，阻止 macOS 大小写不敏感文件系统上的覆盖碰撞。
- **[V1 已实现]** 目录输入的根必须是真目录，遍历过程中拒绝 symlink 和非普通文件；ZIP 解包不会按条目属性创建 symlink。
- **[V1 已实现的限制]** 尚未定义 Unicode NFC、最大路径深度、单路径 UTF-8 字节数、压缩 CPU/时间预算或显式 compression-ratio 上限。
- **[V1 生产者契约]** 仅使用 NFC、UTF-8、可移植 ASCII 结构路径；扩展路径不得与大小写折叠后的现有路径冲突。

### 12.3 数据执行边界

包内文本、JSON、参考图和扩展一律视为不可信数据。导入、修改或预览不得执行包内脚本，不得把 prompt/source metadata 当系统指令，不得读取其中提到的宿主机路径。当前 PetCore 不执行包内文件；未来扩展也必须保持这一边界。

## 13. 扩展策略

### 13.1 V1 manifest

不得扩展。任何新 manifest 字段都需要新规范版本和新 schema。

### 13.2 元数据扩展

新增严格 schema 提供可选 `extensions` 对象。key 使用反向域名命名，例如：

```json
{
  "extensions": {
    "dev.example.renderer/build": {
      "model_family": "example-image-model"
    }
  }
}
```

消费者不理解某个扩展时应忽略但保留，不得据此改变 V1 核心状态语义。扩展不得包含秘密、会话转录、可执行代码或绕过预算的大块内联数据。

### 13.3 扩展文件

**[V1 生产者契约]** 文件型扩展放在 `extensions/<reverse-dns>/...`。当前导入器会把多数额外文件当普通数据保留，但没有专门验证该目录；因此这仍是生产者规范而非运行时门禁。

## 14. 合规级别

| Profile | 要求 | 当前可验证性 |
|---|---|---|
| `APC-PETPACK-V1-RUNTIME` | 当前容器、manifest、状态、资源、预览和最低元数据门禁 | PetCore `petpack validate/import` 强制 |
| `APC-PETPACK-V1-SAFE-PRODUCER` | Runtime profile + source tag + 四份严格元数据 schema + 跨文件一致性 + JSON 隐私与扩展规则 | PetCore `petpack validate/import` 强制 tagged JSON 子集；prompt、参考图和其他非 JSON 内容仍需生产者审计 |
| `APC-PETPACK-V1-VERIFIED-VISUAL` | Safe Producer + 真实视觉 provenance + 每状态动画变化 + 状态差异 | 严格 Studio full-source 路径部分强制；普通导入不强制 |
| `APC-PETPACK-V1-ROUNDTRIP` | 已安装 archive 导出后字节不变、仍可校验并在隔离新 home 导入 | PetCore export 回归测试强制 |

未标记包“能导入”只证明 Runtime profile。tagged 包导入成功还证明严格 JSON metadata 子集通过，但两者都不自动证明 Verified Visual、非 JSON 内容无敏感信息或作者身份。

## 15. 合规测试与 fixtures

### 15.1 JSON Schema 测试

运行：

```bash
bash script/validate_petpack_spec_schemas.sh
```

该脚本使用 Draft 2020-12 校验：

- `schemas/petpack.schema.json`
- `schemas/pet-source.schema.json`
- `schemas/pet-brief.schema.json`
- `schemas/pet-source-event.schema.json`
- `schemas/pet-validation.schema.json`

每个 schema 对应的 `fixtures/schemas/<name>/` 至少包含一个 `valid-*.json` 和一个 `invalid-*.json`。事件 schema 对 `skill_session.jsonl` 的每个非空行逐行应用；fixture 文件代表单行对象。

### 15.2 当前 Rust 协议测试

实现变更后至少运行：

```bash
cargo test --locked -p petcore --test schema_fixtures
cargo test --locked -p petcore --test petpack_import_atomic
cargo test --locked -p petcore --test petpack_resource_limits
cargo test --locked -p petcore --test petpack_export
cargo test --locked -p petcore-cli --test petpack_import_routing
cargo test --locked -p petcore-cli --test petpack_export_routing
```

### 15.3 端到端矩阵

**[V1 已实现]** 当前 Rust 回归覆盖 archive import → export 字节相同 → 第二个隔离 home 重新导入、同 ID 修订与活动状态保持、严格 metadata schema/交叉一致性/递归隐私负例，以及 traversal、大小写冲突、symlink、资源超限和畸形图像负例。

仍建议继续扩展的 CI/实机矩阵：

1. 目录 source → build → validate → import；
2. 每种质量、每个 FPS profile 和七状态真实 macOS renderer 解码；
3. source/prompt 与参考图导出的人工隐私/授权审计；
4. 未来 migrator 出现后，补充旧版本升级与失败回滚测试。

## 16. 实现映射

| 规范领域 | 当前实现/契约位置 |
|---|---|
| 核心类型、状态、画质、manifest | `crates/petcore-types/src/lib.rs` |
| 容器校验、预算、build/import/export | `crates/petcore/src/petpack.rs` |
| 不可变 revision、锁、active pointer、回滚 | `crates/petcore/src/pet_revision.rs` |
| 宠物记录和首次激活 | `crates/petcore/src/db.rs` |
| Studio full-source provenance、视觉差异、session 写入 | `crates/petcore/src/generation.rs` |
| RPC 方法 | `crates/petcore/src/rpc.rs` |
| CLI build/validate/import/export | `crates/petcore-cli/src/main.rs` |
| manifest schema | `schemas/petpack.schema.json` |
| 严格生产者元数据 schema | `schemas/pet-source.schema.json`、`pet-brief.schema.json`、`pet-source-event.schema.json`、`pet-validation.schema.json` |
| macOS UTI 和导入文件策略 | `apps/macos/Sources/AgentPetCompanion/App/PetpackImportPolicy.swift` |
| macOS 导入/导出交互 | `apps/macos/Sources/AgentPetCompanion/App/AppStore.swift`、`Views/PetLibraryView.swift` |
| 帧发现、自然排序和渲染预算 | `PetAssetLocator.swift`、`Overlay/PetFramePipeline.swift` |
| 产品/技术基线 | `docs/design/product-plan-v5/AgentPetCompanion_ProductPlan_V5.md`、`docs/design/AgentPetCompanion_TechnicalPlan_V1_1.md` |

## 17. 已知边界与后续顺序

### V1 已收口：Safe Producer JSON 门禁

1. 通用 validate/build/import 路径调用四份 metadata schema，JSONL 按非空行校验。
2. tagged profile 执行 manifest 交叉一致性与递归 JSON 隐私检查；诊断稳定、有界、含 instance/schema JSON Pointer 且不回显数据值。
3. 历史未标记包与 tagged 包使用显式分流；未知 source metadata 版本 fail closed。

### 后续：提高可移植性和视觉真实性

1. 通用 validator 增加 alpha、可见像素、帧差异和 macOS ImageIO 可解码性门禁。
2. 校验包内 references 的类型、大小、像素和路径引用一致性。
3. 增加确定性 ZIP 构建；当前 archive/import/export new-home 往返已由 Rust 回归覆盖。
4. 完成 UTI 文档类型注册与 Finder 双击导入/导出行为；专用 MIME 已固定为 `application/vnd.agentpet.petpack+zip`，后续只需随生态需求评估外部注册。

### 更远期：版本与生态

1. reader/writer capability 协商与迁移器；
2. revision lineage、历史 UI、回退与回收；
3. 可选签名/摘要清单和可信生产者展示，但不强制云账户。

## 18. 生产者发布清单

发布前逐项确认：

- [ ] 输出是 ZIP `.petpack`，路径仅使用 `/`，无 symlink、绝对路径或 `..`。
- [ ] `manifest.json` 通过 `petpack.schema.json` 且是 `apc.petpack.v1`。
- [ ] 七状态、固定目录、loop、质量尺寸、12/20 FPS 完全一致。
- [ ] 每状态至少一帧；真实 Agent 视觉至少两帧且确有运动与状态差异。
- [ ] PNG 背景透明、主体可见、锚点稳定；预览可解码。
- [ ] 新包明确选择 tagged Safe Producer profile；四个 artifact 分别写入正确且必填的 `apc.pet-source.v1`、`apc.pet-brief.v1`、`apc.pet-source-event.v1`、`apc.pet-validation.v1`。
- [ ] `brief.json`、`source.json`、每条非空 session event、`validation.json` 通过对应严格 schema，并与 manifest 一致。
- [ ] provenance 如实，没有 materializer 冒充真实 AI 视觉来源。
- [ ] 无对话、运行 ID、命令、工具输出、绝对路径、环境变量或 secret。
- [ ] 参考图仅包含用户允许随包导出的实际使用文件，最多 4 张。
- [ ] `petcore-cli petpack validate` 成功，warning 已审阅。
- [ ] 导入、激活、七状态渲染、导出和重新导入均通过。

---

本白皮书以代码中的当前强制行为为基线。若文档、schema 与 PetCore 运行时发生冲突，必须先将冲突记录为实现差距；不得通过修改措辞把尚未实现的门禁描述为已完成。
