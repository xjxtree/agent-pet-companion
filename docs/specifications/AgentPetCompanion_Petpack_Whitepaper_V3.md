# Agent Pet Companion `.petpack` V3 Specification

Schema identity: `apc.petpack.v3`

`.petpack` is Agent Pet Companion's app-owned, portable desktop-pet container.
It is a ZIP archive containing a strict manifest, nine fixed authored actions,
static and animated previews, privacy-bounded production metadata, and
validation metadata. Package content is untrusted data and is never executed.

This document defines the current V3 reader, writer, runtime, and producer
contract. Exact enforcement lives in
[PetManifest](../../crates/petcore-types/src/lib.rs),
[petpack.rs](../../crates/petcore/src/petpack.rs),
[JSON Schemas](../../schemas/), and their fixtures and tests.

## 1. Conformance profiles

| Profile | Meaning |
|---|---|
| Runtime package | Passes the container, path, budget, manifest, media, metadata, and import checks required by PetCore. |
| Safe Producer | `source/source.json` declares `apc.pet-source.v1`; all four metadata schemas, cross-file consistency, and recursive privacy checks pass. V3 has no untagged metadata compatibility profile. |
| Verified visual source | Safe Producer package with trusted full-source provenance, an exact authored frame inventory, visibly distinct adjacent motion, current `authored_timing` QA, and complete per-state visual review. The strict Studio and portable Maker paths enforce this profile; ordinary import does not certify artistic quality. |

An unknown, malformed, older, or newer manifest or source-metadata version
fails closed. In particular, PetCore does not read or migrate
`apc.petpack.v1` or `apc.petpack.v2`; the user-facing validation error directs
the user to recreate the pet with the V3 maker.

## 2. Container identity

| Property | Contract |
|---|---|
| Filename extension | `.petpack`, checked case-insensitively by App import UI |
| Container | ZIP with `/` path separators |
| Development input | Validators and builders also accept an unpacked directory |
| UTI | `dev.agentpet.petpack`, conforming to `public.data` |
| MIME tag | `application/vnd.agentpet.petpack+zip` |
| macOS publication metadata | Writers clear only Finder's BSD `UF_HIDDEN` flag from the final user-facing archive after atomic publication. Dot-prefixed staging names may be hidden, but their inode metadata must not make the normally named result invisible. |

The archive is the portable exchange unit. A directory is only a trusted local
build or validation input.

## 3. Required layout

```text
<pet-id>.petpack
├── manifest.json
├── brief.json
├── assets/
│   ├── frames/
│   │   ├── idle/*.png
│   │   ├── thinking/*.png
│   │   ├── tool/*.png
│   │   ├── waiting/*.png
│   │   ├── done/*.png
│   │   ├── failed/*.png
│   │   ├── acknowledge/*.png
│   │   ├── drag_left/*.png
│   │   └── drag_right/*.png
│   └── preview/
│       ├── cover.png
│       └── animated_preview.webp
├── source/
│   ├── prompt.md
│   ├── source.json
│   ├── references/
│   └── skill_session.jsonl
└── build/
    └── validation.json
```

All listed files and directories are required; `source/references/` may be
empty. At the untrusted in-app Skill boundary, PetCore may materialize this
empty directory only when the submitted form has no reference images. State
directories are flat. Files with a case-insensitive `.png` suffix are frames;
other direct files are ignored and must not carry required semantics.

The runtime permits unknown root data files except explicit compatibility
package names such as `.codex-plugin`, `hooks`, `skills`, `codex-pet.json`,
`codex_pet.json`, and `pet.json`, which are rejected. Conforming producers put
optional non-executable extension data below
`extensions/<reverse-domain>/`.

## 4. Manifest contract

[`schemas/petpack.schema.json`](../../schemas/petpack.schema.json) and Rust
`PetManifest` define `manifest.json`. Unknown fields are rejected.

| Field | Contract |
|---|---|
| `schema_version` | Exactly `apc.petpack.v3` |
| `id` | `^pet_[a-z0-9]+$`, at most 128 characters; stable logical identity |
| `name` | Non-blank display name; not unique |
| `style` | Non-blank visual or production style |
| `quality` | Exactly `low`, `standard`, or `high` |
| `render_size` | Exact canvas for the selected quality |
| `states` | Exactly one of each fixed action, with the fixed directory, timing, and state-specific playback mode |
| `created_at` | RFC 3339 timestamp |

