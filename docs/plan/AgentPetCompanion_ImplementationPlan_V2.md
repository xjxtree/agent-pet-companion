# Agent Pet Companion 落地任务规划 V2（阶段版）

> 基于《Agent Pet Companion 产品方案 V5》与《Agent Pet Companion 技术方案 V1.1》。目标是先完成 macOS V1：宠物 Studio、宠物库、启用与行为、Agent 连接、桌宠悬浮层、多 Agent 响应、AI 辅助生成 `.petpack`。

---

## 1. 版本目标

V1 交付范围固定为：

```text
macOS 原生 App
Rust PetCore
AI 宠物 Studio
本地宠物库
启用与行为配置
Agent 连接检查
桌宠悬浮层
Codex / Claude Code / Pi / OpenCode 事件响应
```

不包含：

```text
公共素材库
宠物分享
Petdex 导入
Codex 内置宠物兼容导出
Windows UI
云端账号
任务管理平台
完整 Agent Mission Control
```

---

## 2. 阶段划分

V1 只按阶段推进，不绑定固定时间。每个阶段以验收结果作为进入下一阶段的条件。

| 阶段 | 目标 | 进入下一阶段条件 |
|---|---|---|
| M0 | 工程骨架与技术验证 | App、PetCore、悬浮窗、Codex App Server 基础链路跑通 |
| M1 | PetCore 与 macOS Shell | 本地 daemon、IPC、SQLite、主窗口、状态订阅可用 |
| M2 | 桌宠渲染与 `.petpack` | 四档分辨率、12 FPS / 20 FPS、状态切换、缩放手柄可用 |
| M3 | 宠物 Studio AI 会话 | 初始表单能发起 AI 会话，生成结果可入库 |
| M4 | 多 Agent 连接 | Codex / Claude Code / Pi / OpenCode 事件能统一驱动宠物状态 |
| M5 | 宠物库与启用行为 | 宠物启用、删除、来源过滤、事件过滤、帧率设置即时生效 |
| M6 | 性能、稳定性、安全检查 | 资源占用、安全边界、异常恢复达到 V1 可用标准 |

---

## 3. M0：工程骨架与技术验证

### 3.1 任务

1. 创建 monorepo。
2. 初始化 macOS App 工程。
3. 初始化 Rust workspace。
4. 建立 PetCore daemon 与 CLI 基础结构。
5. 验证 Swift ↔ Rust Unix Domain Socket 通信。
6. 验证 NSPanel 透明悬浮窗。
7. 验证 Metal 显示透明 PNG 帧。
8. 验证 Codex App Server stdio 启动和基础消息收发。

### 3.2 目录结构

```text
agent-pet-companion/
  apps/
    macos/
      Package.swift
      Sources/
        AgentPetCompanion/
        AgentPetCompanionCore/
        AgentPetCompanionCoreValidation/
  crates/
    petcore/
    petcore-cli/
    petcore-types/
  plugins/
    codex/
    claude-code/
    pi/
    opencode/
  skills/
    agent-pet-studio/
  schemas/
  docs/
```

### 3.3 验收

```text
macOS App 能启动
PetCore 能启动
App 能通过 Unix socket 调用 petcore.health
透明悬浮窗能显示一组测试帧
Codex App Server 能被 PetCore 启动并初始化
```

---

## 4. M1：PetCore 与 macOS Shell

### 4.1 PetCore daemon

任务：

1. 实现 daemon 主进程。
2. 实现 Unix socket JSON-RPC。
3. 实现 SQLite 初始化。
4. 实现 LaunchAgent 安装与卸载。
5. 实现配置目录初始化。
6. 实现本地 HTTP event endpoint。
7. 实现 capability token 文件。
8. 实现日志系统。

交付：

```text
petcore
petcore-cli
SQLite schema
LaunchAgent plist
runtime token
```

验收：

```text
petcore-cli health 返回 ok
App 重启后 PetCore 自动恢复
本地 HTTP endpoint 不带 token 返回 401
带 token 可写入测试事件
```

### 4.2 macOS Shell

任务：

1. 实现主窗口布局。
2. 实现侧栏三个入口：宠物 Studio、启用与行为、Agent 连接。
3. 实现菜单栏图标。
4. 实现基础设置持久化。
5. 实现 App 与 PetCore 状态订阅。

验收：

```text
三个主入口可切换
菜单栏可显示/隐藏主窗口
设置项能写入 SQLite
PetCore 状态变化能推送到 App
```

