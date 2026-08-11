# Unreleased changelog fragments / 未发布变更片段

Train-based task PRs put one bounded JSON fragment here for every user-visible change. The train coordinator runs `./script/changelog_fragments.py consume --apply` before marking the train PR to `main` ready. Direct PRs to `main` update root `CHANGELOG.md` directly and must not leave a fragment. / 基于 train 的任务 PR 应为每项用户可见变化在此写入一个有界 JSON 片段；train 协调者在将面向 `main` 的 PR 标记为 ready 前运行 `./script/changelog_fragments.py consume --apply`。直接进入 `main` 的 PR 应直接更新根 `CHANGELOG.md`，不得遗留片段。

```json
{
  "schema_version": "apc.changelog-fragment.v1",
  "kind": "Changed",
  "scope": "overlay",
  "summary_en": "Desktop bubbles keep the newest Agent reply.",
  "summary_zh": "桌面气泡保留最新的 Agent 回复。"
}
```
