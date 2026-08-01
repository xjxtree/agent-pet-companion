# Agent Pet Companion `.petpack` V2 Specification

Schema identity: `apc.petpack.v2`

`.petpack` is Agent Pet Companion's app-owned, portable desktop-pet container.
It is a ZIP archive containing a strict manifest, seven fixed animation states,
static and animated previews, privacy-bounded production metadata, and
validation metadata. Package content is untrusted data and is never executed.

This document defines the current V2 reader, writer, runtime, and producer
contract. Exact enforcement lives in
[PetManifest](../../crates/petcore-types/src/lib.rs),
[petpack.rs](../../crates/petcore/src/petpack.rs),
[JSON Schemas](../../schemas/), and their fixtures and tests.

## 1. Conformance profiles

| Profile | Meaning |
|---|---|
| Runtime package | Passes the container, path, budget, manifest, media, metadata, and import checks required by PetCore. |
| Safe Producer | `source/source.json` declares `apc.pet-source.v1`; all four metadata schemas, cross-file consistency, and recursive privacy checks pass. V2 has no untagged metadata compatibility profile. |
| Verified visual source | Safe Producer package with trusted full-source provenance, an exact authored frame inventory, visibly distinct adjacent motion, current `authored_timing` QA, and complete per-state visual review. The strict Studio and portable Maker paths enforce this profile; ordinary import does not certify artistic quality. |

An unknown, malformed, older, or newer manifest or source-metadata version
fails closed. In particular, PetCore does not read or migrate
`apc.petpack.v1`; the user-facing validation error directs the user to recreate
the pet with the V2 maker.

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
│   │   ├── start/*.png
│   │   ├── tool/*.png
│   │   ├── waiting/*.png
│   │   ├── review/*.png
│   │   ├── done/*.png
│   │   └── failed/*.png
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
| `schema_version` | Exactly `apc.petpack.v2` |
| `id` | `^pet_[a-z0-9]+$`, at most 128 characters; stable logical identity |
| `name` | Non-blank display name; not unique |
| `style` | Non-blank visual or production style |
| `quality` | Exactly `low` or `standard` |
| `render_size` | Exact canvas for the selected quality |
| `states` | Exactly one of each fixed state, with the fixed directory and a complete timing contract |
| `created_at` | RFC 3339 timestamp |

There is no package-wide FPS, duration, playback profile, or uniform frame
count. Every state owns its complete authored timing.

### Quality and native canvas

| Quality | Width | Height | Selection guidance |
|---|---:|---:|---|
| `low` | 192 | 208 | Minimal, pixel-focused, or resource-sensitive characters; 1:1 through 96 pt at 2× |
| `standard` | 384 | 416 | Default for most characters; 1:1 through 192 pt at 2× |

Both tiers are 12:13 and their widths are multiples of 192. One package uses one
tier for every frame. `render_size` is both the exact decoded PNG size and the
minimum native source-pixel crop for every accepted frame. A producer may crop
an exact target-size rectangle from a larger decoded source. Upscaling,
super-resolution, stretching, resampling, or padding a smaller crop into the
target canvas is invalid. The currently qualified image path does not preserve
native 576×624 cells in an eight-cell state sheet, so V2 has no `high` tier;
splitting that state across multiple batches is not a substitute for missing
native single-batch capacity. The qualification evidence and rerun conditions
are documented in [Validation Profiles](../development/validation.md).

Display size is a separate App preference and never changes package identity or
authored pixels. The App exposes an 80–224 pt logical-width slider; it does not
rewrite, upscale, or retime a package.

### Fixed states and defaults

The seven state names and directories are fixed. State array order is not
semantic, but writers use this order for deterministic output and review.

| State | `frames_dir` | Default `frame_durations_ms` | Default playback | Reduced-motion index |
|---|---|---|---|---:|
| `idle` | `assets/frames/idle` | `[180, 160, 180, 380]` | `periodic`, cooldown `[4000, 8000]` | 2 |
| `start` | `assets/frames/start` | `[120, 140, 160, 180]` | `once_hold`, settle 3 | 2 |
| `tool` | `assets/frames/tool` | `[150, 150, 170, 330]` | `burst_then_settle`, repeat 1, settle 3 | 2 |
| `waiting` | `assets/frames/waiting` | `[150, 150, 150, 150, 170, 230]` | `once_hold`, settle 5 | 4 |
| `review` | `assets/frames/review` | `[140, 140, 150, 150, 180, 240]` | `once_hold`, settle 5 | 4 |
| `done` | `assets/frames/done` | `[120, 140, 160, 230]` | `once_hold`, settle 3 | 2 |
| `failed` | `assets/frames/failed` | `[150, 170, 190, 290]` | `once_hold`, settle 3 | 2 |

These defaults are a production starting point, not a reason to make every pet
move identically. A producer may author another valid rhythm and playback
contract when it better expresses the character.

## 5. Per-state timing and playback

Every state object contains:

```json
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
| `once_hold` | Play once, then hold a declared pose | `settle_frame_index` | repeat, cooldown |
| `periodic` | Play once, wait a randomized bounded cooldown, then repeat | `cooldown_ms` | repeat, settle |
| `burst_then_settle` | Repeat the authored burst a fixed number of times, then hold | `entry_repeat_count`, `settle_frame_index` | cooldown |

The runtime uses the authored duration of each frame directly. It never samples,
subsamples, duplicates, interpolates, or retimes frames and exposes no
Standard/Smooth playback choice. An unchanged semantic state does not restart.
After a rendering stall, playback resumes from the currently due frame without
rapidly presenting missed frames. Reduce Motion presents only the declared
representative frame.

The following common production targets are warnings, not package validity
limits: 4–8 authored frames, at most about 1,500 ms, and an average effective
rate of 4–12 frames per second. A valid action outside those ranges remains
importable when its structural contract is sound.

`animated_preview.webp` is a non-authoritative display asset. Its codec timing
must not be used to infer runtime timing.

## 6. Media and visual-production contract

### Runtime media gate

- Each frame is a decodable PNG whose dimensions exactly match `render_size`.
- Frame ordering uses the same deterministic ASCII natural comparator in
  PetCore, the Maker Skill, and macOS playback. Producers use zero-padded ASCII
  names such as `0000.png` and `0001.png`.
- `assets/preview/cover.png` and
  `assets/preview/animated_preview.webp` decode completely. `384×416` remains
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
- Each state communicates one readable intent, with deliberate spacing and
  non-uniform holds. Whole-character travel, rotation, recoil, squash/stretch,
  or scale change is valid when identity, continuity, crop, props, timing, and
  settle or return remain convincing.
- Frames for one state form a coherent authored sequence. A smaller storyboard
  may not be expanded through duplicates, crossfade, morph, optical flow,
  transformed copies, or procedural interpolation.
- Each state is normally produced in one image batch. An exceptional
  multi-batch row within a supported tier carries accepted boundary poses and
  the canonical base into the next batch and receives explicit join review. A
  producer must not claim a larger quality tier by spreading a state across
  multiple batches when the image path cannot provide the required native cell
  size.
- The seven states may not reuse one identical visual sequence. The strict
  producer gate requires cross-state distinction.
- `cover.png` identifies the same character without animation; the animated
  preview may not depict assets absent from the package.

### Authored-timing QA

Portable finalization and strict Studio generation run incremental and final
motion QA outside the closed package tree:

- one runtime-size keyframe sheet;
- one actual-duration `authored_timing` WebP for every audited state;
- a `timing_digest` bound to the complete manifest state contracts;
- decoded frame and frame-set digests;
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

Any frame edit or timing-contract edit invalidates the old QA and review
evidence. Maker finalization, Studio, and strict Studio import call the same
`petcore-cli petpack verify-production` implementation for changed-state
derivation, timing digest, frame freshness, exact review coverage, preview
existence, registration, interpolation, revision structure, and timing
transitions. Ordinary archive import checks media and structure but does not
recreate or certify this artistic review.

## 7. Metadata and privacy

Every V2 package satisfies the Safe Producer metadata gate:

| Artifact | Schema identity | Schema |
|---|---|---|
| `source/source.json` | `apc.pet-source.v1` | [pet-source.schema.json](../../schemas/pet-source.schema.json) |
| `brief.json` | `apc.pet-brief.v1` | [pet-brief.schema.json](../../schemas/pet-brief.schema.json) |
| Each JSONL record | `apc.pet-source-event.v1` | [pet-source-event.schema.json](../../schemas/pet-source-event.schema.json) |
| `build/validation.json` | `apc.pet-validation.v1` | [pet-validation.schema.json](../../schemas/pet-validation.schema.json) |

`source/prompt.md` is non-empty UTF-8 text, `source/references/` exists,
`source/skill_session.jsonl` contains valid typed records, and
`build/validation.json.ok` is exactly `true`. PetCore cross-checks manifest
identity, name and style, quality and render size, all seven state timing
contracts, per-state and total frame counts, reference inventory,
generator/provenance, validation outcome, and event lifecycle. Closed objects
reject unknown fields; explicitly defined reverse-domain `extensions`
containers are the only metadata extension point.

`provenance: skill-full-source` additionally requires an allowed full visual
source, `preview_only: false`, complete V2 state timing metadata, exact decoded
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
3. Parse exactly `apc.petpack.v2`; reject V1 before typed decoding.
4. Validate the manifest, quality canvas, fixed states, per-frame timing,
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

Creation defaults to `standard` 384×416 and the state table in this
specification; `low` 192×208 is the smaller alternative. The App's
`GenerationForm` contains only description, style, quality, and bounded
reference-image paths. Users do not configure timing in
the form; the visual producer authors the complete timing contract as part of
each state. Modification preserves every unrequested state byte-for-byte.
Changing durations, playback behavior, settle or cooldown data, or the
reduced-motion frame is an authored state change and requires a regenerated or
edited complete sequence plus fresh QA. It may not sample, retime, pad,
duplicate, or interpolate the old sequence.

The in-app AI Pet Maker uses Codex App Server and the internal
[agent-pet-studio Skill](../../skills/agent-pet-studio/). Connecting Claude
Code, Pi, or OpenCode does not make those hosts in-app generation backends.

## 10. Version and compatibility

- Current readers and writers use exactly `apc.petpack.v2`.
- The runtime manifest reads and writes V2 only.
- `apc.petpack.v1` is deliberately unsupported and has no migration path. A V1
  archive must be recreated by a V2-capable maker.
- Manifest unknown fields fail closed. Package-wide FPS, fixed-duration,
  Standard/Smooth profile, unsupported `high`/`ultra`/`original` quality,
  uniform frame-count, and legacy loop fields are not accepted.
- Source metadata requires its explicit schema identity; V2 has no untagged
  compatibility branch.
- No package content is executed, and no extension changes the seven core
  states or runtime behavior.

## 11. Security budgets

These limits are unchanged from the preceding format:

| Resource | Maximum |
|---|---:|
| Archive file | 1 GiB |
| Archive entries | 5,000 |
| One entry | 256 MiB |
| Total expanded data | 4 GiB |
| Frames per state | 40 |
| Frames per package | 280 |
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
| In-app producer behavior | [agent-pet-studio](../../skills/agent-pet-studio/), [generation.rs](../../crates/petcore/src/generation.rs), [app_server.rs](../../crates/petcore/src/app_server.rs) |

Run the schema fixtures, relevant PetCore tests, portable Skill tests, and
packaged-App acceptance for a change that touches this contract. Results belong
in CI or matching release evidence, not in this specification.

## 13. Producer checklist

- [ ] Archive identity, layout, metadata, and manifest exactly match V2.
- [ ] ID is stable and is not derived from the display name.
- [ ] Quality and exact canvas are low 192×208 or standard 384×416.
- [ ] All seven fixed states declare valid per-frame durations, playback fields, and a representative reduced-motion frame.
- [ ] Every state has exactly one PNG per duration entry; frames and previews decode within the unchanged budgets.
- [ ] One canonical identity, readable state intent, coherent trajectory and crop, deliberate spacing, and prop continuity are explicit for every generated state.
- [ ] Every actual-duration `authored_timing` preview and the keyframe sheet were inspected; `timing_digest`, frame digests, and per-state review are current.
- [ ] No state was fabricated through sampling, retiming, duplicates, interpolation, or an undersized source crop.
- [ ] Metadata passes all schemas, cross-file consistency, privacy checks, and reference bounds.
- [ ] No credentials, local paths, runtime identifiers, transcripts, commands, tool data, hidden reasoning, or executable content are present.
- [ ] Build, validate, import, activate, render all states, export, and reimport succeed in an isolated home.
- [ ] Creation or modification does not mutate the user's library without explicit import, and activation remains a separate explicit choice.
