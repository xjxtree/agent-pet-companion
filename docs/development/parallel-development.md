# Parallel Development and Protected Delivery / 并行开发与受保护交付

`main` is read-only for local development. Every change is delivered by a pull request through one of two lanes; the executing Agent chooses the smallest safe lane from current scope and coordination needs. / 本地开发不得直接写入 `main`。所有变更通过以下两类 PR 交付；执行 Agent 根据当前范围与协调需求选择最小且安全的通道。

## Lane selection / 通道选择

| Situation / 场景 | Lane / 通道 | PR chain / PR 链路 |
|---|---|---|
| Hotfix or small isolated update / 热修复或小型独立更新 | Direct | `gd-ops/fix/*` or `gd-ops/task/*` → `main` |
| Multiple Agents/sessions, cross-component feature, or an active shared train / 多 Agent/会话、跨组件功能或已有共享 train | Train | task/fix branches → `gd-ops/train/*` → `main` |

`./script/development_flow.py decide` makes the same default decision mechanically. An explicit `--lane direct|train` is allowed when the Agent has stronger task evidence. Hotfix is the only automatic direct override while a train exists; ordinary sub-Agent work joins the main Agent's active train. / `decide` 命令可机械执行同一默认决策；Agent 有更充分证据时可显式指定通道。已有 train 时，只有 hotfix 会自动改走 direct，普通子 Agent 工作均加入主 Agent 的活动 train。

## Branch and worktree ownership / 分支与 worktree 所有权

- Branches use `gd-ops/train/<name>`, `gd-ops/task/<task>-<slug>`, or `gd-ops/fix/<task>-<slug>`. / 分支使用上述固定命名。
- Every Agent/session gets an independent branch and worktree. One Agent is the sole writer for each owned path at a time. / 每个 Agent/会话使用独立分支和 worktree；同一路径同一时刻只有一个写入者。
- The main Agent owns train creation, dependency order, shared schemas/manifests/version files, changelog consolidation, the final train PR, and conflict resolution. / 主 Agent 负责 train 创建、依赖顺序、共享 schema/manifest/版本文件、变更日志汇总、最终 train PR 与冲突处理。
- Sub-Agents never commit directly into another Agent's branch or the train branch. Their unit of handoff is a task PR. / 子 Agent 不直接写入其他 Agent 分支或 train 分支；任务 PR 是唯一交接单元。

The coordinator starts one shared train and task worktrees from explicit remote bases. Commands are plans unless `--apply` is present; shared state lives under Git's common directory so all worktrees see the same active train. / 协调者从明确的远端基线创建一个共享 train 和各任务 worktree。未给出 `--apply` 时命令只输出计划；共享状态位于 Git common directory，因此全部 worktree 能看到同一活动 train。

```bash
./script/development_flow.py train-start \
  --name feature-set \
  --worktree ../apc-train-feature-set

./script/development_flow.py train-start \
  --name feature-set \
  --worktree ../apc-train-feature-set \
  --apply

./script/development_flow.py task-start \
  --task 123 \
  --slug pi-bubble \
  --agents 3 \
  --worktree ../apc-task-123-pi-bubble \
  --apply
```

For direct work, pass `--hotfix` or `--small`; for an explicit train, pass `--lane train --train gd-ops/train/<name>`. The tool rejects missing train coordination, branch collisions, dirty PR worktrees, and unmanaged PR heads. / direct 工作使用 `--hotfix` 或 `--small`；显式 train 使用 `--lane train --train ...`。工具会拒绝缺少 train 协调、分支冲突、PR worktree 不干净及非受管 PR head。

## PR lifecycle and CI / PR 生命周期与 CI

Task PRs start as drafts unless the Agent explicitly marks them ready. A ready PR created by the helper is pushed and opened against its recorded base. After its CI workflow succeeds, the trusted post-CI merger independently resolves the exact same-repository PR and head commit, verifies its run/attempt-bound merge ticket, tested merge parents, lane proof, and active PR/`Required CI` rules, then squash-merges. It checks out only the trusted `main` verifier, never pull-request code. / 任务 PR 默认以 draft 创建。Agent 显式标记 ready 后，辅助工具会推送并按记录基线创建 PR。其 CI workflow 成功后，受信任的 CI 后合并器会独立解析精确的同仓库 PR 与 head commit，校验绑定 run/attempt 的 merge ticket、测试合并父提交、通道证明以及有效的 PR/`Required CI` 规则，再执行 squash 合并；它只 checkout 受信任的 `main` 验证器，绝不 checkout 或执行 PR 代码。

