# Agent Pet Companion `.petpack` v1

## Package tree

Create exactly one package source root containing:

```text
manifest.json
brief.json
assets/frames/{idle,start,tool,waiting,review,done,failed}/*.png
assets/preview/cover.png
assets/preview/animated_preview.webp
source/prompt.md
source/source.json
source/references/
source/skill_session.jsonl
build/validation.json
```

The helper owns `build/validation.json`; do not use it to claim validation before `finalize` succeeds.

## Manifest contract

`manifest.json` is closed: do not add fields. Use this exact shape (replace values, but preserve field names and state layout):

```json
{
  "schema_version": "apc.petpack.v1",
  "id": "pet_starlightfox",
  "name": "Starlight Fox",
  "style": "soft luminous storybook creature",
  "quality": "high",
  "render_size": { "width": 384, "height": 416 },
  "native_fps": 10,
  "states": [
    { "name": "idle", "frames_dir": "assets/frames/idle", "loop": true, "duration_ms": 2000 },
    { "name": "start", "frames_dir": "assets/frames/start", "loop": false, "duration_ms": 1000 },
    { "name": "tool", "frames_dir": "assets/frames/tool", "loop": true, "duration_ms": 2000 },
    { "name": "waiting", "frames_dir": "assets/frames/waiting", "loop": true, "duration_ms": 2000 },
    { "name": "review", "frames_dir": "assets/frames/review", "loop": true, "duration_ms": 2000 },
    { "name": "done", "frames_dir": "assets/frames/done", "loop": false, "duration_ms": 1000 },
    { "name": "failed", "frames_dir": "assets/frames/failed", "loop": true, "duration_ms": 2000 }
  ],
  "created_at": "2026-07-16T00:00:00Z"
}
```

Use an ID matching `^pet_[a-z0-9]+$`. For a modification, preserve the base ID, original `created_at`, and all structural fields.

| Quality | Exact PNG size |
| --- | --- |
| `standard` | 192 × 208 |
| `high` | 384 × 416 |
| `ultra` | 768 × 832 |
| `original` | 1536 × 1664 |

### Per-frame native source resolution

The quality table is a source-pixel requirement as well as a final PNG
dimension requirement. Every accepted animation frame must originate from an
independent crop containing exactly the selected `render_size` in decoded
source pixels before any resampling. A target-size PNG canvas does not make a
smaller source frame native resolution.

- A frame generated or edited directly at `render_size` is valid.
- A larger image or sprite sheet is valid when each frame is extracted as one
  exact target-size source rectangle with crop-only operations.
- A sheet cell larger than the target may be trimmed to one stable target-size
  crop. Do not resize the cell in either direction during extraction.
- A crop smaller than the target is invalid. Never upscale, super-resolve,
  stretch, or paste it into a target-size transparent canvas.
- Calculate available cell pixels from the decoded source dimensions after
  accounting for margins and gutters. Do not infer them from the requested
  generator size or the final exported PNG dimensions.
- Reject a nominally target-size cell when it visibly contains a lower-
  resolution raster that was enlarged before or during extraction.

For High quality, each frame requires 384 × 416 native source pixels. A decoded
1536 × 1024 image arranged as 4 × 2 can provide an unscaled 384 × 416 crop per
cell, with surplus cell height discarded by cropping. The same image arranged
as 10 × 4 provides only about 154 × 256 pixels per cell and is invalid; scaling
those cells to 384 × 416 does not repair it.

The runtime media gate verifies that each final PNG decodes at `render_size`.
That check cannot prove source provenance or detect every pre-export upscale,
so strict producers must enforce and visually inspect this native-source
contract immediately after each generated image.

Set `native_fps` to exactly `10` or `20`. Creation defaults to `10`; use `20`
only when the user requests a smooth-native pet and the producer can create the
additional real intermediate frames. Runtime derives supported playback modes:
a native-10 pet supports 10 FPS only, while a native-20 pet supports 10 and 20
FPS without changing action duration.

Use each state exactly once:

| State | Loop | Default duration | Visual intent |
| --- | --- | ---: | --- |
| `idle` | true | 2000 ms | calm breathing or subtle ambient motion |
| `start` | false | 1000 ms | notice, wake, or begin work |
| `tool` | true | 2000 ms | active work, movement, or tool use |
| `waiting` | true | 2000 ms | visibly waiting for user input |
| `review` | true | 2000 ms | checking or presenting a result |
| `done` | false | 1000 ms | successful completion reaction |
| `failed` | true | 2000 ms | recoverable error or disappointment |

