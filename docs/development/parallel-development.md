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

`development/domains.json` is the typed ownership source for domain paths, dependencies, focused tests, CI flags, shared-path risk, and parallel sub-claims. Register the exact domain/claim before editing. Amber paths require explicit approval; Red paths additionally require the control-plane owner. `development_flow.py conflicts` compares active claims and merge trees so overlap is rejected before handoff instead of discovered during train integration. / `development/domains.json` 是领域路径、依赖、聚焦测试、CI 标记、共享路径风险和并行子声明的类型化所有权来源。编辑前必须登记精确 domain/claim；Amber 路径需显式批准，Red 路径还要求控制面 owner。冲突命令同时比较活动声明与 merge tree，使冲突在交接前被拒绝。

```bash
./script/development_domains.py validate
./script/development_flow.py branch-claim \
  --worktree /absolute/path/to/worktree \
  --domain agent-connections \
  --claim pi-adapter \
  --apply
./script/development_flow.py conflicts
./script/validate_local_tests.sh --plan-only
```

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

## Commit, push, and PR checklist / 提交、推送与 PR 检查清单

Every direct, task-to-train, and final train handoff uses the same explicit lifecycle. A changed file is not delivered merely because it exists in a worktree: it must be intentionally staged, committed, observed in a clean worktree, pushed, and represented by the expected PR head/base. / direct、task→train 与最终 train 的每次交付都必须执行同一套显式生命周期。文件只存在于 worktree 中不等于已经交付；它必须被明确暂存、提交，在干净 worktree 中复核，推送，并由预期 head/base 的 PR 承载。

1. Confirm that the current branch, recorded base, domain claim, approved shared paths, and changelog mode match the chosen lane. Inspect `git status --short` and the complete diff; do not mix another Agent's paths, generated output, credentials, `.env`, DerivedData, or temporary assets. / 确认当前分支、基线、领域声明、获批共享路径与变更日志模式符合通道；检查完整状态与 diff，不混入其他 Agent 路径、生成物、凭据或临时文件。
2. Run `git diff --check` and `./script/validate_pre_push.sh`. The fast local gate is required; the larger remote matrix remains authoritative. / 运行空白检查与本地快速门禁；本地快速门禁是必选项，远端大矩阵仍是权威结果。
3. Stage only the intended paths with an explicit `git add -- <paths...>`. `git add -A` is permitted only after the whole worktree has been deliberately confirmed as one scope. Audit the index with `git diff --cached --check`, `git diff --cached --stat`, and, when needed, the full cached diff. / 使用显式路径只暂存本次范围；仅在已明确确认整个 worktree 都属于同一范围时才可使用 `git add -A`，随后检查 index 的空白、统计与完整 diff。
4. Commit the staged change, then require `git status --short` to be empty. A successful commit with remaining modified or untracked files is an incomplete handoff and must not be pushed as complete. / 提交后必须确认 `git status --short` 为空；commit 成功但仍有修改或未跟踪文件，仍属于不完整交付，不能按已完成状态推送。
5. Use `development_flow.py pr-open ... --apply` (or an equivalent explicit push plus PR operation), then verify the remote branch SHA, PR head/base, draft/ready state, and CI run. The helper refuses a dirty PR worktree. / 使用辅助命令（或等价的显式 push + PR 操作），并复核远端 SHA、PR head/base、draft/ready 状态与 CI；辅助命令会拒绝脏 worktree。

```bash
git status --short
git diff --check
./script/validate_pre_push.sh
git add -- path/to/owned-file another/owned-file
git diff --cached --check
git diff --cached --stat
git commit -m "Describe the delivered change"
test -z "$(git status --porcelain)"

./script/development_flow.py pr-open \
  --worktree /absolute/path/to/owned-worktree \
  --title "Describe the delivered change" \
  --ready \
  --apply
```

## PR lifecycle and CI / PR 生命周期与 CI

Task PRs start as drafts unless the Agent explicitly marks them ready. A ready PR created by the helper is pushed and opened against its recorded base. After its CI workflow succeeds, the trusted post-CI merger independently resolves the exact same-repository PR and head commit, verifies its run/attempt-bound merge ticket, tested merge parents, lane proof, and active PR/`Required CI` rules, then squash-merges. It checks out only the trusted `main` verifier, never pull-request code. / 任务 PR 默认以 draft 创建。Agent 显式标记 ready 后，辅助工具会推送并按记录基线创建 PR。其 CI workflow 成功后，受信任的 CI 后合并器会独立解析精确的同仓库 PR 与 head commit，校验绑定 run/attempt 的 merge ticket、测试合并父提交、通道证明以及有效的 PR/`Required CI` 规则，再执行 squash 合并；它只 checkout 受信任的 `main` 验证器，绝不 checkout 或执行 PR 代码。

After it verifies the merged PR response, the trusted merger also removes the source ref for direct, task-to-train, and final train PRs. Exact-main validation dispatch happens first so cleanup cannot strand an already-merged commit without a Release proof. Repository automatic deletion remains enabled as the first convenience layer, but the workflow adds bounded cleanup: in the run that transitions the PR from open to merged, an existing ref is deleted with an atomic force-with-lease bound to the verified PR head SHA; an advanced ref fails closed. A closed-PR replay uses the PR-list response only to discover one closed candidate with `merged_at`, then requires the authoritative single-PR response to prove `merged == true`, the exact base/head identity, and the merge commit before recovery. Only an already-absent source ref succeeds on replay—any existing ref, including the same name recreated at the old SHA, is treated as reused and is never deleted. / 受信任合并器确认 PR 已合并后，还会清理 direct、task→train 与最终 train PR 的源 ref。精确 main 验证会先派发，避免清理失败让已合并 commit 永久缺少 Release 证明。仓库自动删除开关仍作为第一层便利机制；workflow 追加有界清理：仅在本次 run 将 PR 从 open 变为 merged 时，才会用绑定已验证 PR head SHA 的原子 force-with-lease 删除仍存在的 ref，ref 已推进则 fail closed。closed PR replay 只把 PR 列表中带 `merged_at` 的唯一 closed 候选用于发现，随后必须由权威单 PR 响应证明 `merged == true`、精确 base/head 身份与 merge commit 后才能恢复。replay 只接受源 ref 已不存在；任何仍存在的 ref（包括用旧 SHA 重建的同名分支）都视为已复用，绝不删除。

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