There is no package-wide FPS, duration, playback profile, or uniform frame
count. Every state owns its complete authored timing.

### Quality and exact runtime canvas

| Quality | Width | Height | Selection guidance |
|---|---:|---:|---|
| `low` | 192 | 208 | Minimal, pixel-focused, or resource-sensitive characters; 1:1 through 96 pt at 2× |
| `standard` | 384 | 416 | Default for most characters; 1:1 through 192 pt at 2× |
| `high` | 576 | 624 | High-resolution art from an externally source-capable producer; 1:1 through 288 pt at 2× |

All tiers are 12:13 and their widths are multiples of 192. One package uses one
tier for every frame. `render_size` is the exact decoded runtime PNG size and
the minimum accepted 12:13 source crop, not a model-output instruction. A
producer must inspect the untouched image at its actual returned dimensions and
may crop a complete 12:13 cell at or above the target from a larger decoded
source. Prompted dimensions and layout guides may guide composition but never
prove output pixels. Within one state, source crop windows keep stable geometry
and preserve authored translation and baseline rather than independently
fitting each pose to its subject bounds.

After transparent exact-tier frames exist, Motion QA reports each frame's
Alpha-weighted body anchor and visible baseline. The producer compares that
path with the action card and deterministic pose guide: intentional travel and
authored easing remain untouched. When whole-subject registration is the only
defect, a QA-digest-bound correction may translate complete transparent frames
by integer pixels to a locked, equal-spacing, or explicit guide-derived path.
It performs no scaling, rotation, resampling, Alpha filtering, or pose
deformation; any lost Alpha or transparent-padding violation rejects the
correction. Corrected frames require fresh Motion QA and visual review.

For model-generated multi-frame rows, Maker and Studio use one canonical
character base plus a deterministic pose guide and a separate deterministic
size-reference image. Both structural references come from one recorded slot,
centered crop, safe-box, baseline, and global-scale geometry; prompted
equal-size figures are guidance, not acceptance evidence. These workspace-only
guides never enter the portable package.

The shared Maker/Studio transparency pipeline retains that source-resolution
transparent master and may perform one direct linear-light
premultiplied-Alpha downscale to the runtime tier for `low`, `standard`, or
`high`. Upscaling, super-resolution, stretching, resizing before matting,
independent per-pose fitting, cascaded or post-process resizing, or padding a
smaller crop into the target canvas is invalid. Package support does not claim
that every producer can create every tier. The App's Codex-backed Studio and
the built-in ChatGPT/Codex image path are qualified only for `low` and
`standard`. Another producer may author `high` only when its untouched decoded
source proves sufficient pixels for every cell; splitting a state across
multiple batches is not a substitute for missing source capacity.
[Validation Profiles](../development/validation.md) defines which validation
layer covers this boundary.

Display size is a separate App preference and never changes package identity or
authored pixels. The App exposes a 100–300 pt logical-width slider; it does not
rewrite, upscale, or retime a package.

### Fixed actions and defaults

The nine action names and directories are fixed. The first six represent Agent
semantics; the final three are App-local presentation interactions. Array order
is not semantic, but writers use this order for deterministic output and review.

| Action | `frames_dir` | Default `frame_durations_ms` | Required playback | Reduced-motion index |
|---|---|---|---|---:|
| `idle` | `assets/frames/idle` | `[260, 220, 240, 260, 380, 640]` | `periodic`, cooldown `[2500, 5000]` | 2 |
| `thinking` | `assets/frames/thinking` | `[120, 140, 160, 180]` | `burst_then_idle`, repeat 3 | 2 |
| `tool` | `assets/frames/tool` | `[150, 150, 170, 330]` | `burst_then_idle`, repeat 3 | 2 |
| `waiting` | `assets/frames/waiting` | `[100, 100, 110, 110, 120, 130, 160, 230]` | `burst_then_settle`, repeat 3, settle 7 | 4 |
| `done` | `assets/frames/done` | `[120, 140, 160, 230]` | `burst_then_idle`, repeat 3 | 2 |
| `failed` | `assets/frames/failed` | `[80, 80, 90, 100, 110, 120, 190, 290]` | `burst_then_settle`, repeat 3, settle 7 | 2 |
| `acknowledge` | `assets/frames/acknowledge` | `[180, 140, 180, 300]` | `once_then_return` | 1 |
| `drag_left` | `assets/frames/drag_left` | `[100, 90, 100, 110, 100, 200]` | `loop` | 2 |
| `drag_right` | `assets/frames/drag_right` | `[100, 90, 100, 110, 100, 200]` | `loop` | 2 |