---

## 5. M2：桌宠渲染与 `.petpack`

### 5.1 `.petpack` 构建器

任务：

1. 定义 manifest schema。
2. 实现 petpack 解包。
3. 实现 petpack 打包。
4. 实现素材校验。
5. 实现 cover 与 preview 生成。
6. 实现 7 个固定状态目录校验。

状态固定为：

```text
idle
start
tool
waiting
review
done
failed
```

验收：

```text
缺少 manifest 时校验失败
缺少任一必需状态时校验失败
尺寸不匹配时校验失败
有效 petpack 可导入 SQLite
```

### 5.2 Renderer

任务：

1. 实现 Metal-backed pet renderer。
2. 实现 PNG 帧解码。
3. 实现 12 FPS frame scheduler。
4. 实现 20 FPS frame scheduler。
5. 实现状态切换。
6. 实现原画档环形缓存。
7. 实现隐藏暂停。
8. 实现右下角缩放手柄。

验收：

```text
四档分辨率均可播放
12 FPS 播放稳定
20 FPS 播放稳定
拖拽缩放顺滑
隐藏悬浮层后动画停止
原画档不会一次性加载全部状态
```

### 5.3 性能基准

测试组合固定为：

```text
高清 384×416 @ 12 FPS
高清 384×416 @ 20 FPS
超清 768×832 @ 12 FPS
超清 768×832 @ 20 FPS
原画 1536×1664 @ 12 FPS
原画 1536×1664 @ 20 FPS
```

验收指标：

```text
高清 12 FPS CPU ≤ 4%
超清 20 FPS Renderer 内存 ≤ 260 MB
原画 20 FPS Renderer 内存 ≤ 420 MB
页面切换无明显卡顿
```

---

## 6. M3：宠物 Studio AI 会话

### 6.1 新建表单

任务：

1. 实现宠物描述输入。
2. 实现风格预设选择。
3. 实现图像画质选择。
4. 实现参考图上传。
5. 实现开始生成按钮。
6. 实现 generation job 创建。

风格固定为：

```text
写实
半写实
现代
像素
动漫
不指定
```

画质固定为：

```text
标清 192×208
高清 384×416
超清 768×832
原画 1536×1664
```

验收：

```text
表单校验正常
参考图可加入 job 目录
点击开始生成后进入 AI 会话页
job 状态写入 SQLite
```

### 6.2 AI 会话窗口

任务：

1. 实现 Studio 会话消息流。
2. 实现用户输入。
3. 实现生成进度展示。
4. 实现错误提示。
5. 实现 job 状态订阅。
6. 实现生成完成后自动入库。

验收：

```text
用户能在会话中继续补充要求
AI 消息能流式显示
生成进度能更新
失败时显示可重试
完成后宠物出现在宠物库
```

### 6.3 Codex App Server 集成

任务：

1. 实现 app-server stdio client。
2. 实现会话启动。
3. 实现消息发送。
4. 实现事件流解析。
5. 实现会话取消。
6. 实现异常恢复。

验收：

```text
PetCore 能启动 Codex App Server
PetCore 能创建生成会话
Studio 能展示 streamed message
取消生成能终止对应进程
Codex 异常退出时 job 标记 failed
```

### 6.4 Pet Studio Skill

任务：

1. 编写 `agent-pet-studio/SKILL.md`。
2. 定义表单输入 contract。
3. 定义 brief 输出格式。
4. 定义 7 状态动作输出格式。
5. 定义图像帧命名规范。
6. 定义校验失败后的修复流程。
7. 接入 `petcore-cli petpack validate`。
8. 接入 `petcore-cli petpack build`。

验收：

```text
Skill 能基于表单生成 brief
Skill 能生成 7 状态素材
Skill 能调用 petpack build
最终产物可被 App 播放
```

---

## 7. M4：多 Agent 连接

### 7.1 统一事件接收

任务：

1. 实现 `agent.ingest` JSON-RPC。
2. 实现 `POST /agent-events` HTTP endpoint。
3. 实现 event normalization。
4. 实现事件去重。
5. 实现事件到宠物状态映射。
6. 实现行为配置过滤。

验收：

```text
任意来源事件都能写入 agent_events
同一事件重复发送不会重复触发动作
关闭的来源不会触发动作
关闭的事件类型不会触发动作
```

### 7.2 Codex 连接

任务：

