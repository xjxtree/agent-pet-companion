# Agent Pet Companion `.petpack` V2

## Contents

1. Package tree
2. Manifest and quality
3. State timing and defaults
4. Visual and frame rules
5. Producer metadata
6. Revision and result contracts

## Package tree

Create one source root:

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

The helper owns `build/validation.json`. Keep helper QA evidence and output
sidecars outside `petpack-source`.

## Manifest and quality

`manifest.json` is closed and declares `apc.petpack.v2`. PetCore does not read
V1 packages; recreate them through the V2 Maker instead of migrating, sampling,
or retiming their frames.

Use one render tier for every PNG:

| Quality | Exact render size | Use |
| --- | ---: | --- |
| `low` | 192×208 | pixel/minimal characters and low-resource devices |
| `standard` | 384×416 | default for most characters |

Both tiers are 12:13. Width is a multiple of 192, so both sprite-sheet edges are
multiples of 16. Unsupported quality names, including the retired `high`, fail
closed; do not alias or map them onto a supported tier.

Example manifest:

```json
{
  "schema_version": "apc.petpack.v2",
  "id": "pet_starlightfox",
  "name": "Starlight Fox",
  "style": "soft luminous storybook creature",
  "quality": "standard",
  "render_size": { "width": 384, "height": 416 },
  "states": [
    {
      "name": "idle",
      "frames_dir": "assets/frames/idle",
      "frame_durations_ms": [180, 160, 180, 380],
      "playback": { "mode": "periodic", "cooldown_ms": [4000, 8000] },
      "reduced_motion_frame_index": 2
    },
    {
      "name": "start",
      "frames_dir": "assets/frames/start",
      "frame_durations_ms": [120, 140, 160, 180],
      "playback": { "mode": "once_hold", "settle_frame_index": 3 },
      "reduced_motion_frame_index": 2
    },
    {
      "name": "tool",
      "frames_dir": "assets/frames/tool",
      "frame_durations_ms": [150, 150, 170, 330],
      "playback": {
        "mode": "burst_then_settle",
        "entry_repeat_count": 1,
        "settle_frame_index": 3
      },
      "reduced_motion_frame_index": 2
    },
    {
      "name": "waiting",
      "frames_dir": "assets/frames/waiting",
      "frame_durations_ms": [150, 150, 150, 150, 170, 230],
      "playback": { "mode": "once_hold", "settle_frame_index": 5 },
      "reduced_motion_frame_index": 4
    },
    {
      "name": "review",
      "frames_dir": "assets/frames/review",
      "frame_durations_ms": [140, 140, 150, 150, 180, 240],
      "playback": { "mode": "once_hold", "settle_frame_index": 5 },
      "reduced_motion_frame_index": 4
    },
    {
      "name": "done",
      "frames_dir": "assets/frames/done",
      "frame_durations_ms": [120, 140, 160, 230],
      "playback": { "mode": "once_hold", "settle_frame_index": 3 },
      "reduced_motion_frame_index": 2
    },
    {
      "name": "failed",
      "frames_dir": "assets/frames/failed",
      "frame_durations_ms": [150, 170, 190, 290],
      "playback": { "mode": "once_hold", "settle_frame_index": 3 },
      "reduced_motion_frame_index": 2
    }
  ],
  "created_at": "2026-07-16T00:00:00Z"
}
```

Use an ID matching `^pet_[a-z0-9]+$`. Use every fixed state exactly once and
its exact `assets/frames/<state>` directory.

## State timing and defaults

The array length is the exact authored PNG count. Each duration is 50–2000ms;
each state has 2–40 frames; a package has at most 280 frames. These structural
limits do not turn the 4–8 frame creative budget into a hard gate.

The default is 32 frames:

| State | Durations (ms) | Total | Playback |
| --- | --- | ---: | --- |
| `idle` | 180, 160, 180, 380 | 900 | `periodic`, cooldown 4000–8000 |
| `start` | 120, 140, 160, 180 | 600 | `once_hold` |
| `tool` | 150, 150, 170, 330 | 800 | `burst_then_settle`, repeat 1 |
| `waiting` | 150, 150, 150, 150, 170, 230 | 1000 | `once_hold` |
| `review` | 140, 140, 150, 150, 180, 240 | 1000 | `once_hold` |
| `done` | 120, 140, 160, 230 | 650 | `once_hold` |
| `failed` | 150, 170, 190, 290 | 800 | `once_hold` |

