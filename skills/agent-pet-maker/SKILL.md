---
name: agent-pet-maker
description: Create or modify portable Agent Pet Companion .petpack V3 desktop pets from text and optional reference images, with nine fixed semantic and local-interaction actions, authored per-frame timing, identity continuity, deterministic source-to-runtime sizing, runtime-size motion review, and validated packaging. Use when a user asks to make a new Agent Pet Companion pet, revise an exported V3 .petpack, change pet actions or timing, or produce a validated package for Agent Pet Companion.
---

# Agent Pet Maker

Create a coherent nine-action character performance: six semantic actions and
three restrained local interactions. Preserve recognizable
identity and prop relationships while allowing deliberate whole-character or
local motion. Use the bundled helper for workspace safety, actual-timing Motion
QA, bound visual review, shared production verification, and package building.
Use only real image-capable tools and record their real names.

## Read the contracts

- Always read [references/petpack-v3.md](references/petpack-v3.md) for the closed
  package, timing, metadata, and result contracts.
- Always read
  [references/visual-production-and-native-resolution.md](references/visual-production-and-native-resolution.md)
  for source-pixel and visual acceptance rules.
- Always read
  [references/transparent-frame-production.md](references/transparent-frame-production.md)
  and use `scripts/prepare_transparent_frames.py` for every newly generated or
  regenerated transparent frame. Do not request model-native transparency.
- Read [references/create-modify.md](references/create-modify.md) for the chosen
  create or modify workflow.
- Always follow [references/security.md](references/security.md).

## Preflight

Run:

```bash
python3 <skill-dir>/scripts/petpack_workspace.py preflight
```

Use a Python interpreter with Pillow PNG and animated WebP support. Never
replace the helper or Pillow with a shim. If real image generation, required
image understanding, Pillow, or PetCore is unavailable, stop and write an
honest sidecar:

```bash
python3 <skill-dir>/scripts/petpack_workspace.py capability-missing \
  --operation create \
  --capability image-generation \
  --result /absolute/output/result.json
```

## Create

1. Prepare an empty workspace:

   ```bash
   python3 <skill-dir>/scripts/petpack_workspace.py prepare \
     --operation create \
     --workspace /absolute/workspace
   ```

2. Use `standard` 384×416 unless the user chooses `low` 192×208 or explicitly
   requests `high` 576×624. One package uses one tier for every frame. `high`
   is valid only when the active image source can supply every cell as a 12:13
   crop of at least that size. Do not require the generator's whole output or
   each generated cell to equal the target dimensions exactly. ChatGPT/Codex
   built-in `imagegen` is qualified only for `low` and `standard`: do not
   attempt `high` with it, do not split batches to make
   up missing pixels, and do not silently fall back. If `high` is required and
   no other source-capable image tool or sufficiently large user artwork is
   available, return `capability_missing` before image generation.
3. Establish one canonical production base and one action card per action.
   Author the exact default 42-frame timing from `petpack-v3.md`. Semantic
   thinking/tool/done use finite bursts that return visually to idle;
   waiting/failed use bounded bursts that settle; acknowledge is one short
   click response; drag_left/drag_right are restrained loops. Never add gaze
   directions, hover reactions, autonomous movement, or aliases. Never emit
   removed package states such as `start` or `review`; any V1/V2 source must be
   recreated as V3.
4. Generate one complete state per image batch on the opaque flat background
   required by the shared transparent-frame contract. Request 4–8 distinct
   ordered cells with stable camera, scale, baseline, spacing, and safe margins;
   treat requested pixel dimensions and layout guides as generation guidance,
   not proof of the returned size. Persist the untouched output, verify exact
   frame count/order and action continuity, then apply the source-capacity gate.
   A multi-batch state is only an exceptional continuity fallback within an
   already qualified tier: never use it to compensate for insufficient source
   cell capacity or to introduce another tier. Record why, start each later
   batch from accepted boundary poses, and inspect the join.
5. Crop accepted cells without resampling. Use stable equal-size 12:13 source
   windows across the state and preserve intended translation and baseline;
   never tight-crop and independently fit each pose to its subject bounds. A
   crop may equal or exceed the selected target. Then run the shared
   deterministic pipeline. Keep its opaque sources, transparent masters,
   report, and multi-background previews outside `petpack-source`; put only
   selected-tier runtime PNGs in `assets/frames/`. Accept the state only when
   the report and every frame say `"ok": true` and the previews pass visual
   inspection:

   ```bash
   python3 <skill-dir>/scripts/prepare_transparent_frames.py \
     --jobs /absolute/workspace/transparent-frame-jobs-idle.json \
     --report /absolute/workspace/transparency-report-idle.json \
     --preview-dir /absolute/workspace/transparency-previews/idle
   ```

   Never substitute custom color removal, edge cleanup, Alpha filtering, or
   resizing. The shared pipeline may make one direct downscale for `low`,
   `standard`, or `high`; it never upscales. Follow the shared failure policy
   instead of tuning thresholds.