These 50-frame defaults are a production starting point for future creation,
not a reason to make every pet move identically or an additional conformance
gate. A producer may author another valid rhythm and mode-specific playback
value when it better expresses the character. Existing packages that satisfy
V3 remain valid and are not migrated, rewritten, or rejected merely because
their authored timing differs from this table. An edit preserves the validated
baseline timing unless the user explicitly requests a timing change.

Package actions are not all Agent session events. The normalized Agent
event `start` has no pet reaction and renders `idle`; Agent events `thinking`
and `plan` both select the package `thinking` action. The remaining reactive
events select their namesake semantic action. `acknowledge` is activated only by
an idle primary click. When no bubble content is available, pointer-down also
adds a 160 ms, low-amplitude press-scale response; starting a drag cancels that
response. `drag_left` and `drag_right` are selected from the current pointer-drag
direction. These three interactions and the press response do not emit Agent
events, change the underlying semantic state, or persist. Reduce Motion omits
both acknowledge playback and the press-scale response.

V3 intentionally provides no 16-direction gaze set or any other gaze action.
It also defines no hover jump, autonomous roaming, audio, particles, momentum,
or post-release movement. Interaction presentation priority is drag,
acknowledge, then the current semantic presentation.

## 5. Per-action timing and playback

Every state object contains:

```json
{
  "name": "tool",
  "frames_dir": "assets/frames/tool",
  "frame_durations_ms": [150, 150, 170, 330],
  "playback": {
    "mode": "burst_then_idle",
    "entry_repeat_count": 3
  },
  "reduced_motion_frame_index": 2
}
```

### Hard structural invariants

- `frame_durations_ms` has 2–40 integer entries.
- Each entry is 50–2,000 ms and the state total is at most 5,000 ms.
- The state directory contains exactly one decodable PNG for each duration
  entry.
- `reduced_motion_frame_index` and every settle index are inside that exact
  frame sequence.
- `entry_repeat_count`, when required, is 1–8.
- A periodic cooldown is `[minimum_ms, maximum_ms]`, each no more than
  86,400,000 ms, with minimum no greater than maximum.

Playback fields are closed by mode:

| Mode | Meaning | Required fields | Forbidden fields |
|---|---|---|---|
| `loop` | Repeat the sequence continuously | none | repeat, settle, cooldown |
| `periodic` | Play once, wait a randomized bounded cooldown, then repeat | `cooldown_ms` | repeat, settle |
| `burst_then_settle` | Repeat the authored burst a fixed number of times, then hold | `entry_repeat_count`, `settle_frame_index` | cooldown |
| `burst_then_idle` | Repeat the authored burst, then present the package idle action without changing the semantic state | `entry_repeat_count` | settle, cooldown |
| `once_then_return` | Play once, then return to the underlying semantic presentation | none | repeat, settle, cooldown |

The action/mode mapping in §4 is a hard invariant; structurally valid fields are
still rejected when attached to the wrong fixed action.

The runtime uses the authored duration of each frame directly. It never samples,
subsamples, duplicates, interpolates, or retimes frames and exposes no
Standard/Smooth playback choice. An unchanged semantic state does not restart.
After a rendering stall, playback resumes from the currently due frame without
rapidly presenting missed frames. `burst_then_idle` is the key long-lease
guard: thinking, tool, and done cannot hold their last pose for the remaining
semantic lease. They show their bounded authored burst and then visually use
idle while the bubble and semantic state continue to communicate activity.
Waiting and failed retain their explicit persistent settle pose.

With Reduce Motion, the runtime presents the declared representative frame
without boundary scheduling. A finite semantic action still returns visually
to idle after its authored active duration; acknowledge is skipped; a drag uses
the declared representative left/right pose only while dragging.

The following common production targets are warnings, not package validity
limits: 4–8 authored frames, at most about 1,500 ms for a non-periodic action,
and an average effective rate of 4–12 frames per second. A periodic idle may
deliberately use a longer calm authored hold, including the 2,000 ms creation
default, before its separate cooldown. A valid action outside those ranges
remains importable when its structural contract is sound.

`animated_preview.webp` is a non-authoritative display asset. Its codec timing
must not be used to infer runtime timing.

## 6. Media and visual-production contract

### Runtime media gate