1. 生成 Codex plugin 目录。
2. 写入 `.codex-plugin/plugin.json`。
3. 写入 `hooks/hooks.json`。
4. 安装 `agent-pet-studio` skill。
5. 实现连接检查。
6. 实现一键修复。
7. 实现 hook 信任状态提示。

验收：

```text
Codex CLI 检测正常
plugin 可安装
hooks 可触发 start/tool/waiting/done/failed
未信任 hooks 时 Agent 连接页显示需修复
```

### 7.3 Claude Code 连接

任务：

1. 检测 Claude Code CLI。
2. 写入 `~/.claude/settings.json` hook 配置。
3. 实现 hook command。
4. 实现连接测试。
5. 实现卸载。

验收：

```text
UserPromptSubmit 能触发 start
PreToolUse 能触发 tool
PermissionRequest 能触发 waiting
Stop 能触发 done 或 review
StopFailure 能触发 failed
```

### 7.4 Pi Coding Agent 连接

任务：

1. 检测 Pi CLI。
2. 安装 extension 到 `~/.pi/agent/extensions/`。
3. 实现 extension 事件监听。
4. 实现 RPC 启动检查。
5. 实现连接测试。
6. 实现卸载。

验收：

```text
Pi extension 可被加载
turn_start 触发 start
tool_execution_start 触发 tool
tool_execution_end 正常结束
agent_end 触发 done
extension_error 触发 failed
```

### 7.5 OpenCode 连接

任务：

1. 检测 OpenCode CLI。
2. 安装 OpenCode plugin。
3. 实现 plugin 事件发送。
4. 实现连接测试。
5. 实现卸载。

验收：

```text
OpenCode plugin 可被加载
session start 触发 start
tool event 触发 tool
permission event 触发 waiting
session finish 触发 done
error 触发 failed
```

---

## 8. M5：宠物库与启用行为

### 8.1 宠物库

任务：

1. 实现宠物卡片列表。
2. 实现当前启用标记。
3. 实现启用宠物。
4. 实现删除宠物。
5. 实现宠物详情基础信息。
6. 实现生成历史跳转。

验收：

```text
新建完成后自动出现在宠物库
点击启用后悬浮层切换宠物
删除当前宠物前要求切换或确认
宠物库只展示用户历史制作的宠物
```

### 8.2 启用与行为

任务：

1. 实现总开关。
2. 实现鼠标穿透开关。
3. 实现自动收起开关。
4. 实现 12 FPS / 20 FPS 切换。
5. 实现响应来源开关。
6. 实现响应事件开关。
7. 实现设置即时生效。

响应来源固定：

```text
Codex
Claude Code
Pi Coding Agent
OpenCode
```

响应事件固定：

```text
开始处理
执行工具
等待确认
待查看
完成
失败
```

验收：

```text
关闭总开关后桌宠隐藏且不播放
关闭某来源后该来源事件不触发动作
关闭某事件后该事件不触发动作
帧率切换后下一轮动画生效
设置重启后保持
```

---

## 9. M6：性能、稳定性、安全检查

### 9.1 性能测试

任务：

1. 制作四档分辨率测试宠物。
2. 测试 12 FPS 与 20 FPS。
3. 测试状态频繁切换。
4. 测试原画环形缓存。
5. 测试主界面滚动和切页。
6. 测试外接显示器与缩放。

验收：

```text
性能达到技术方案预算
状态切换不闪烁
原画档内存不超过预算
多显示器拖动位置正确保存
```

### 9.2 稳定性测试

任务：

1. PetCore 崩溃自动恢复。
2. App 重启恢复 active pet。
3. generation job 中断恢复为 failed。
4. Agent hook 连续事件压测。
5. HTTP token 过期重建。
6. SQLite 损坏备份与重建。

验收：

```text
PetCore 异常退出后 App 能提示并重启
生成失败不会产生半成品 active pet
事件风暴不会卡住 UI
SQLite 损坏时能保留 petpack 文件
```

### 9.3 安全检查

任务：

1. 检查不读取 auth/token/cookie/API Key。
2. 检查 HTTP endpoint 只监听 127.0.0.1。
3. 检查 token 文件权限为 0600。
4. 检查 hook/plugin/extension 安装路径展示。
5. 检查一键卸载。
6. 检查日志脱敏。

验收：

```text
未授权请求不能写入事件
日志不包含用户 token
卸载后所有 agent 连接配置被移除
```

---

## 10. V1 可用性验收

