# Agent Pet Companion

中文 | [English](README.md)

Agent Pet Companion 是一款面向编码 Agent 用户的 macOS 原生桌宠 App。你可以用 AI 创建高画质个性化桌宠，把它放在桌面上，并让它响应 Agent 的工作状态。

本项目已开源，目前处于早期开发阶段，暂未提供可安装的公开版本。

## 产品简介

- 根据描述、风格偏好、图像画质和可选参考图创建个性化桌宠。
- 在 macOS 桌面上显示高画质悬浮桌宠。
- 让桌宠响应 Agent 的思考、执行工具、等待确认、待查看、完成、失败等状态。
- 本地保存宠物库，支持启用、删除、查看资源信息和导出。
- 提供 Codex、Claude Code、Pi Coding Agent、OpenCode 的连接检查。

## 功能与能力

### 宠物 Studio

从一个简单表单开始，通过 AI 会话继续调整宠物的外观、动作和行为。生成完成后，宠物会保存为本地 `.petpack` 文件，并出现在宠物库中。

### 桌面悬浮层

桌宠会以 macOS 悬浮层形式出现在桌面。你可以拖动它的位置，通过右下角缩放手柄调整大小，也可以点击桌宠打开快捷菜单。

### Agent 状态响应

Agent Pet Companion 会监听受支持的本地 Agent 事件通道，并把 Agent 状态映射为桌宠动作：

- 开始处理：thinking
- 执行工具：working
- 等待确认：waiting
- 待查看：review
- 完成：done
- 失败：failed

### 本地宠物库

你创建的宠物会保存在本机。宠物库用于启用宠物、查看资源信息、删除本地宠物，以及导出 `.petpack` 文件。

## 支持平台

- macOS
- V1 优先面向 Apple Silicon Mac 优化

Windows、云端账号、公共宠物分享和公共素材库不在首个版本范围内。

## 安装

当前暂未发布可安装版本。

首个版本完成后，将通过 GitHub Releases 提供安装包：

1. 下载签名后的 macOS 安装包。
2. 将 Agent Pet Companion 移动到 `Applications`。
3. 打开 App，并按应用内的连接检查完成配置。

源码构建方式会在 macOS App 和本地服务实现后补充。

## 使用方式

1. 打开 Agent Pet Companion。
2. 进入宠物 Studio，描述你想要的桌宠。
3. 选择风格预设、图像画质，并按需上传参考图。
4. 发起 AI 会话，通过对话继续调整宠物。
5. 在本地宠物库中启用生成好的宠物。
6. 进入 Agent 连接，检查 Codex、Claude Code、Pi Coding Agent 或 OpenCode 集成。
7. 在使用受支持 Agent 工作时，让桌宠停留在桌面并响应状态变化。

## 隐私与安全

Agent Pet Companion 以本地优先为设计原则。应用不应读取 Agent 的 auth、token、cookie、API Key 或其他密钥文件。Agent 响应基于明确的本地事件通道和项目自有的能力令牌。

## 开源协议

Agent Pet Companion 使用 [MIT License](LICENSE) 开源。
