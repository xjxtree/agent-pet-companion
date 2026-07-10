# Agent Pet Companion 最终验证记录

> 日期：2026-07-10
> 分支：`codex/project-audit-remediation`
> 应用：[AgentPetCompanion.app](../../../dist/AgentPetCompanion.app)
> 完整账本：[REPORT.md](REPORT.md)

## 1. 最终结论

- 审查确认 54 个问题：P1 17、P2 28、P3 9。
- 最终状态：48 `FIXED`、6 `MITIGATED`、0 `OPEN`、0 `DEFERRED`。
- 12 个结构性优化项全部 `DONE`。
- 6 个 `MITIGATED` 只涉及需要用户明确授权的真实 Codex/Claude Code/Pi/OpenCode 或真实 Codex App Server 验收；本地代码、严格边界、官方形状 fixture、模拟 runtime 和失败降级均已完成。
- 审查和验证没有读取 auth、token、cookie、API key 或 secret 文件，也没有修改用户真实 Agent 配置。

## 2. Fresh 验证矩阵

| 门禁 | 命令/入口 | 结果 |
|---|---|---:|
| Rust 格式 | `cargo fmt --all -- --check` | PASS |
| Rust lint | `cargo clippy --workspace --all-targets --locked -- -D warnings` | PASS |
| Rust 全量测试 | `cargo test --workspace --locked -- --test-threads=1` | PASS |
| Swift Testing | `swift test --enable-swift-testing`，附 CommandLineTools Testing framework flags | PASS，57/57、8 suites |
| 默认无副作用回归 | `APC_VALIDATE_HOST_UI=0 APC_VALIDATE_OVERLAY_RUNTIME=0 APC_VALIDATE_OVERLAY_INTERACTION=0 APC_VALIDATE_REAL_AGENT_CONNECTORS=0 APC_VALIDATE_REAL_APP_SERVER=0 ./script/test_all.sh` | PASS |
| app bundle / launch | `APC_VALIDATE_HOST_UI=1 ./script/build_and_run.sh --verify` | PASS |
| 主窗口 AX/UI | `APC_VALIDATE_HOST_UI=1 ./script/validate_main_window_ui.sh` | PASS |
| Overlay 非鼠标 | `APC_VALIDATE_HOST_UI=1 ./script/validate_overlay_non_mouse.sh` | PASS |
| Overlay 交互 | `APC_VALIDATE_HOST_UI=1 APC_VALIDATE_OVERLAY_INTERACTION=1 ./script/validate_overlay_interaction.sh` | PASS |
| 缩放持久化 | `APC_VALIDATE_HOST_UI=1 ./script/validate_overlay_scale_persistence.sh` | PASS |
| daemon 恢复 | `APC_VALIDATE_HOST_UI=1 ./script/validate_app_recovery.sh` | PASS |
| Renderer 实测 | `APC_VALIDATE_HOST_UI=1 ./script/validate_renderer_runtime_budget.sh` | PASS |
| RustSec | `cargo audit --deny warnings` | PASS，159 dependencies、0 vulnerabilities |
| Diff 卫生 | `git diff --check` | PASS |

默认 `test_all.sh` fresh run 覆盖 Schema 正反例、source/shell/build-script safety、M0–M6、模拟 connector runtime、180-event storm、V1 场景、安全边界、离线 Overlay/UI contract 和开发包打包。真实 Agent 与真实 App Server gate 均按预期输出明确 skip 原因。

## 3. 关键回归证据

| 子系统 | 代表性通过项 |
|---|---|
| Pet revision / petpack | `petpack_import_atomic` 12/12；`petpack_import_routing` 3/3；`petpack_resource_limits` 10/10；`reference_image_policy` 4/4 |
| daemon / RPC / security | `daemon_lifecycle` 25/25；`daemon_http_security` 4/4；`schema_fixtures` 3/3 |
| Event privacy | `event_envelope_security` 15/15；legacy scrub、retention、source/session dedupe、strict ingress 全部通过 |
| Generation | `generation_recovery` 8/8；`generation_lifecycle` 4/4；`generation_jsonl_recovery` 4/4；`app_server_transport` 2/2 |
| Agent contracts / processes | `connector_contracts` 4/4；`process_runner` 6/6；Claude surgical uninstall 和 official payload fixtures 通过 |
| macOS | Swift 57/57；UI validation 7/7；主窗口、Overlay、缩放、恢复实机脚本全部通过 |

