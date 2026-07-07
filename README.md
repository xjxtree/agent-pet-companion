# Agent Pet Companion

[中文](README.zh-CN.md) | English

Agent Pet Companion is a native macOS desktop pet app for people who work with coding agents. Create a high-quality AI pet, place it on your desktop, and let it react to what your agents are doing.

The project is open source and currently in early development. A public installable release is not available yet.

## What It Does

- Creates personalized desktop pets from your description, style preference, image quality choice, and optional reference images.
- Displays a high-quality floating pet overlay on macOS.
- Lets the pet react to coding-agent activity such as thinking, tool execution, waiting for confirmation, review needed, completion, and failure.
- Keeps pets in a local library so you can enable, remove, inspect, or export them.
- Provides connection checks for Codex, Claude Code, Pi Coding Agent, and OpenCode.

## Core Features

### Pet Studio

Start from a short form, then continue in an AI conversation to refine the pet's look, motion, and behavior. Generated pets are saved as local `.petpack` files and appear in your pet library.

### Desktop Overlay

The pet appears as a floating macOS overlay. You can drag it around, resize it from the bottom-right handle, and open a quick menu from the pet itself.

### Agent Reactions

Agent Pet Companion listens to supported local agent event channels and maps agent states to pet animations:

- Started work: thinking
- Running tools: working
- Waiting for confirmation: waiting
- Needs review: review
- Completed: done
- Failed: failed

### Local Pet Library

Your generated pets stay on your Mac. The library is designed for enabling a pet, checking its asset information, deleting local pets, and exporting `.petpack` files.

## Supported Platforms

- macOS
- Apple Silicon is the primary performance target for V1

Windows, cloud accounts, public pet sharing, and public asset galleries are not part of the initial release scope.

## Installation

No public build is available yet.

When the first release is ready, installation will be provided through GitHub Releases:

1. Download the signed macOS release package.
2. Move Agent Pet Companion to `Applications`.
3. Open the app and follow the in-app connection checks.

Source builds will be documented after the macOS app and local service are implemented.

## Basic Usage

1. Open Agent Pet Companion.
2. Go to Pet Studio and describe the pet you want.
3. Choose a style preset, image quality, and optional reference image.
4. Start the AI session and refine the pet through conversation.
5. Enable the generated pet from the local library.
6. Use Agent Connections to check Codex, Claude Code, Pi Coding Agent, or OpenCode integration.
7. Keep the pet on your desktop while you work with supported agents.

## Privacy And Safety

Agent Pet Companion is designed as a local-first app. It should not read agent auth files, tokens, cookies, API keys, or other secrets. Agent reactions are based on explicit local event channels and project-owned capability tokens.

## License

Agent Pet Companion is released under the [MIT License](LICENSE).
