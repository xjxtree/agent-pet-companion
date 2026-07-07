---
name: agent-pet-studio
description: Generate Agent Pet Companion .petpack assets from the Studio form and validate them with petcore-cli.
---

# Agent Pet Studio

Use this skill only inside Agent Pet Companion generation jobs. The app owns the `.petpack` format; do not export Codex built-in pet packages, public gallery records, or sharing metadata.

## Input Contract

The host passes one JSON form:

```json
{
  "description": "自然语言外观、气质、动作要求",
  "style": "写实 | 半写实 | 现代 | 像素 | 动漫 | 不指定",
  "quality": "standard | high | ultra | original",
  "reference_images": ["/absolute/path/reference.png"],
  "note": "optional"
}
```

Quality maps to runtime frame size:

- `standard`: 192 x 208
- `high`: 384 x 416
- `ultra`: 768 x 832
- `original`: 1536 x 1664

## Required Output

Create a petpack source directory with:

```text
manifest.json
brief.json
assets/frames/idle/
assets/frames/start/
assets/frames/tool/
assets/frames/waiting/
assets/frames/review/
assets/frames/done/
assets/frames/failed/
assets/preview/cover.png
source/prompt.md
source/references/
source/skill_session.jsonl
build/validation.json
```

The seven state names are fixed: `idle`, `start`, `tool`, `waiting`, `review`, `done`, `failed`.

## Workflow

1. Read the form and reference images.
2. Ask follow-up questions in the Studio conversation only when required details are missing.
3. Write `brief.json` with character identity, style constraints, palette, motion notes, and quality.
4. Generate a consistent main image and all seven state motion concepts.
5. Render PNG frame sequences at the exact quality size.
6. Run `petcore-cli petpack validate <source-dir>`.
7. If validation fails, fix the assets or manifest and validate again.
8. Run `petcore-cli petpack build --input <source-dir> --output <pet-id>.petpack`.
9. Report progress back to the Studio conversation and PetCore job.

## Guardrails

- Do not read agent auth, token, cookie, or API key files.
- Do not include user project files or agent transcripts in the petpack.
- Keep all reference images inside the generation job workspace.
- Keep runtime FPS profiles fixed at standard 12 FPS and smooth 20 FPS.