- Each frame is a decodable PNG whose dimensions exactly match `render_size`.
- Frame ordering uses the same deterministic ASCII natural comparator in
  PetCore, the Maker Skill, and macOS playback. Producers use zero-padded ASCII
  names such as `0000.png` and `0001.png`.
- `assets/preview/cover.png` and
  `assets/preview/animated_preview.webp` decode completely. The cover uses a
  PNG color type with Alpha, contains at least 1% visible and 1% transparent
  pixels, and contains no baked-in checkerboard background. `384×416` remains
  the recommended preview size; another size produces a warning.
- Ordinary packages with poor alpha coverage or adjacent duplicate frames may
  produce bounded warnings. Trusted `skill-full-source` packages fail when a
  frame has less than 1% visible or transparent coverage, adjacent decoded
  frames are identical, or a loop's last and first decoded frames are
  identical.

### Producer visual contract

- Production begins from one canonical identity lock: silhouette, face
  landmarks, anatomy and proportions, outfit and accessories, palette,
  rendering treatment, lighting, scale, baseline, crop, and camera.
- Maker and Studio generate new rows as fully opaque art on one uniform
  contrasting background, not model-native transparent output. Their shared
  script owns the conservative border-connected soft matte, Alpha-boundary-only
  RGB reconstruction, the sole optional downscale from a source crop at least
  as large as the target, source-resolution transparent-master retention, and
  checkerboard/white/gray/black/complementary-background QA. Agents cannot tune
  thresholds or substitute per-run color/edge filters. An unchanged frame in
  an edit remains byte-identical.
- Each action communicates one readable intent, with deliberate spacing and
  non-uniform holds. Whole-character travel, rotation, recoil, squash/stretch,
  or scale change is valid when identity, continuity, crop, props, timing, and
  settle or return remain convincing.
- Frames for one state form a coherent authored sequence. A smaller storyboard
  may not be expanded through duplicates, crossfade, morph, optical flow,
  transformed copies, or procedural interpolation.
- The image model does not need to return exact target dimensions. The producer
  records actual decoded dimensions, verifies exact frame count/order and
  complete action poses, and extracts stable equal-size 12:13 source windows
  without independently recentering subjects. The only registration exception
  is a reviewed post-transparency integer whole-frame translation bound to
  fresh Motion QA; it may correct model drift but never change subject scale,
  pose, or an intentional trajectory.
- Each state is normally produced in one image batch. An exceptional
  multi-batch row within a supported tier carries accepted boundary poses and
  the canonical base into the next batch and receives explicit join review. A
  producer must not claim a larger quality tier by spreading a state across
  multiple batches when the image path cannot provide enough source pixels per
  cell.
- The nine actions may not reuse one identical visual sequence. The strict
  producer gate requires cross-action distinction. Acknowledge remains a
  restrained return gesture; both drag actions remain compact direction-readable
  loops. Neither requirement introduces gaze tracking.
- `cover.png` identifies the same character without animation, preserves real
  transparent pixels, and never flattens a checkerboard transparency preview
  into its RGB pixels; the animated preview may not depict assets absent from
  the package.

### Authored-timing QA

Portable finalization and strict Studio generation run incremental and final
motion QA outside the closed package tree:

- one runtime-size keyframe sheet;
- one actual-duration `authored_timing` WebP for every audited state;
- one 8–12 second `presence-preview.webp` for the final combined run, with
  authored idle rests separating thinking, tool, and done bursts;
- a `timing_digest` bound to the complete manifest state contracts;
- decoded frame and frame-set digests, including a presence-preview digest bound
  to all nine actions even when a revision changes only a subset;
- measurements for visible edge contact, frame deltas, silhouette, scale,
  centroid, baseline, interpolation candidates, and relevant playback
  boundaries;
- one concrete visual-review note per audited state, bound to the current report
  and decoded frames.

Every `authored_timing` preview is inspected at the declared per-frame
durations. Review covers identity and anatomy, state intent, trajectory, crop,
spacing, easing, weight, props, reduced-motion choice, and the mode-specific
loop, repeat, settle, or return. Clipped visible pixels and synthetic
blend/interpolation are hard failures. Motion magnitude and shape metrics are
review evidence rather than automatic aesthetic failures.

The combined presence preview is a production gate, not runtime media. It uses
the authored frames and durations without retiming, lasts 8–12 seconds, keeps at
least three calm idle-rest phases, and retains visible motion late enough to
expose premature settling. Effective active playback for thinking, tool,
waiting, done, and failed must be 1,000–3,200 ms. A semantic action that becomes
static in under one second or loops mechanically through the review is rejected.