End with a longer hold when it improves settle. For every mode, use only its
fields:

- `loop`: `mode` only.
- `once_hold`: add an in-range `settle_frame_index`.
- `periodic`: add ordered `[minimum, maximum]` `cooldown_ms`; each value is an
  integer in `0...86_400_000` milliseconds.
- `burst_then_settle`: add `entry_repeat_count` 1–8 and an in-range
  `settle_frame_index`.

Choose `reduced_motion_frame_index` as an independently readable still for the
state. Do not default it to frame 0 or select a transitional in-between.

Timing is authored content. The runtime uses the arrays directly and never
resamples, retimes, subsamples, catches up missed frames, or restarts an
unchanged semantic state.

## Visual and frame rules

- Generate/edit every frame at the manifest tier or extract one exact
  target-size crop without resampling.
- Keep transparent surroundings and at least one transparent pixel on every
  edge.
- Preserve identity, anatomy, palette, costume, and prop relationships.
- Make each adjacent pose genuine; reject duplicates, crossfades, morphs,
  optical flow, transformed copies, or procedural filler.
- Use non-uniform spacing and a readable anticipation–action–settle arc where
  appropriate.
- Keep resident/high-frequency `idle`, `tool`, and `waiting` motion restrained
  around a stable root. Allow short full-body reactions for `start`, `review`,
  `done`, and `failed` within the crop budget.
- Make loop boundaries deliberate. Make hold/settle indices readable.
- Name frames with zero-padded ASCII natural order, such as `0000.png`.
- Provide a useful `cover.png` and animated WebP preview.

## Producer metadata

`source/source.json` is closed. Use the current safe-producer schema. Record
`schema_version: apc.pet-source.v1`, the actual `generator` and `runner`,
`provenance: skill-full-source`, manifest identity/style/quality,
`visual_source`, `preview_only: false`, the seven complete manifest state
objects under `states`, array-length-derived `state_frame_counts`,
package-relative `reference_files`, and `skill_helper: agent-pet-maker`.

For a reference-derived result, use `user-reference-derived`, set
`reference_visual_influence: true`, and list package-relative files below
`source/references/`.

Each `brief.json` state has `name` or `state`, `motion`, and the matching
`frame_durations_ms`, `playback`, and `reduced_motion_frame_index`. Optional
`runtime` contains the complete seven states, `state_frame_counts`, and
`render_size`.

Write only the bounded user brief to `source/prompt.md`. Lifecycle events use
the current safe event schema. A `states.rendered` event records
`state_timings` and `state_frame_counts`; never include conversations,
identifiers, commands, tool inputs/outputs, environment values, credentials,
absolute paths, or URLs.

## Revision and result contracts

For modification, preserve manifest ID and `created_at`. Change only requested
state directories. A changed timing contract changes that whole authored state;
regenerate it rather than adapting old frames.

`production-verify` reports:

```json
{
  "build_ok": true,
  "package_ok": true,
  "interaction_ok": true,
  "interaction_evidence": [
    "OverlayPlacementAuthorityTests",
    "AppStoreOverlaySnapshotTests",
    "OverlayGeometryTests",
    "OverlayDisplayWidthTests"
  ],
  "runtime_ok": true,
  "visual_ok": true,
  "usable": true
}
```

`usable` is exactly the conjunction of the five component gates. Every gate
must be present and exactly `true`; a missing or non-boolean gate fails closed
and prevents finalization. A true `interaction_ok` also requires the complete,
non-empty, closed `interaction_evidence` list above; unknown, duplicate, or
partial evidence prevents finalization.

The completed result sidecar includes the V2 manifest summary with all state
contracts, the package hash and path, changed states, PetCore validation,
Motion QA/review evidence, and result path. The archive is a new immutable
revision; the helper never edits an installed revision in place.