6. After each accepted state, run the explicit-state Motion QA before generating
   another state:

   ```bash
   python3 <skill-dir>/scripts/petpack_workspace.py motion-qa \
     --workspace /absolute/workspace \
     --state idle
   ```

   Repair clipped frames and synthetic interpolation immediately. Review the
   exact-tier runtime frames after any downscale for identity, distinct poses,
   action readability, anatomy, props, continuity, and settle/loop behavior.
   Treat other measurements as visual review targets, not motion-amplitude
   limits.
7. After all states pass, run Motion QA without `--state`. Inspect
   `keyframes.png`, each state's single `authored_timing` preview at 192×208,
   and the generated 8–12 second `previews/presence-preview.webp`. Verify readable
   intent, spacing, easing, identity, props, crop, and loop/settle behavior. The
   presence preview must retain separated late motion and calm rests; reject any
   semantic action that becomes static in under one second or loops mechanically
   throughout the review. Never retime frames to make the preview pass.
8. Bind one concrete note to every audited state:

   ```bash
   python3 <skill-dir>/scripts/petpack_workspace.py motion-review \
     --workspace /absolute/workspace \
     --state-note "idle=<intent, continuity, timing, periodic return>" \
     --state-note "thinking=<anticipation, reasoning intent, settle>" \
     --state-note "tool=<intent, continuity, repeated burst, settle>" \
     --state-note "waiting=<intent, continuity, settle>" \
     --state-note "done=<reaction, continuity, settle>" \
     --state-note "failed=<reaction, continuity, persistent settle>" \
     --state-note "acknowledge=<short low-distraction response and return>" \
     --state-note "drag_left=<left gait loop, identity, continuity>" \
     --state-note "drag_right=<right gait loop, identity, continuity>"
   ```

9. Finalize. This runs the existing shared production gate, validates twice,
   builds beside the destination, and publishes atomically. All five readiness
   fields must be explicitly present and `true`; missing evidence fails closed:

   ```bash
   python3 <skill-dir>/scripts/petpack_workspace.py finalize \
     --operation create \
     --workspace /absolute/workspace \
     --output /absolute/output/pet.petpack
   ```

## Modify

1. Accept only an exported `.petpack` V3 archive. Never modify an installed
   package directory. Recreate V1/V2 packages instead of migrating them.
2. Prepare with `--operation modify --input /absolute/input.petpack`.
3. Preserve manifest ID and `created_at`. Keep unrequested state files
   byte-identical.
4. Treat a timing edit as an authored animation edit. Re-storyboard the complete
   affected state so `frame_durations_ms.count` equals its PNG count. Never
   retime, sample, duplicate, interpolate, or transform old frames into filler.
5. Run every newly generated or regenerated frame through
   `scripts/prepare_transparent_frames.py`; preserve untouched baseline PNGs
   byte-for-byte. Rerun explicit-state Motion QA for every changed state, then
   run final Motion QA without `--state` so the 8–12 second presence preview is
   rebuilt and bound to all nine current actions. Review exactly the changed
   states and declare each one during finalization:

   ```bash
   python3 <skill-dir>/scripts/petpack_workspace.py finalize \
     --operation modify \
     --workspace /absolute/workspace \
     --changed-state tool \
     --output /absolute/output/revised.petpack
   ```

The helper and PetCore derive the actual changed set and reject stale evidence.

## Optional local motion lock

For a localized edit only, preserve explicit non-moving pixels from one accepted
reference frame with `motion-lock`. Use a black-locked/white-moving PNG mask,
inspect seams, copy approved outputs back, and rerun Motion QA. Never use it to
freeze an intended full-character action or conceal a bad sequence.

## Install only when requested

`finalize` does not import, activate, or enable a pet. When the user explicitly
asks to install, run:

```bash
python3 <skill-dir>/scripts/petpack_workspace.py install \
  --input /absolute/output/pet.petpack
```

Add `--activate` only on explicit request. Use
`--allow-existing-id-revision` only for an intentional same-ID revision.
