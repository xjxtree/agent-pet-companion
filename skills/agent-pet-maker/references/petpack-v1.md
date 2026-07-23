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
action.

## Visual requirements

- Preserve transparent surroundings; do not place the pet on an opaque rectangular canvas.
- Keep character identity, proportions, palette, lighting, and outline treatment consistent across all states.
- Make every adjacent frame visibly animate rather than duplicating one still.
- For loops, make the final-to-first seam continuous without duplicating the
  first frame as a terminal hold.
- For non-looping actions, reach a readable final pose within the fixed authored
  duration; runtime may hold that pose after the action completes.
- Make the seven state actions distinguishable at desktop-pet size.
- Use the exact manifest dimensions for every frame.
- Provide a useful still `cover.png` and an actual animated WebP preview. Prefer 384 × 416 for previews.

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
