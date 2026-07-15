---
name: agent-pet-studio
description: Generate Agent Pet Companion .petpack assets from the Studio form and validate them with the provided PetCore CLI.
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
  "reference_images": ["/absolute/path/reference.png"]
}
```

Quality maps to runtime frame size:

- `standard`: 192 x 208
- `high`: 384 x 416
- `ultra`: 768 x 832
- `original`: 1536 x 1664

## Output Modes

Agent Pet Companion uses this skill in two compatible modes:

1. **Input request mode:** if required identity, appearance, or behavior details are missing and creating a coherent pet would require guessing, return compact JSON only: `{"needs_input":true,"question":"one concise Studio follow-up question"}`. PetCore pauses the generation job and waits for the user's reply in the Studio conversation.
2. **External full source mode (required when `APC_REQUIRE_EXTERNAL_SKILL_SOURCE=1`):** create the visual assets with an image-capable tool available to the App Server turn, write the complete `petpack-source`, and validate it with the provided PetCore CLI. Returning only brief JSON is not enough. The job-local `apc_write_skill_source.py` helper is explicitly a deterministic preview fixture and is rejected in this mode; it is not evidence of AI image generation.
3. **Built-in materializer mode:** when the Codex App Server turn cannot write files and external full source is not required, return compact JSON with the pet name, visual brief, palette, seven state motion notes, render notes, and `"petpack_source": "petpack-source"`. PetCore's built-in Pet Studio Skill materializer writes the validated full source and records it as internally materialized, so real external-source validation can distinguish it.
4. **Brief mode (fallback):** in non-strict development runs, PetCore may materialize a returned brief with fallback provenance so tests can continue without a real App Server.

## Full Source Output

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
assets/preview/animated_preview.webp
source/prompt.md
source/source.json
source/references/
source/skill_session.jsonl
build/validation.json
```

`manifest.json` must use the current Agent Pet Companion schema, not crate or app semantic versions:

```json
{
  "schema_version": "apc.petpack.v1",
  "id": "pet_lowercasealnum",
  "name": "Pet name",
  "style": "半写实",
  "quality": "standard",
  "render_size": { "width": 192, "height": 208 },
  "fps_profiles": { "standard": 12, "smooth": 20 },
  "default_fps_profile": "standard",
  "states": [
    { "name": "idle", "frames_dir": "assets/frames/idle", "loop": true },
    { "name": "start", "frames_dir": "assets/frames/start", "loop": false },
    { "name": "tool", "frames_dir": "assets/frames/tool", "loop": true },
    { "name": "waiting", "frames_dir": "assets/frames/waiting", "loop": true },
    { "name": "review", "frames_dir": "assets/frames/review", "loop": true },
    { "name": "done", "frames_dir": "assets/frames/done", "loop": false },
    { "name": "failed", "frames_dir": "assets/frames/failed", "loop": true }
  ],
  "created_at": "2026-07-09T00:00:00Z"
}
```

The manifest `id` must be a package id beginning with `pet_` and containing only lowercase ASCII letters and digits after the prefix. Do not use `"0.1.0"` or any crate/app version as `schema_version`.

The seven state names are fixed: `idle`, `start`, `tool`, `waiting`, `review`, `done`, `failed`.

`source/source.json` must identify the real visual producer so PetCore and the UI can distinguish image-generated assets from deterministic preview materialization:

```json
{
  "generator": "codex-app-server-skill",
  "provenance": "skill-full-source",
  "visual_source": "image-generation",
  "frames_per_state": 12,
  "preview_only": false,
  "form": {},
  "reference_files": []
}
```

## Workflow

1. Read the form and reference images.
2. Ask follow-up questions in the Studio conversation only when required details are missing, using Input request mode.
3. In external full source mode, call an image-capable tool to create the main image and visibly distinct frame sequences. One or more ordered sprite sheets may be used and cropped into the required frames to keep the turn bounded. Do not run `apc_write_skill_source.py`; that helper is preview-only. Write `brief.json` with character identity, style constraints, palette, motion notes, and quality, and write `source/source.json` with `generator: "codex-app-server-skill"`, `provenance: "skill-full-source"`, `visual_source: "image-generation"` (or `user-reference-derived`), `frames_per_state >= 2`, and `preview_only: false`. Keep preview encoding fast and prioritize completing required source files and CLI validation over optional compression optimization.
4. In brief mode, return structured JSON only; do not write files or read unrelated files.
5. Generate a consistent main image and all seven state motion concepts.
6. Render PNG frame sequences at the exact quality size.
7. Run `"$APC_PETCORE_CLI" petpack validate <source-dir>`; fall back to `petcore-cli` only if the environment variable is absent.
8. If validation fails, fix the assets or manifest and validate again.
9. Run `"$APC_PETCORE_CLI" petpack build --input <source-dir> --output <pet-id>.petpack`.
10. Report progress back to the Studio conversation and PetCore job.

## Guardrails

- Do not read agent auth, token, cookie, or API key files.
- Do not include user project files or agent transcripts in the petpack.
- Keep all reference images inside the generation job workspace.
- Keep runtime FPS profiles fixed at standard 12 FPS and smooth 20 FPS.
