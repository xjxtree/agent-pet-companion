## Development lane / 开发通道

- Lane / 通道: `direct-to-main` / `task-to-train` / `train-to-main`
- Base branch / 目标分支:
- Active train / 所属 train: `n/a` or `gd-ops/train/<name>`
- Owning Agent/session / 写入负责人:

## Scope and dependencies / 范围与依赖

- Owned paths / 独占修改路径:
- Shared files and coordinator / 共享文件及协调者:
- Depends on / 依赖 PR:
- Blocks / 阻塞 PR:

## Change / 改动

Describe the behavior and contract change. Task PRs to a train add one `changes/unreleased/*.json` fragment for each user-visible change. Direct or ready train PRs to `main` must have consumed all fragments into root `CHANGELOG.md`. / 描述行为与合同变化。进入 train 的任务 PR 应为每项用户可见变化添加一个 `changes/unreleased/*.json`；直接进入 `main` 或已 ready 的 train PR 必须将片段全部汇总进根 `CHANGELOG.md`。

## Validation / 验证

- Local fast gate:
- Focused checks:
- Environment-dependent gates skipped:
- Visible UI evidence, when applicable:

## Risk / 风险

- Privacy/security:
- Migration/compatibility:
- Performance/accessibility:
- Release/version impact:
