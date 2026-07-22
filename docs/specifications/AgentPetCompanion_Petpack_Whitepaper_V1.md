# Agent Pet Companion `.petpack` V1 Specification

Schema identity: `apc.petpack.v1`

`.petpack` is Agent Pet Companion's app-owned, portable desktop-pet container. It is a ZIP archive containing a strict manifest, seven fixed animation states, static and animated previews, provenance metadata, a privacy-safe production event stream, and validation metadata. Package content is untrusted data and is never executed.

This document defines the current V1 reader, writer, and producer contract. Exact enforcement lives in [PetManifest](../../crates/petcore-types/src/lib.rs), [petpack.rs](../../crates/petcore/src/petpack.rs), [JSON Schemas](../../schemas/), and their fixtures/tests.

## 1. Conformance profiles

| Profile | Meaning |
|---|---|
| Runtime package | Passes the container, path, budget, manifest, media, baseline metadata, and import checks required by PetCore. |
| Safe Producer | `source/source.json` declares `apc.pet-source.v1`; all four metadata schemas, cross-file consistency, and recursive privacy checks pass. |
| Verified visual source | Safe Producer package with trusted full-source provenance, at least two visibly different frames per state, and sufficient differences across states. The strict in-app Studio path enforces this profile; ordinary import does not certify artistic quality. |
| Untagged V1 compatibility | `source/source.json` has no `schema_version`; PetCore applies the baseline metadata gate so existing V1 archives remain importable. It does not grant Safe Producer status. |

An unknown, malformed, older, or newer explicit source metadata version fails closed; it never silently falls back to the untagged compatibility profile.

## 2. Container identity

| Property | Contract |
|---|---|
| Filename extension | `.petpack`, checked case-insensitively by App import UI |
| Container | ZIP with `/` path separators |
| Development input | Validators/builders also accept an unpacked directory |
| UTI | `dev.agentpet.petpack`, conforming to `public.data` |
| MIME tag | `application/vnd.agentpet.petpack+zip` |

The archive is the portable exchange unit. A directory is only a trusted local build/validation input.

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

All listed files and directories are required; `source/references/` may be empty. State directories are flat and may not contain nested directories. Files with a case-insensitive `.png` suffix are frames; other direct files are ignored by the current runtime and therefore must not carry required semantics.

The runtime permits unknown root data files except explicit compatibility-package names such as `.codex-plugin`, `hooks`, `skills`, `codex-pet.json`, `codex_pet.json`, and `pet.json`, which are rejected. Conforming producers must not add undeclared root files. Extension data belongs under `extensions/<reverse-dns>/` and remains non-executable data.

## 4. Manifest contract

[`schemas/petpack.schema.json`](../../schemas/petpack.schema.json) and Rust `PetManifest` define `manifest.json`. Unknown fields are rejected.

| Field | Contract |
|---|---|
| `schema_version` | Exactly `apc.petpack.v1` |
| `id` | `^pet_[a-z0-9]+$`, at most 128 characters; stable logical identity |
| `name` | Non-blank display name; not unique |
| `style` | Non-blank display/production style |
| `quality` | `standard`, `high`, `ultra`, or `original` |
| `render_size` | Exact size for `quality` |
| `fps_profiles` | Semantically exactly `standard: 12` and `smooth: 20` |
| `default_fps_profile` | Exactly `standard` |
| `states` | Exactly the seven unique states and fixed directories/loop flags below |
| `created_at` | RFC 3339 timestamp |

### Quality and canvas

| Quality | Width | Height |
|---|---:|---:|
| `standard` | 192 | 208 |
| `high` | 384 | 416 |
| `ultra` | 768 | 832 |
| `original` | 1536 | 1664 |

Every state uses the same canvas. Producers must keep the character anchor, baseline, and visible scale stable across states to prevent jumps during transitions.

### States

| State | `frames_dir` | `loop` | Runtime meaning |
|---|---|---:|---|
| `idle` | `assets/frames/idle` | `true` | No active Agent event |
| `start` | `assets/frames/start` | `false` | Task or reasoning starts |
| `tool` | `assets/frames/tool` | `true` | Tool/work activity |
| `waiting` | `assets/frames/waiting` | `true` | User input or confirmation required |
| `review` | `assets/frames/review` | `true` | Result ready for review |
| `done` | `assets/frames/done` | `false` | Successful completion transition |
| `failed` | `assets/frames/failed` | `true` | Failure or blocking error |

State array order is not semantic, but writers use the table order for deterministic output and review.

## 5. Frames and previews

### Runtime media gate