Each `duration_ms` is exactly `1000` or `2000` and becomes immutable package
information until an explicit AI revision changes it. Each `frames_dir` must be
`assets/frames/<state>`, and its exact frame count is:

```text
state_frame_count = native_fps * duration_ms / 1000
```

Frames are ordered with the shared deterministic ASCII natural comparator;
write canonical zero-padded ASCII names such as `0000.png`, `0001.png`, and
`0010.png`.

The only valid counts are therefore 10, 20, or 40. With the default durations,
a native-10 package contains 120 frames and a native-20 package contains 240.
Use at most 40 frames per state and 280 total. Every adjacent generated frame
must be visibly distinct. At native 20 FPS, runtime Standard playback defines
the canonical 10 FPS sequence. Loop states sample every second frame. One-shot
`start` and `done` states sample uniformly while preserving both the first and
final authored poses. Adjacent poses in that canonical sequence, including the
wrap pair for loop states, must remain pixel-distinct. Every non-sampled frame
is genuine intermediate motion; runtime never speeds up or slows down the
action. Author the exact derived count as distinct ordered sprite cells.
Multiple coherent sheets may sum to that count, but never expand a smaller
key-pose storyboard with crossfade, morph, optical flow, transformed
duplicates, or procedural interpolation.

## Visual requirements

- Preserve transparent surroundings; do not place the pet on an opaque rectangular canvas.
- Lock a canonical identity: character silhouette, face landmarks, proportions,
  anatomy, outfit/accessories, palette, lighting, outline/texture, scale,
  baseline, and camera remain stable unless the action explicitly moves or
  deforms that part.
- Direct exactly one intent and one primary action per state, supported by small
  causally connected responses and delayed or settling secondary motion
  appropriate to the pet's form. Use anticipation, a readable apex, and
  recovery/settle; simplify multi-step business instead of squeezing it into
  one second.
- Declare stable spatial anchors and moving regions while planning. Anchors
  preserve identity, camera, scale, baseline, and essential contacts; they do
  not require every other body or visual feature to remain frozen. Generate/edit
  each state as one coherent sequence from the canonical base rather than
  independently inventing each frame.
- Keep props continuous in shape, orientation, position, and attachment. Props
  enter and leave through visible motion rather than appearing between frames.
- A moving limb, tail, costume part, or prop must remain anatomically attached
  and may not shrink or disappear between adjacent frames or across a loop
  boundary.
- Make every adjacent frame visibly animate rather than duplicating one still.
- For loops, make the final-to-first seam continuous without duplicating the
  first frame as a terminal hold.
- For non-looping actions, reach a readable final pose within the fixed authored
  duration; runtime may hold that pose after the action completes.
- Make the seven state actions distinguishable at desktop-pet size.
- Reject actions that require zooming to understand, move only an isolated
  micro-feature without a connected response, or move the whole subject as one
  rigid layer. Review the intent and layered response at 192 × 208.
- Use the exact manifest dimensions for every frame.
- Preserve target-size native source pixels for every frame and extract with
  crop-only operations; a resized lower-resolution source is non-conforming
  even when its final PNG dimensions match the manifest.
- Provide a useful still `cover.png` and an actual animated WebP preview. Prefer 384 × 416 for previews.
- Before finalization, inspect the helper's 192 × 208 keyframe sheet and every
  Standard/Smooth playback preview. Automated drift and seam warnings are
  advisory only when no visible defect is present; a visible snap,
  disappearing attachment, prop teleport, or broken loop must be repaired. A
  bound per-state visual review is required.

## Provider-neutral metadata

`source/source.json` is also closed. Record the real image generator in `generator`, the host agent in `runner`, and this skill in `skill_helper`:

```json
{
  "schema_version": "apc.pet-source.v1",
  "generator": "actual-image-tool-name",
  "provenance": "skill-full-source",
  "created_at": "2026-07-16T00:00:00Z",
  "manifest_id": "pet_starlightfox",
  "pet_name": "Starlight Fox",
  "style": "soft luminous storybook creature",
  "quality": "high",
  "visual_source": "image-generation",
  "preview_only": false,
  "native_fps": 10,
  "state_durations_ms": {
    "idle": 2000, "start": 1000, "tool": 2000, "waiting": 2000,
    "review": 2000, "done": 1000, "failed": 2000
  },
  "state_frame_counts": {
    "idle": 20, "start": 10, "tool": 20, "waiting": 20,
    "review": 20, "done": 10, "failed": 20
  },
  "reference_files": [],
  "runner": "actual-agent-name",
  "skill_helper": "agent-pet-maker"
}
```