## 4. Renderer 30 秒实测

每种状态使用 61 个样本、0.5 秒间隔；CPU 使用累计进程 CPU time delta，内存使用 active RSS peak 减隐藏 Overlay RSS median，并同时硬断言应用内 decoded cache、drawable texture 与 Metal device allocation。

| 场景 | CPU 平均 | CPU 预算 | 观察 FPS | 最低 FPS | RSS 峰值增量 | 内存预算 |
|---|---:|---:|---:|---:|---:|---:|
| 隐藏 Overlay | 0.10% | idle gate | — | — | 基线 RSS median 135.38 MiB | — |
| high / standard | 2.50% | 4% | 12.00 | 10.8 | 21.08 MiB | 180 MiB |
| ultra / smooth | 3.27% | 7% | 19.99 | 18 | 57.69 MiB | 260 MiB |
| original / smooth | 3.60% | 9% | 20.04 | 18 | 247.58 MiB | 420 MiB |

三档 `actual_draw_count`、decoded cache、drawable 和 Metal 分配均为非零，`draw_reads_disk=false`；original 使用 bounded ring source，其余为 eager source。

## 5. 视觉与交互复审

Fresh 截图由真实 bundle、隔离 `APC_HOME` 和 AX 导航生成，并输出为无 alpha 的 RGB PNG。每组都将原始基线与修复版按同视口并排后审查。

- [Pet Studio 窄视口对照](comparisons/01-pet-studio-new-before-after.png)
- [Pet Studio 宽视口对照](comparisons/02-pet-studio-new-wide-before-after.png)
- [Pet Library 对照](comparisons/03-pet-library-before-after.png)
- [Enable & Behavior 对照](comparisons/04-enable-behavior-before-after.png)
- [Agent Connections 对照](comparisons/05-agent-connections-before-after.png)
- [Overlay 折叠对照](comparisons/06-overlay-collapsed-before-after.png)
- [Overlay 放大对照](comparisons/07-overlay-large-before-after.png)
- [AI 会话失败/重试对照](comparisons/08-ai-session-before-after.png)

最终视觉结论：同一页面不再中英混排；选择状态不只依赖颜色；Library 不再把长验证说明塞入徽章，也不再虚报资源完整；Studio 根据真实容器宽度维持双列；Connections 顶对齐；Overlay 两档尺寸、上下气泡与短气泡均在可见交互边界内；失败态提供明确重试。

## 6. 有界外部条件

| 范围 | 本地结论 | 需要的外部条件 |
|---|---|---|
| P1-014 真实 App Server 生成 | preview/full source gate、完整 petpack 验证和诚实失败均已完成 | 用户明确授权真实 App Server 后运行 `APC_VALIDATE_REAL_APP_SERVER=1 ./script/validate_real_app_server.sh` |
| P1-016 / P1-017 / P2-024 / P2-025 / P2-027 | 四类 Agent 官方形状 fixture、模拟 runtime、安装/检查/卸载逻辑通过 | 用户明确授权改写/加载其真实 connector 配置后运行 `APC_VALIDATE_REAL_AGENT_CONNECTORS=1 ./script/validate_real_agent_connectors.sh` |
| distributable macOS Release | universal/sign/notarize/staple/Gatekeeper 脚本和前置失败检查已完成 | 完整 Xcode、Developer ID Application identity、notary profile 和发布操作者授权 |

## 7. 工作区说明

审查开始前工作区已有大量未提交改动；本轮没有回退、覆盖或擅自提交这些用户改动。所有新验证使用临时 home、唯一 runtime marker 和 owned PID/start identity 清理，不依赖 broad process-name kill。
