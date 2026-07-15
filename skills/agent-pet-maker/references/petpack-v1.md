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

Set `fps_profiles` to `{ "standard": 12, "smooth": 20 }` and `default_fps_profile` to `standard`.

Use each state exactly once:

| State | Loop | Visual intent |
| --- | --- | --- |
| `idle` | true | calm breathing or subtle ambient motion |
| `start` | false | notice, wake, or begin work |
| `tool` | true | active work, movement, or tool use |
| `waiting` | true | visibly waiting for user input |
| `review` | true | checking or presenting a result |
| `done` | false | successful completion reaction |
| `failed` | true | recoverable error or disappointment |

Each `frames_dir` must be `assets/frames/<state>`. A portable `skill-full-source` result requires at least two PNG frames in every state; every newly generated or regenerated state must contain at least two ordered, byte-distinct PNG frames. Use at most 40 frames per state and 280 total. A legacy package with a one-frame state cannot be emitted as a conforming portable-skill revision until that state is explicitly regenerated. The helper requires a byte-level change within every declared modified state, but semantic quality still requires visual inspection.

## Visual requirements

- Preserve transparent surroundings; do not place the pet on an opaque rectangular canvas.
- Keep character identity, proportions, palette, lighting, and outline treatment consistent across all states.
- Make adjacent frames visibly animate rather than duplicating one still.
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
  "frames_per_state": 2,
  "reference_files": [],
  "runner": "actual-agent-name",
  "skill_helper": "agent-pet-maker"
}
```

For a reference-derived result, use `visual_source: "user-reference-derived"`, set `reference_visual_influence: true`, and list package-relative files under `reference_files`. For modification, the helper adds `base_manifest_id` and `changed_states`; it does not store a local path or base archive hash in the package. Never add `producer`, `operation`, `frame_counts`, `base`, or other undeclared fields. Never identify a producer or tool that was not actually used.

Write `brief.json` with this exact field vocabulary. `runtime` and `generation` are optional, but when present must match the manifest/source:

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
    { "name": "idle", "motion": "Breathes softly." },
    { "name": "start", "motion": "Raises its ears." },
    { "name": "tool", "motion": "Paws move while working." },
    { "name": "waiting", "motion": "Tilts one ear toward the user." },
    { "name": "review", "motion": "Presents the result." },
    { "name": "done", "motion": "Nods with a star burst." },
    { "name": "failed", "motion": "Lowers its ears gently." }
  ],
  "runtime": {
    "default_fps": 12,
    "smooth_fps": 20,
    "frames_per_state": 2,
    "render_size": { "width": 384, "height": 416 }
  }
}
```

Write only the normalized user request to `source/prompt.md`.

Write JSON Lines lifecycle events to `source/skill_session.jsonl`. Every line uses only fields from `apc.pet-source-event.v1`, for example:

```json
{"schema_version":"apc.pet-source-event.v1","event":"states.rendered","created_at":"2026-07-16T00:00:00Z","skill":"agent-pet-maker","runner":"actual-agent-name","generator":"actual-image-tool-name","manifest_id":"pet_starlightfox","quality":"high","render_size":{"width":384,"height":416},"states":["idle","start","tool","waiting","review","done","failed"],"frames_per_state":2,"fps_profiles":{"standard":12,"smooth":20}}
```

Events may describe workspace preparation, visual generation, and validation, but must not contain conversations, thread/session IDs, operation names, validator-specific ad hoc fields, tool arguments, commands, environment values, or tool output. The helper appends the final schema-conforming validation event.
