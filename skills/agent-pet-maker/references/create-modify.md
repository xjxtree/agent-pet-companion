# Create and modify `.petpack` V3

## Contents

1. Shared workspace flow
2. Create
3. Modify
4. Motion QA and production verification
5. Finalize, result, and install

Read
[visual-production-and-native-resolution.md](visual-production-and-native-resolution.md)
and
[transparent-frame-production.md](transparent-frame-production.md) with this
workflow. They own source-capacity proof, deterministic source-to-runtime
normalization, transparent-frame derivation, and visual acceptance.

## Shared workspace flow

1. Run `preflight`.
2. Run `prepare` into an absent or empty private workspace.
3. Work only below `<workspace>/petpack-source`.
4. Keep raw generator outputs, rejection notes, Motion QA, review evidence, and
   result sidecars outside that source root.
5. Generate one state per batch. Decode and inspect the batch before any later
   image call.
6. Crop in source pixels and run `prepare_transparent_frames.py`; accept only a
   passing report and inspected multi-background previews.
7. Run `motion-qa --state <state>` after each accepted state.
8. Run combined `motion-qa`, inspect every `authored_timing` preview and the
   8–12 second all-action presence preview, then bind `motion-review`.
9. Run `finalize`. Do not hand-build or edit the resulting archive.

The helper never generates artwork. Use real image generation/editing and real
image understanding. Return `capability_missing` when either is unavailable.

## Create

### Choose the tier and timing

Default to `standard` 384×416. Use `low` 192×208 for minimal/pixel work or
resource-sensitive use. Use `high` 576×624 only when the user requests it and
the active image source proves a 12:13 crop of at least that size for every
frame. The generated sheet and cells do not need to equal the target dimensions
exactly. ChatGPT/Codex
built-in `imagegen` supports this workflow only at `low` and `standard`; do not
attempt `high` with it. Never upscale into a tier.

Start from the 42-frame table in `petpack-v3.md`. Change timing only when the action
benefits from a different valid per-frame rhythm. Keep the common creative
budget at 4–8 frames and about 1500ms or less per state, but do not treat those
numbers as package validity limits.

### Build the character and action cards

Establish:

- silhouette, landmarks, proportions, palette, lighting, and texture;
- camera, crop, and transparent safe area;
- any persistent prop and its attachment;
- one readable intent per fixed action;
- ordered anticipation, main action, and settle/return beats;
- deliberate spacing and non-uniform frame holds;
- playback mode, settle/cooldown fields, and a representative reduced-motion
  frame.

Keep `idle`, `tool`, and `waiting` centered around a stable subject root with
local motion by default. Allow bounded short whole-character reactions for
`thinking`, `done`, and `failed`. These are direction defaults, not
amplitude validators.

Keep `acknowledge` short and low-amplitude. Author `drag_left` and `drag_right`
as compact direction-readable gait loops that accompany the App's actual
pointer drag. Do not add gaze directions, hover reactions, autonomous motion,
audio, particles, or other interaction rows.

### Produce one state per batch

Request the exact state frame count as distinct ordered cells on the opaque
flat background defined by the shared transparency contract. Ask for stable
spacing, camera, scale, baseline, and safe margins instead of trusting the model
to return exact target pixels. Four to eight cells fit one ordinary V3 batch
only when the selected provider has qualified source capacity for that tier.
Persist the untouched image, verify exact frame count/order and target-size crop
capacity, inspect the action, crop stable equal-size 12:13 windows without
resampling, and run the shared script. Retain each source-resolution transparent
master outside the package and accept only the script's exact-tier runtime PNG
after its report, previews, and runtime-size action QA pass.

An exceptional multi-batch row is allowed only within an already qualified
tier. It cannot compensate for undersized source cells or manufacture source
capacity. When a non-capacity provider constraint requires
multiple batches:

1. Record the reason outside `petpack-source`.
2. Ground the next batch with one or two accepted boundary poses and the
   canonical base.
3. Keep cell geometry unchanged.
4. Inspect both sides of the join at runtime size.
5. Reject repeated, blended, or discontinuous boundary frames.

Do not use multi-batch production as the normal path or as a source-capacity
workaround.

## Modify

Prepare with:

```bash
python3 <skill-dir>/scripts/petpack_workspace.py prepare \
  --operation modify \
  --input /absolute/input.petpack \
  --workspace /absolute/workspace
```

The input must already be V3. Recreate V1/V2 inputs; do not migrate or alias
them. Read `.agent-pet-maker/context.json`. Preserve
manifest ID and `created_at`, render tier, and all unrequested state bytes.

For every changed state:

1. Use the strongest accepted unchanged frame as identity reference.
2. Write a fresh action card and complete V3 timing contract.
3. Regenerate or edit the complete state sequence.
4. Derive changed transparent PNGs with the shared script; never reprocess an
   unchanged baseline frame.
5. Make the PNG count exactly equal `frame_durations_ms.count`.
6. Rerun explicit-state Motion QA and repair before continuing.

Changing durations, playback, settle/cooldown behavior, or reduced-motion
selection is an authored state change. Do not speed up, slow down, sample,
subsample, duplicate, interpolate, or transform the old sequence to fit.

Replace `source/prompt.md`, `source/source.json`, and `brief.json` with concise
metadata for the new revision. Never copy an embedded transcript from the base.

## Motion QA and production verification

`motion-qa`:

- validates exact state counts from `frame_durations_ms`;
- renders one actual-duration `authored_timing` WebP per audited state;
- on the final combined run, renders an 8–12 second presence preview that uses
  authored timing, separated idle rests, and a digest of all nine actions;
- writes a runtime-size keyframe sheet;
- measures frame deltas, silhouette/scale, centroid/baseline, edges,
  interpolation candidates, and relevant loop boundaries;
- writes a `timing_digest` bound to the complete manifest states.

Clipped visible pixels and synthetic blend/interpolation are hard failures.
Other measurements are review targets. Inspect identity, readable state intent,
trajectory, crop, spacing/easing/weight, props, reduced-motion still choice,
and playback settle/return. The combined presence preview rejects effective
thinking/tool/waiting/done/failed activity below 1,000 ms or above 3,200 ms, so
the pet cannot freeze in under one second or loop mechanically for the whole
8–12 second review. Do not retime authored frames to satisfy this gate.

`motion-review` binds one concrete approved note per audited state to the
current report hash and frame-set digest. Any changed frame or timing contract
makes the old evidence stale.

`production-verify` calls the shared PetCore verifier. It checks changed-state
coverage, timing digest, decoded frame digests, keyframes, the per-state
`authored_timing` previews, the all-action-bound presence preview, review
freshness, registration, interpolation, and state distinction. Its `usable`
field is:

```text
build_ok && package_ok && interaction_ok && runtime_ok && visual_ok
```

`interaction_ok` is accepted only with the complete, closed
`interaction_evidence` suite list from a build-bound PetCore-validated
attestation. The attestation is written only after the native Swift Phase A and
T-B4 suites pass, and is rejected when its build ID, contract digest, fields,
or suite inventory are stale. Package playback evidence belongs to the
package/runtime gates.

Do not add another verification system.

## Finalize, result, and install

Create:

```bash
python3 <skill-dir>/scripts/petpack_workspace.py finalize \
  --operation create \
  --workspace /absolute/workspace \
  --output /absolute/output/pet.petpack
```

Modify:

```bash
python3 <skill-dir>/scripts/petpack_workspace.py finalize \
  --operation modify \
  --workspace /absolute/workspace \
  --changed-state tool \
  --output /absolute/output/revised.petpack
```

Repeat `--changed-state` for every actual change. The helper rejects a mismatch,
validates the source, builds and validates a staged archive, then publishes it
atomically. The staged archive uses a normal filename inside a private sibling
directory so macOS cannot carry a delayed Finder-hidden marker from a
dot-prefixed file inode onto the published package. Finalization also holds a
short bounded visibility-settling window before reporting completion, clearing
any delayed Finder flag reapplication. `--replace` replaces an existing
destination only after staged validation succeeds.

The result sidecar is transport metadata outside the package. It records
completion/capability status, output and hash, V3 manifest action contracts,
changed states, validation, Motion QA/review, and production gate status.

Installation is a separate explicit operation. It validates twice, rejects an
ID collision by default, imports through online PetCore, and verifies list and
snapshot state. Add `--activate` only when requested; never enable global
behavior implicitly.