- Every state contains at least one decodable PNG.
- Each PNG's pixel dimensions exactly match `render_size`.
- A single-frame state is accepted with a static-animation warning.
- Runtime frame ordering is natural filename order. Producers use zero-padded ASCII names such as `0000.png` and `0001.png`.
- `assets/preview/cover.png` and `assets/preview/animated_preview.webp` must decode completely. `384×416` is the recommended preview size; another size produces a warning.

### Producer visual contract

- Frame PNGs have an alpha channel, transparent background, and a visible subject fully inside the canvas.
- A full visual source has at least two frames per state and at least one decoded pixel change within every state.
- The seven states may not reuse one identical visual sequence. The strict Studio path requires at least four states to have different first-frame decoded digests.
- `cover.png` identifies the same character without animation; the animated preview may not depict assets absent from the package.

Ordinary runtime import verifies decodability, dimensions, structure, and budgets. It does not certify motion quality, anchor stability, alpha visibility, or cross-state artistic distinction. Do not present a normal import result as Verified visual source evidence.

## 6. Metadata and privacy

### Baseline metadata gate

Every package, including the untagged compatibility profile, must satisfy:

| File | Baseline requirement |
|---|---|
| `brief.json` | Valid JSON |
| `source/prompt.md` | Non-empty UTF-8 text |
| `source/source.json` | Valid JSON with non-blank `generator` and `provenance` strings |
| `source/references/` | Directory exists |
| `source/skill_session.jsonl` | Every non-empty line is JSON; at least one line has a string `event` |
| `build/validation.json` | Valid JSON with `ok` exactly `true` |

### Safe Producer metadata

When `source/source.json.schema_version` is `apc.pet-source.v1`, PetCore applies all four Draft 2020-12 schemas:

| Artifact | Schema identity | Schema |
|---|---|---|
| `source/source.json` | `apc.pet-source.v1` | [pet-source.schema.json](../../schemas/pet-source.schema.json) |
| `brief.json` | `apc.pet-brief.v1` | [pet-brief.schema.json](../../schemas/pet-brief.schema.json) |
| Each JSONL record | `apc.pet-source-event.v1` | [pet-source-event.schema.json](../../schemas/pet-source-event.schema.json) |
| `build/validation.json` | `apc.pet-validation.v1` | [pet-validation.schema.json](../../schemas/pet-validation.schema.json) |

PetCore also checks cross-artifact identity, name/style, quality, render size, FPS, state coverage, reference counts/paths, generator/provenance, validation outcome, and event lifecycle. Closed schema objects reject unknown fields; optional extensions use the schema's explicit reverse-domain-keyed `extensions` container.

`provenance: skill-full-source` additionally requires:

- `visual_source` is `image-generation` or `user-reference-derived`;
- `frames_per_state` is at least 2;
- `preview_only` is `false`;
- deterministic/materializer-only provenance fields are absent.

### Content hygiene

Portable metadata must not contain:

- credentials, tokens, cookies, API keys, authorization headers, or secret material;
- absolute local paths, home-directory paths, external file locators, or host configuration paths;
- Agent thread/session/turn/job IDs, command sources, tool-call IDs, or runtime connector identifiers;
- command lines, tool input/output, chat transcripts, hidden reasoning, internal prompts, or arbitrary environment dumps;
- executable code or instructions intended to override an importer, Agent, or user.

Tagged metadata is recursively checked by key and string value. `source/prompt.md` and reference-image binary semantics cannot be fully proven safe by JSON Schema, so the producer must sanitize them before packaging. `generator` and `provenance` are provenance claims, not cryptographic signatures.

## 7. Reference images

References are optional and limited to the package's declared/bounded count. A packaged reference path is relative to `source/references/`, contains no traversal, and agrees across source metadata, brief, events, and validation.

Producers copy only references that are required to understand or reproduce the visual result. They remove unnecessary metadata and never record the original absolute path. Import treats reference bytes as untrusted media data and never follows instructions embedded in the image or metadata.

## 8. Validation, import, revision, and export

### Validation sequence

1. Resolve a regular ZIP file or real directory without following disallowed link/file types.
2. Apply archive/path and decoded-resource budgets.
3. Validate manifest, fixed states, media, and baseline metadata.
4. If tagged, validate Safe Producer schemas, consistency, and recursive privacy.
5. Stage normalized package, cover, and runtime frame cache under a new revision.
6. Sync and atomically publish the revision and `active.json` pointer.
7. Commit the SQLite pet row; on failure, restore the pointer and remove the candidate revision.

The pet-store lock serializes imports, edits, deletion, and explicit offline maintenance. Package validation and library mutation are separate: a valid package is not active until the corresponding operation commits it.

### Identity and conflicts