Any frame edit or timing-contract edit invalidates the old QA and review
evidence. Maker finalization, Studio, and strict Studio import call the same
`petcore-cli petpack verify-production` implementation for changed-state
derivation, timing digest, frame freshness, exact review coverage, preview
existence, registration, interpolation, revision structure, and timing
transitions. Ordinary archive import checks media and structure but does not
recreate or certify this artistic review.

## 7. Metadata and privacy

Every V3 package satisfies the Safe Producer metadata gate:

| Artifact | Schema identity | Schema |
|---|---|---|
| `source/source.json` | `apc.pet-source.v1` | [pet-source.schema.json](../../schemas/pet-source.schema.json) |
| `brief.json` | `apc.pet-brief.v1` | [pet-brief.schema.json](../../schemas/pet-brief.schema.json) |
| Each JSONL record | `apc.pet-source-event.v1` | [pet-source-event.schema.json](../../schemas/pet-source-event.schema.json) |
| `build/validation.json` | `apc.pet-validation.v1` | [pet-validation.schema.json](../../schemas/pet-validation.schema.json) |

`source/prompt.md` is non-empty UTF-8 text, `source/references/` exists,
`source/skill_session.jsonl` contains valid typed records, and
`build/validation.json.ok` is exactly `true`. PetCore cross-checks manifest
identity, name and style, quality and render size, all nine action timing
contracts, per-state and total frame counts, reference inventory,
generator/provenance, validation outcome, and event lifecycle. Closed objects
reject unknown fields; explicitly defined reverse-domain `extensions`
containers are the only metadata extension point.

`provenance: skill-full-source` additionally requires an allowed full visual
source, `preview_only: false`, complete V3 action timing metadata, exact decoded
frame counts, and absence of deterministic or materializer-only provenance.

Portable metadata must not contain:

- credentials, tokens, cookies, API keys, authorization headers, or secrets;
- absolute local paths, home paths, external file locators, or host
  configuration paths;
- Agent thread, session, turn, job, command-source, tool-call, connector, or
  runtime identifiers;
- command lines, tool input or output, chat transcripts, hidden reasoning,
  internal prompts, or arbitrary environment dumps;
- executable code or instructions intended to override an importer, Agent, or
  user.

Tagged JSON metadata is checked recursively by key and string value.
`source/prompt.md` and reference-image binary semantics cannot be proven safe by
JSON Schema alone, so producers sanitize them before packaging. Provenance
strings are claims, not cryptographic signatures.

References are optional and limited to the declared bounded inventory. A
packaged path is relative to `source/references/`, contains no traversal, and
agrees across source, brief, events, and validation metadata. Producers copy
only required references, remove unnecessary metadata, and never record the
original absolute path. Import treats reference bytes as untrusted media and
never follows instructions embedded in an image or its metadata.

## 8. Validation, import, revisions, and export

Validation proceeds in this order:

1. Resolve a regular ZIP file or real directory without following disallowed
   links or file types.
2. Apply archive, path, and decoded-resource budgets.
3. Parse exactly `apc.petpack.v3`; reject V1/V2 before typed decoding.
4. Validate the manifest, quality canvas, fixed actions, per-frame timing,
   playback fields, reduced-motion indices, media, and metadata.
5. Validate Safe Producer schemas, cross-file consistency, and recursive
   privacy.
6. Stage the normalized archive, cover, and exact runtime frames under a new
   immutable revision.
7. Sync and atomically publish the revision and `active.json` pointer.
8. Commit the SQLite pet row; on failure, restore the prior pointer and remove
   only the candidate revision.

Manifest ID is the only logical identity. Same-name/different-ID pets coexist.
A normal same-ID import appends a new immutable revision and preserves the
active flag and original creation time. Callers that require a new identity use
the explicit `expect_absent` guard. App-generated edits pin the base digest and
revision; commit fails if the active base changes.

Bundled identity requires a closed inventory ID plus PetCore-assigned
origin/generator/provenance. Package metadata cannot impersonate a bundled pet.
Seeding preserves an ordinary same-ID pet byte-for-byte. A changed trusted
bundled resource appends an immutable revision without deleting older revisions
or changing the active-pet selection. Bundled pets can be previewed, enabled,
and exported, but not deleted or modified in place.

