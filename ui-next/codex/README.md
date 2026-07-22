# UI Next / Codex 交付索引

主规格文档：[`UI-NEXT-SPEC.md`](UI-NEXT-SPEC.md)

当前方案版本为 1.1：Sidebar 与 Toolbar 已统一为原生 macOS source-list/分组控件语言；“服务与诊断”已迁移为第五个一级入口，宠物配置只保留两个子项。

## 内容

- `mockups/`：14 张已渲染、已逐屏检查的 UI 示意图。
- `source/mockups.html`、`source/mockups.css`：示意图的确定性源文件。
- `source/render_mockups.cjs`：使用 Playwright 批量重渲染示意图。
- `assets/desktop-wallpaper.png`：只用于展示桌宠玻璃层对不同桌面背景的适应性。
- `assets/brand-mark.png`：来自 App 当前品牌资源的工作副本。
- `assets/bytebud/`、`assets/xingwu/`：从仓库内置 `.petpack` 提取的预览/状态帧，仅用于本项目方案图。

## 重渲染

在仓库根目录运行：

```bash
CODEX_NODE_MODULES=/Users/zyq/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules \
CHROMIUM_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
/Users/zyq/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node \
ui-next/codex/source/render_mockups.cjs
```

如果本机 `playwright` 与 Chromium 已在默认路径，可省略两个环境变量并直接运行脚本。输出会覆盖 `mockups/` 中同名 PNG。

## 生成背景的来源

`assets/desktop-wallpaper.png` 通过 Codex 内置 ImageGen 生成并保存到项目目录。最终提示词如下：

```text
Use case: stylized-concept
Asset type: background context for a macOS desktop-pet UI mockup
Primary request: create a restrained abstract desktop wallpaper that can sit behind translucent native Liquid Glass controls
Scene/backdrop: a calm edge-to-edge 16:10 wallpaper with deep ink-blue, soft graphite, muted periwinkle and a small amount of warm coral light; broad atmospheric gradient and two or three very soft aurora-like translucent shapes
Style/medium: premium minimal digital gradient artwork, refined and quiet, suitable for a modern native macOS desktop
Composition/framing: landscape, balanced, no focal object, keep the center and lower-right sufficiently calm so glass UI remains readable
Lighting/mood: subtle luminous depth, calm, productive, sophisticated
Constraints: no text, no letters, no logos, no Apple marks, no icons, no windows, no UI components, no people, no pets, no watermark; low visual noise; avoid banding and hard edges
```

背景不是产品资产提案，也不应打包进 App；它只是让桌宠气泡在复杂明暗背景上的对比策略可被评审。

## 使用规则

- 示意图定义信息层级、布局关系、组件类型和交互意图，不是让工程实现 Web/CSS 外观。
- 最终实现优先使用 SwiftUI/AppKit 系统组件与系统 Liquid Glass。
- 当前 `images/app` 和 `images/pet` 只作为功能清单，不得作为样式或布局模板。