- Manifest ID is the only logical identity. Same-name/different-ID pets coexist.
- A normal same-ID import appends a new immutable revision and preserves the pet's active flag and original creation time.
- Callers that require a new identity use the explicit `expect_absent` guard, which rejects an existing ID.
- App-generated edits pin the base digest and revision; commit fails if the active base changed while the edit was running.
- Bundled inventory seeding preserves an existing same-ID pet byte-for-byte, is idempotent, and never selects by name.
- Bundled read-only identity requires both a fixed inventory ID and PetCore-assigned identity markers. Package metadata cannot impersonate a bundled pet.
- Bundled pets may be previewed, enabled, and exported, but not deleted or modified under the reserved same ID.

### Export and round trip

Export copies the installed archive to staging outside the managed pet root, syncs it, validates the staged copy, compares manifest/frame/warning results, then atomically publishes the requested destination. Export is lossless; unknown compatibility data remains byte-for-byte because the original archive is copied rather than reconstructed.

## 9. Portable Agent maker

The provider-neutral [agent-pet-maker Skill](../../skills/agent-pet-maker/) supports:

- `create`: generate a new package identity;
- `modify`: safely unpack a validated package, preserve its ID and contract, and verify every state not requested for change is byte-identical;
- optional `install`: import only after explicit user authorization;
- optional activation: a second explicit user choice, never implied by generation or install.

The Skill requires real image understanding/generation/editing for visual work. When unavailable, it returns `capability_missing` instead of fabricating a package. All output still crosses `petcore-cli petpack validate` and the normal PetCore import boundary.

The in-app AI Pet Maker uses Codex App Server and the internal [agent-pet-studio Skill](../../skills/agent-pet-studio/). Connecting Claude Code, Pi, or OpenCode does not make those hosts in-app generation backends.

## 10. Version and compatibility

- V1 readers and writers use exactly `apc.petpack.v1`; unknown manifest versions fail closed.
- The runtime manifest declares `petpack_read_versions` and `petpack_write_version`. The current set reads and writes only V1.
- Manifest unknown fields fail closed. Tagged metadata unknown fields fail closed except inside explicitly defined extension containers.
- Untagged source metadata follows the baseline compatibility gate and does not gain Safe Producer status on import or export.
- No package content is executed, and no unknown extension changes the seven core states or runtime behavior.
- A format-version change requires a new schema identity, explicit reader/writer compatibility, fixtures, migration/round-trip tests, and a runtime-manifest update. It may not silently relax V1.

## 11. Security budgets

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

Paths must be relative, normalized, and free of `..`, absolute roots, drive prefixes, NUL, or conflicting case-folded identities. Archive symlinks and unsupported special files are rejected. Directory validation does not follow symlinks. Package output may not be written inside its input tree.

These constants are authoritative in [petpack.rs](../../crates/petcore/src/petpack.rs); change code, tests, and this table together.

## 12. Compliance sources

| Contract area | Source of truth |
|---|---|
| Manifest, states, quality, FPS | [petcore-types](../../crates/petcore-types/src/lib.rs), [petpack schema](../../schemas/petpack.schema.json) |
| Container, media, budgets, import/export | [petpack.rs](../../crates/petcore/src/petpack.rs) |
| Immutable local revisions | [pet_revision.rs](../../crates/petcore/src/pet_revision.rs) |
| Safe Producer metadata | [metadata schemas](../../schemas/), [schema fixtures](../../fixtures/schemas/) |
| Portable producer behavior | [agent-pet-maker](../../skills/agent-pet-maker/) |
| In-app producer behavior | [agent-pet-studio](../../skills/agent-pet-studio/), [generation.rs](../../crates/petcore/src/generation.rs), [app_server.rs](../../crates/petcore/src/app_server.rs) |

Run `./script/validate_schema_fixtures.sh`, relevant PetCore tests, portable Skill tests, and packaged-App acceptance for a change that touches this contract. Results belong in CI or the matching release evidence, not in this specification.

## 13. Producer checklist

- [ ] Archive identity, layout, and manifest exactly match V1.
- [ ] ID is stable and not selected from the display name.
- [ ] Quality, canvas, seven states, directories, loop flags, and 12/20 FPS match.
- [ ] Frames and previews decode within budgets; transparent visual assets are coherent and visibly animated when claiming full-source provenance.
- [ ] Baseline metadata is complete; tagged metadata passes all schemas and cross-file checks.
- [ ] References and natural-language text are intentionally included and sanitized.
- [ ] No credentials, local paths, runtime identifiers, transcripts, commands, tool data, hidden reasoning, or executable content are present.
- [ ] Build, validate, import, activate, render all states, export, and reimport succeed in an isolated home.
- [ ] Creation/modification does not mutate the user's library without explicit import, and activation remains a separate explicit choice.
