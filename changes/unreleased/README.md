# Unreleased changelog fragments / 未发布变更片段

Every direct, task, and train development PR records each user-visible change as a globally unique `<id>.json` fragment here. Ordinary development leaves root `CHANGELOG.md` untouched. Only an explicit release-preparation branch may freeze and consume the fragments. See [changelog and integration](../../docs/development/parallel-development.md#changelog-and-final-train-integration--变更日志与-train-收口) for commands and [macOS release](../../docs/release/macos-release.md) for the version/tag/Release contract. / 所有 direct、task 与 train 开发 PR 均在此以全局唯一的 `<id>.json` 记录用户可见变化，普通开发不修改根 `CHANGELOG.md`。仅显式发布准备分支可冻结并汇总片段；命令和版本、tag、Release 契约见上述文档。

```json
{
  "schema_version": "apc.changelog-fragment.v1",
  "kind": "Changed",
  "scope": "overlay",
  "summary_en": "Desktop bubbles keep the newest Agent reply.",
  "summary_zh": "桌面气泡保留最新的 Agent 回复。"
}
```