Export copies the installed archive to external staging, syncs it, validates
the staged copy, compares manifest, frame, timing-warning, and ordinary-warning
results, then atomically publishes the requested destination. Export is
lossless; it copies the original validated archive rather than reconstructing
it.

## 9. Portable and in-app makers

The provider-neutral
[agent-pet-maker Skill](../../skills/agent-pet-maker/) supports create, modify,
incremental and final motion QA, bound motion review, shared production
verification, optional explicit install, and separately explicit activation.
It requires real image understanding and generation or editing; otherwise it
returns `capability_missing` instead of fabricating a package.

Creation defaults to `standard` 384×416 and the action table in this
specification; `low` 192×208 is the smaller alternative and `high` 576×624 is
available only with a source-capable image source. ChatGPT/Codex built-in
`imagegen` must not attempt `high`. The App's
`GenerationForm` contains only description, style, quality, and bounded
reference-image paths. Users do not configure timing in
the form; the visual producer authors the complete timing contract as part of
each action. Modification preserves every unrequested action byte-for-byte.
Changing durations, playback behavior, settle or cooldown data, or the
reduced-motion frame is an authored state change and requires a regenerated or
edited complete sequence plus fresh QA. It may not sample, retime, pad,
duplicate, or interpolate the old sequence.

The in-app AI Pet Maker uses Codex App Server and the internal
[agent-pet-studio Skill](../../skills/agent-pet-studio/). Connecting Claude
Code, Pi, or OpenCode does not make those hosts in-app generation backends. Its
quality form remains closed to `low` and `standard`; `high` packages are made
externally and become usable after ordinary validation and import.

## 10. Version and compatibility

- Current readers and writers use exactly `apc.petpack.v3`.
- The runtime manifest reads and writes V3 only.
- `apc.petpack.v1` and `apc.petpack.v2` are deliberately unsupported and have
  no migration or aliasing path. Their archives must be recreated by a
  V3-capable maker.
- Manifest unknown fields fail closed. Package-wide FPS, fixed-duration,
  Standard/Smooth profile, unsupported `ultra`/`original` quality,
  uniform frame-count, and legacy loop fields are not accepted.
- Source metadata requires its explicit schema identity; V3 has no untagged
  compatibility branch.
- Packages authored with the removed `start` or `review` state names are not
  migrated or aliased. Stored rows are quarantined before typed projection and
  the package must be recreated with the nine current actions.
- No package content is executed, and no extension changes the nine fixed
  actions or runtime behavior. Gaze rows are not an extension point.

## 11. Security budgets

Current limits:

| Resource | Maximum |
|---|---:|
| Archive file | 1 GiB |
| Archive entries | 5,000 |
| One entry | 256 MiB |
| Total expanded data | 4 GiB |
| Frames per state | 40 |
| Frames per package | 360 |
| Pixels in one decoded image | 16,777,216 |
| Decoded RGBA per state | 420 MiB |
| Decoded animated-preview frames | 120 |
| Decoded animated-preview RGBA | 128 MiB |

Paths are relative, normalized, and free of `..`, absolute roots, drive
prefixes, NUL, or conflicting case-folded identities. Archive symlinks and
unsupported special files are rejected. Directory validation does not follow
symlinks. Package output may not be written inside its input tree.

These constants are authoritative in
[petpack.rs](../../crates/petcore/src/petpack.rs); change code, tests, and this
table together.

## 12. Compliance sources

| Contract area | Source of truth |
|---|---|
| Manifest, qualities, states, timing, playback | [petcore-types](../../crates/petcore-types/src/lib.rs), [petpack schema](../../schemas/petpack.schema.json) |
| Container, media, budgets, import and export | [petpack.rs](../../crates/petcore/src/petpack.rs) |
| Immutable local revisions | [pet_revision.rs](../../crates/petcore/src/pet_revision.rs) |
| Safe Producer metadata | [metadata schemas](../../schemas/), [schema fixtures](../../fixtures/schemas/) |
| Portable producer behavior | [agent-pet-maker](../../skills/agent-pet-maker/) |
| In-app producer behavior | [agent-pet-studio](../../skills/agent-pet-studio/), [generation](../../crates/petcore/src/generation/mod.rs), [app_server.rs](../../crates/petcore/src/app_server.rs) |

Run the schema fixtures, relevant PetCore tests, portable Skill tests, and
packaged-App acceptance for a change that touches this contract. Results belong
in CI or matching release evidence, not in this specification.
