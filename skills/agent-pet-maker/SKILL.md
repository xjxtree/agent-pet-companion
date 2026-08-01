---
name: agent-pet-maker
description: Create or modify portable Agent Pet Companion .petpack V2 desktop pets from text and optional reference images, with per-frame authored timing, identity continuity, native-resolution production, runtime-size motion review, and validated packaging. Use when a user asks to make a new Agent Pet Companion pet, revise an exported V2 .petpack, change pet actions or timing, or produce a validated package for Agent Pet Companion.
---

# Agent Pet Maker

Create a coherent seven-state character performance. Preserve recognizable
identity and prop relationships while allowing deliberate whole-character or
local motion. Use the bundled helper for workspace safety, actual-timing Motion
QA, bound visual review, shared production verification, and package building.
Use only real image-capable tools and record their real names.

## Read the contracts

- Always read [references/petpack-v2.md](references/petpack-v2.md) for the closed
  package, timing, metadata, and result contracts.
- Always read
  [references/visual-production-and-native-resolution.md](references/visual-production-and-native-resolution.md)
  for source-pixel and visual acceptance rules.
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

2. Use `standard` 384×416 unless the user chooses `low` 192×208. One package
   uses one tier for every frame.
3. Establish one canonical production base and one action card per state.
   Author the exact default 32-frame timing from `petpack-v2.md`—including idle
   reduced-motion frame 2 and one tool entry repeat—unless the brief justifies
   another valid V2 contract.
4. Generate one complete state per image batch. Request 4–8 distinct ordered
   cells and apply the native-resolution gate immediately. A multi-batch state
   is only an exceptional continuity fallback within an already qualified tier:
   never use it to compensate for insufficient native cell capacity or to
   introduce another tier. Record why, start each later batch from accepted
   boundary poses, and inspect the join.
5. After each accepted state, run the explicit-state Motion QA before generating
   another state:

   ```bash
   python3 <skill-dir>/scripts/petpack_workspace.py motion-qa \
     --workspace /absolute/workspace \
     --state idle
   ```

   Repair clipped frames and synthetic interpolation immediately. Treat other
   measurements as visual review targets, not motion-amplitude limits.
6. After all states pass, run Motion QA without `--state`. Inspect
   `keyframes.png` and each state's single `authored_timing` preview at 192×208.
   Verify readable intent, spacing, easing, identity, props, crop, and
   loop/settle behavior.
7. Bind one concrete note to every audited state:

   ```bash
   python3 <skill-dir>/scripts/petpack_workspace.py motion-review \
     --workspace /absolute/workspace \
     --state-note "idle=<intent, continuity, timing, periodic return>" \
     --state-note "start=<anticipation, reaction, settle>" \
     --state-note "tool=<intent, continuity, repeated burst, settle>" \
     --state-note "waiting=<intent, continuity, settle>" \
     --state-note "review=<intent, prop continuity, settle>" \
     --state-note "done=<reaction, continuity, settle>" \
     --state-note "failed=<reaction, continuity, settle>"
   ```

8. Finalize. This runs the existing shared production gate, validates twice,
   builds beside the destination, and publishes atomically. All five readiness
   fields must be explicitly present and `true`; missing evidence fails closed:

   ```bash
   python3 <skill-dir>/scripts/petpack_workspace.py finalize \
     --operation create \
     --workspace /absolute/workspace \
     --output /absolute/output/pet.petpack
   ```

## Modify

1. Accept only an exported `.petpack` V2 archive. Never modify an installed
   package directory or V1 package.
2. Prepare with `--operation modify --input /absolute/input.petpack`.
3. Preserve manifest ID and `created_at`. Keep unrequested state files
   byte-identical.
4. Treat a timing edit as an authored animation edit. Re-storyboard the complete
   affected state so `frame_durations_ms.count` equals its PNG count. Never
   retime, sample, duplicate, interpolate, or transform old frames into filler.
5. Rerun Motion QA and review for exactly the changed states. Declare each one
   during finalization:

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