最终验收清单：

```text
1. App 可在开发环境启动并完成初始化。
2. 桌宠可显示、拖动、右下角缩放。
3. 宠物 Studio 可通过表单发起 AI 会话。
4. AI 会话可生成 petpack。
5. 新宠物自动进入宠物库。
6. 宠物库可启用新宠物。
7. 启用与行为配置即时生效。
8. Codex 事件可触发宠物动作。
9. Claude Code 事件可触发宠物动作。
10. Pi Coding Agent 事件可触发宠物动作。
11. OpenCode 事件可触发宠物动作。
12. 原画 20 FPS 不超过内存预算。
13. App 不读取任何 Agent 认证文件。
14. 所有连接配置可一键卸载。
```

## 11. 关键风险与处理

| 风险 | 处理方式 |
|---|---|
| 原画档资源占用高 | 环形缓存、只缓存当前状态、跳帧保护 |
| AI 生成帧一致性差 | Skill 中加入角色 brief、状态约束、校验失败自动修复 |
| Agent hooks 配置变更 | 连接页做版本化检查和一键重写 |
| Codex App Server 协议变化 | app-server client 独立模块封装，升级只改 adapter |
| OpenCode/Pi 事件字段差异 | 所有来源先 normalize 到 AgentEvent |
| macOS 悬浮窗抢焦点 | 使用 non-activating NSPanel，交互区单独控制 |
| 用户误删宠物文件 | petpack 统一保存在 App 支持目录，SQLite 可重建索引 |

---

## 12. 开发顺序约束

必须按以下顺序开发：

```text
PetCore 基础
→ macOS Shell
→ petpack
→ Renderer
→ 宠物 Studio AI 会话
→ Agent 连接
→ 行为配置
→ 性能与稳定性验证
```

原因：

1. Renderer 依赖 petpack schema。
2. 宠物 Studio 生成结果依赖 petpack build。
3. Agent 事件触发依赖 Renderer 状态切换。
4. 行为配置依赖统一事件模型。
5. 性能测试必须在真实 Renderer 和真实 petpack 完成后进行。

---

## 13. 当前实现状态（2026-07-07）

当前仓库已经落地本地 V1 开发验证版本：

```text
SwiftPM macOS App: apps/macos
Rust workspace: crates/petcore, crates/petcore-cli, crates/petcore-types
Schemas: schemas/petpack.schema.json, schemas/agent-hook-input.schema.json, schemas/agent-event-ingest.schema.json, schemas/agent-event.schema.json
Pet Studio Skill: skills/agent-pet-studio/SKILL.md
Run entrypoint: script/build_and_run.sh
Phase validations: script/validate_m0.sh ... script/validate_m6.sh
Acceptance/security/stress validations: script/validate_v1.sh, script/validate_security_boundaries.sh, script/validate_event_storm.sh
Runtime validations: script/build_and_run.sh --verify, script/validate_app_bundle.sh, script/validate_overlay_runtime.sh, script/validate_overlay_interaction.sh, script/validate_overlay_scale_persistence.sh, script/validate_app_recovery.sh
Real environment validations: script/validate_real_agent_connectors.sh, script/validate_real_app_server.sh
Full validation entrypoint and profile guide: script/test_all.sh, script/validate_profiles.md
```

当前验证通过：

```text
./script/test_all.sh
./script/build_and_run.sh --verify
```

当前实现说明：

1. macOS App 使用 SwiftPM 构建并由脚本打包为 `.app`，不是 Xcode project。
2. PetCore 通过 Unix Domain Socket JSON-RPC 与 App/CLI 通信，并提供 127.0.0.1 HTTP event endpoint。
3. AI 生成流程已具备 generation job、会话消息、petpack build/import 和宠物库入库路径。
4. 未配置 `CODEX_APP_SERVER_CMD` 且未发现 `codex app-server` 时，Codex App Server probe 会报告不可用并给出 action/skip reason；只有显式设置 `APC_ALLOW_LOCAL_PET_STUDIO_FALLBACK=1` 的开发验证环境才允许本地 Pet Studio runner 继续打包。
5. Renderer 当前验证 Metal-backed view、frame scheduler、预算计算、悬浮层缩放和状态响应；后续生产级纹理缓存可在该边界内替换。
6. 四类 Agent 连接当前生成本地连接模板并验证事件归一化、去重、来源/事件过滤；真实第三方 CLI/hook 信任状态依赖用户环境。
