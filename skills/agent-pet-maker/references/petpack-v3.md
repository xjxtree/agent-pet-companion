# Agent Pet Companion `.petpack` V3 contract

## Contents

1. Package tree
2. Render tiers
3. Actions, timing, and playback
4. Visual and metadata requirements
5. Revisions and results

## Package tree

Create one source root:

```text
manifest.json
brief.json
assets/frames/{idle,thinking,tool,waiting,done,failed,acknowledge,drag_left,drag_right}/*.png
assets/preview/cover.png
assets/preview/animated_preview.webp
source/prompt.md
source/source.json
source/references/
source/skill_session.jsonl
build/validation.json
```

The package schema is `apc.petpack.v3`. Use an ID matching
`^pet_[a-z0-9]+$`, list every fixed action exactly once, and use its exact
`assets/frames/<action>` directory. Keep workspace QA, raw sources, transparent
masters, and result sidecars outside this tree.

## Render tiers

Use one tier for every runtime PNG:

| Quality | Exact runtime size | Producer note |
| --- | ---: | --- |
| `low` | 192×208 | Smallest supported tier |
| `standard` | 384×416 | Creation default |
| `high` | 576×624 | Requires a source-capable external workflow |

Every tier is 12:13. The manifest size is the exact decoded PNG size, not a
promise about image-model output. Follow the shared visual and transparency
contracts for source-crop capacity and the sole allowed downscale.

## Actions, timing, and playback

For future creation, use these 50 authored frames unless the user requests
another structurally valid complete timing:

| Action | Frame durations (ms) | Playback | Reduced-motion frame |
| --- | --- | --- | ---: |
| `idle` | 260, 220, 240, 260, 380, 640 | `periodic`, cooldown 2500–5000 | 2 |
| `thinking` | 120, 140, 160, 180 | `burst_then_idle`, repeat 3 | 2 |
| `tool` | 150, 150, 170, 330 | `burst_then_idle`, repeat 3 | 2 |
| `waiting` | 100, 100, 110, 110, 120, 130, 160, 230 | `burst_then_settle`, repeat 3, settle 7 | 4 |
| `done` | 120, 140, 160, 230 | `burst_then_idle`, repeat 3 | 2 |
| `failed` | 80, 80, 90, 100, 110, 120, 190, 290 | `burst_then_settle`, repeat 3, settle 7 | 2 |
| `acknowledge` | 180, 140, 180, 300 | `once_then_return` | 1 |
| `drag_left` | 100, 90, 100, 110, 100, 200 | `loop` | 2 |
| `drag_right` | 100, 90, 100, 110, 100, 200 | `loop` | 2 |

These are creation defaults, not extra validity rules. Preserve the timing of
an existing valid V3 package unless the user explicitly requests a timing
edit. Both eight-frame settle defaults intentionally stop on their final frame,
index 7.

Each action contains 2–40 frames. Each duration is 50–2000 ms, an action totals
at most 5000 ms, and a package contains at most 360 frames. The timing-array
length is the exact PNG count. The common creative target is 4–8 distinct
frames and no more than 1500 ms for a non-periodic authored pass; the 2000 ms
default idle is the deliberate periodic exception.

Use only the fields allowed by the action's fixed mode:

- `idle`: `periodic` plus ordered `cooldown_ms: [minimum, maximum]` in
  0…86,400,000 ms.
- `thinking`, `tool`, `done`: `burst_then_idle` plus
  `entry_repeat_count` in 1…8.
- `waiting`, `failed`: `burst_then_settle` plus `entry_repeat_count` in 1…8
  and an in-range `settle_frame_index`.
- `acknowledge`: `once_then_return` with no additional playback fields.
- `drag_left`, `drag_right`: `loop` with no additional playback fields.

Choose `reduced_motion_frame_index` as an independently readable pose. The
runtime plays authored durations directly; producers do not sample, retime,
duplicate, interpolate, or catch up frames.

## Visual and metadata requirements

- Name frames in zero-padded ASCII natural order, such as `0000.png`.
- Keep at least one transparent pixel on every edge and preserve identity,
  anatomy, costume, palette, and prop relationships.
- Author genuine adjacent poses with a readable action and deliberate loop,
  settle, or return. Do not create filler with duplicates, crossfades, morphs,
  optical flow, transformed copies, or procedural interpolation.
- Provide a decodable cover and animated WebP preview for the same pet.

For portable Maker or Studio external full-source output, write the current
closed metadata schemas. PetCore-owned materializers supply their own validated
producer identity:

- `source/source.json`: `apc.pet-source.v1`, actual generator and runner,
  `provenance: skill-full-source`, permitted `visual_source`,
  `preview_only: false`, all nine timing objects, derived frame counts,
  and package-relative references. Portable Maker finalization records
  `skill_helper: agent-pet-maker`; Studio follows its host-owned producer
  identity contract.
- `brief.json`: one concise motion entry per action with matching timing and
  reduced-motion data.
- `source/skill_session.jsonl`: bounded `apc.pet-source-event.v1` lifecycle
  facts only.
- `build/validation.json`: `apc.pet-validation.v1`; keep `ok:false` until every
  required visual and PetCore gate succeeds.

Use `user-reference-derived` only when supplied references materially influence
the result. Record only package-relative reference paths.

## Revisions and results

Preserve manifest ID and `created_at`. Keep every unrequested state and timing
byte-identical. Treat a timing edit as a complete authored-state replacement.

The shared `production-verify` result is usable only when `build_ok`,
`package_ok`, `interaction_ok`, `runtime_ok`, and `visual_ok` are all exactly
`true`. The helper owns the required build-bound interaction evidence and
rejects missing, partial, duplicate, unknown, or stale evidence.

The completed sidecar records the manifest summary, package path and hash,
changed states, validation, Motion QA/review evidence, and production-gate
status. The archive is a new immutable revision.