Every development lane adds one globally unique `changes/unreleased/*.json` fragment per user-visible change and leaves root `CHANGELOG.md` untouched. CI rejects duplicate IDs, malformed fragments, direct root-changelog edits, and development-time consumption. An explicit release-preparation branch freezes the complete fragment set, consumes it once, verifies the release section, and leaves no unconsumed fragment. / 所有开发通道均为每项用户可见变化添加全局唯一 JSON 片段，且不修改根变更日志。CI 会拒绝重复 ID、错误格式、开发阶段直接改根日志或提前汇总。显式 release-preparation 分支会冻结完整片段集、一次性汇总并验证版本段，最终不得残留未汇总片段。

```bash
./script/changelog_fragments.py create \
  --id 123-pi-bubble \
  --kind Changed \
  --scope pi \
  --summary-en "Pi bubbles retain the newest Agent reply." \
  --summary-zh "Pi 气泡保留最新的 Agent 回复。" \
  --apply

./script/changelog_fragments.py policy \
  --base-ref origin/main \
  --release-preparation false

# Release-preparation branch only, after the fragment freeze:
./script/changelog_fragments.py consume --apply
./script/validate_pre_push.sh
```

## Post-merge repository audit / 合并后的仓库清场审计

Automatic remote-branch deletion does not clean local worktrees or prove that every local change was delivered. After each direct merge, and once more after a train closes, the coordinator performs a repository-wide audit: / 远端自动删分支不会清理本地 worktree，也不能证明全部本地改动已经交付。每次 direct 合并后，以及 train 收口后，协调者都必须执行全仓审计：

1. Run `git fetch origin --prune`, verify the merged PR and exact `main` SHA, and confirm the remote source ref is absent. / 拉取并 prune，核验已合并 PR 与精确 main SHA，并确认远端源 ref 已不存在。
2. Enumerate every linked worktree with `git worktree list --porcelain`, then run `git status --short` in each path. Any modified or untracked path is unresolved work: preserve it, assign an owner, and deliver it through a PR; never remove or reset that worktree as cleanup. / 枚举每个 worktree 并逐一检查状态；存在修改或未跟踪文件即代表未解决工作，必须保留、分配 owner 并通过 PR 交付，不能以清理名义删除或 reset。
3. Inventory every local branch and open PR. For branches with an upstream, inspect unpushed commits; for branches whose remote was deleted after squash, use the merged PR record as the authority because the task commit is not an ancestor of the squash commit. A branch with no matching merged PR remains unresolved even if its worktree is clean. / 盘点全部本地分支与 open PR；有 upstream 的分支检查未推送 commit，squash 后远端已删的分支以 merged PR 记录为权威，因为任务 commit 不会成为 squash commit 的祖先；没有对应 merged PR 的分支即使 worktree 干净也仍未解决。
4. In one dedicated, clean main worktree only, fast-forward local `main` with `git merge --ff-only origin/main`. Never switch, reset, or overwrite a dirty feature worktree to update main. / 仅在专用且干净的 main worktree 中以 fast-forward 更新本地主分支；不得切换、reset 或覆盖脏的功能 worktree。
5. Remove only owned, clean worktrees whose PR is verified merged and whose remote source ref is absent; then remove their local ephemeral branches. After a train PR merges, also run `train-clear --train ... --apply`. Finish by repeating the all-worktree status, branch, PR, and remote-ref inventory. / 仅清理由本人拥有、状态干净、PR 已确认合并且远端 ref 已删除的 worktree，再删除对应本地临时分支；train 合并后还需清除活动 train 状态，最后再次盘点所有 worktree、分支、PR 与远端 ref。

```bash
git fetch origin --prune
git worktree list --porcelain
git branch -vv
gh pr list --state open --limit 100
gh pr view PR_NUMBER --json state,mergedAt,headRefName,baseRefName,mergeCommit

# Repeat for every path reported above.
git -C /absolute/path/to/worktree status --short

# Run only in a dedicated clean main worktree.
git switch main
git merge --ff-only origin/main

# Run only after the PR/ref/worktree checks above succeed.
git worktree remove /absolute/path/to/owned-clean-worktree
git branch -D gd-ops/task/verified-squash-merged-branch
./script/development_flow.py train-clear \
  --train gd-ops/train/feature-set \
  --apply
```

## Protected branch activation / 受保护分支激活

Repository merge settings enable auto-merge, automatic merged-branch deletion, update-branch support, and squash-only history. The idempotent ruleset applicator protects `main` and `gd-ops/train/*`, but fails closed until the exact remote `main` commit has a successful trusted `Required CI` `push` or exact-SHA `workflow_dispatch` run. / 仓库设置启用自动合并、合并后自动删分支、更新分支和仅 squash 历史。幂等 ruleset 配置器保护 `main` 与 `gd-ops/train/*`，但在远端精确 `main` commit 尚无受信任成功 `Required CI` `push` 或精确 SHA 的 `workflow_dispatch` run 时会 fail closed。

```bash
./script/configure_main_branch_ruleset.py --settings-only --apply
./script/configure_main_branch_ruleset.py
./script/configure_main_branch_ruleset.py --apply
```