PRs that change the CI/Release/merge/proof/ruleset control-plane inventory are intentionally excluded from privileged auto-merge because their own workflow cannot be allowed to prove itself. They still run PR CI, but require a trusted manual squash merge; that human-authored merge produces the ordinary protected `main` push CI. / 修改 CI、Release、合并器、证明或 ruleset 控制面清单的 PR 会被明确排除在特权自动合并之外，因为不能允许 PR 自己修改并证明自身 workflow。此类 PR 仍运行 PR CI，但需要受信任人工执行 squash 合并；该人工合并会产生普通的受保护 `main` push CI。

```bash
./script/development_flow.py pr-open \
  --worktree ../apc-task-123-pi-bubble \
  --title "Optimize Pi session bubbles" \
  --ready \
  --apply
```

- Ready direct and train PRs to `main` run the complete source, integration, Rust, Swift, stress, bundle, and stable `Required CI` gate. They auto-merge only after every required result succeeds and the branch remains mergeable. / 所有 ready 的 direct/train → `main` PR 均运行完整门禁，仅在全部必选结果成功且仍可合并时自动合并。
- Task PRs to a train run path-scoped CI and auto-merge independently. Train status checks are intentionally non-strict so unrelated completed task PRs do not continuously invalidate each other. / task → train PR 按路径运行 CI 并独立自动合并；train 检查刻意使用 non-strict，避免无关任务互相持续失效。
- A successful direct or final train PR records a bounded candidate proof for its tested merge tree. After squash merge, the trusted merger explicitly dispatches CI for the exact new `main` SHA because GitHub suppresses ordinary follow-on workflow events created with `GITHUB_TOKEN`. That main validation reuses the proof only when the same-repository PR, successful `Required CI`, merge parents, artifact, and exact Git tree all match; it then issues the main-bound Release proof without repeating the complete suites. Any missing, expired, ambiguous, or mismatched evidence automatically falls back to the complete main CI. / direct PR 或最终 train PR 成功后会为其已测试合并树记录有界候选证明。squash 合并后，受信任合并器会为新的精确 `main` SHA 显式派发 CI，因为 GitHub 会抑制由 `GITHUB_TOKEN` 产生的普通后续 workflow 事件。该 main 验证只有在同仓库 PR、成功的 `Required CI`、合并父提交、artifact 与精确 Git tree 全部匹配时才复用证明，并直接签发绑定 main 的 Release 证明而不重复全量测试；任何缺失、过期、歧义或不匹配都会自动回退完整 main CI。
- A task PR merged into a train has no post-merge train-push CI and emits no Release candidate proof. The final train → `main` PR is the single complete integrated candidate, so train development remains path-scoped without weakening the final proof. / task PR 合入 train 后不触发 train push CI，也不生成 Release 候选证明；最终 train → `main` PR 才是唯一完整的集成候选，因此 train 开发保持按路径验证，同时不削弱最终证明。

## Changelog and final train integration / 变更日志与 train 收口

A train task PR adds one `changes/unreleased/*.json` fragment per user-visible change instead of editing the shared root changelog. Before the final train PR becomes ready, the coordinator consumes every fragment, resolves shared-file conflicts, and runs the local fast gate. Direct PRs update `[Unreleased]` directly and leave no fragments. / train 任务 PR 为每项用户可见变化添加一个 JSON 片段，不直接修改共享根变更日志。最终 train PR ready 前，协调者汇总所有片段、解决共享文件冲突并运行本地快速门禁；direct PR 直接更新 `[Unreleased]` 且不得遗留片段。

```bash
./script/changelog_fragments.py create \
  --id 123-pi-bubble \
  --kind Changed \
  --scope pi \
  --summary-en "Pi bubbles retain the newest Agent reply." \
  --summary-zh "Pi 气泡保留最新的 Agent 回复。" \
  --apply

./script/changelog_fragments.py consume --apply
./script/validate_pre_push.sh
```

After the train PR merges, the coordinator clears the active state with `train-clear --train ... --apply` and prunes only its owned worktrees. Branch deletion is performed by GitHub after merge. / train PR 合并后，协调者使用 `train-clear` 清除活动状态，并只清理自己拥有的 worktree；分支由 GitHub 在合并后删除。

## Protected branch activation / 受保护分支激活

Repository merge settings enable auto-merge, automatic merged-branch deletion, update-branch support, and squash-only history. The idempotent ruleset applicator protects `main` and `gd-ops/train/*`, but fails closed until the exact remote `main` commit has a successful trusted `Required CI` `push` or exact-SHA `workflow_dispatch` run. / 仓库设置启用自动合并、合并后自动删分支、更新分支和仅 squash 历史。幂等 ruleset 配置器保护 `main` 与 `gd-ops/train/*`，但在远端精确 `main` commit 尚无受信任成功 `Required CI` `push` 或精确 SHA 的 `workflow_dispatch` run 时会 fail closed。

```bash
./script/configure_main_branch_ruleset.py --settings-only --apply
./script/configure_main_branch_ruleset.py
./script/configure_main_branch_ruleset.py --apply
```