For a reference-derived result, use `visual_source: "user-reference-derived"`, set `reference_visual_influence: true`, and list package-relative files under `reference_files`. For modification, the helper adds `base_manifest_id` and `changed_states`; it does not store a local path or base archive hash in the package. Never add `producer`, `operation`, a bare `frame_counts`, `base`, or other undeclared fields. Never identify a producer or tool that was not actually used.

Write `brief.json` with this exact field vocabulary. Every object state carries
the same `duration_ms` as its manifest state. `runtime` and `generation` are
optional, but when present must match the manifest/source:

```json
{
  "schema_version": "apc.pet-brief.v1",
  "name": "Starlight Fox",
  "style": "soft luminous storybook creature",
  "quality": "high",
  "description": "A compact violet fox with a bright starry tail.",
  "generation": {
    "generator": "actual-image-tool-name",
    "provenance": "skill-full-source",
    "skill_helper": "agent-pet-maker",
    "preview_only": false
  },
  "palette": ["violet", "indigo", "cool white"],
  "references": [],
  "states": [
    { "name": "idle", "motion": "Breathes softly.", "duration_ms": 2000 },
    { "name": "start", "motion": "Raises its ears.", "duration_ms": 1000 },
    { "name": "tool", "motion": "Paws move while working.", "duration_ms": 2000 },
    { "name": "waiting", "motion": "Tilts one ear toward the user.", "duration_ms": 2000 },
    { "name": "review", "motion": "Presents the result.", "duration_ms": 2000 },
    { "name": "done", "motion": "Nods with a star burst.", "duration_ms": 1000 },
    { "name": "failed", "motion": "Lowers its ears gently.", "duration_ms": 2000 }
  ],
  "runtime": {
    "native_fps": 10,
    "state_durations_ms": {
      "idle": 2000, "start": 1000, "tool": 2000, "waiting": 2000,
      "review": 2000, "done": 1000, "failed": 2000
    },
    "state_frame_counts": {
      "idle": 20, "start": 10, "tool": 20, "waiting": 20,
      "review": 20, "done": 10, "failed": 20
    },
    "render_size": { "width": 384, "height": 416 }
  }
}
```

Write only the normalized user request to `source/prompt.md`.

Write JSON Lines lifecycle events to `source/skill_session.jsonl`. Every line uses only fields from `apc.pet-source-event.v1`, for example:

```json
{"schema_version":"apc.pet-source-event.v1","event":"states.rendered","created_at":"2026-07-16T00:00:00Z","skill":"agent-pet-maker","runner":"actual-agent-name","generator":"actual-image-tool-name","manifest_id":"pet_starlightfox","quality":"high","render_size":{"width":384,"height":416},"states":["idle","start","tool","waiting","review","done","failed"],"native_fps":10,"state_durations_ms":{"idle":2000,"start":1000,"tool":2000,"waiting":2000,"review":2000,"done":1000,"failed":2000},"state_frame_counts":{"idle":20,"start":10,"tool":20,"waiting":20,"review":20,"done":10,"failed":20}}
```

Events may describe workspace preparation, visual generation, and validation, but must not contain conversations, thread/session IDs, operation names, validator-specific ad hoc fields, tool arguments, commands, environment values, or tool output. The helper appends the final schema-conforming validation event.

## Timing revisions

Timing is authored content and cannot be changed by runtime configuration.

- `10 -> 20` FPS with unchanged durations keeps every old frame at the indices
  selected by runtime Standard playback and generates real, distinct motion at
  every remaining index. Loops use `0, 2, 4, ...`; one-shots use uniform
  endpoint-preserving indices.
- `20 -> 10` FPS with unchanged durations deterministically keeps that same
  runtime sample, including the final one-shot pose.
- Changing native FPS affects all seven state directories and must declare all
  seven as changed.
- Changing one state's duration affects that state. Re-storyboard and regenerate
  its complete sequence; do not truncate, repeat, duplicate, accelerate, or
  decelerate the old frames.
- A modification preserves the manifest ID and original `created_at`, but the
  resulting archive is committed as a new immutable revision. Earlier revision
  bytes remain unchanged.
