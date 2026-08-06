# Create and modify `.petpack` V3

## Contents

1. Shared flow
2. Create
3. Modify
4. QA and finalization
5. Optional install

Read `petpack-v3.md`, `security.md`, and the applicable visual-production
references before using this workflow.

## Shared flow

1. Run `preflight`.
2. Run `prepare` into an absent or empty private workspace.
3. Work only below `<workspace>/petpack-source`.
4. Keep raw image outputs, crop records, transparent masters, QA artifacts, and
   result sidecars outside the source root.
5. Produce and inspect one action at a time.
6. Run per-action Motion QA, then combined QA and bound review.
7. Run `finalize`; never hand-build or patch the archive.

The helper does not generate artwork. Use real image generation or editing and
real image inspection. Return `capability_missing` when a required capability
is unavailable.

## Create

Prepare:

```bash
python3 <skill-dir>/scripts/petpack_workspace.py prepare \
  --operation create \
  --workspace /absolute/workspace
```

Default to `standard` and the creation timing in `petpack-v3.md`. Honor an
explicit supported tier or another complete valid V3 timing. Establish one
canonical identity and action card, generate one action per batch, retain the
untouched result, and create the action's deterministic pose guide plus
separate deterministic size-reference image from one shared geometry record.
Verify source capacity and subject scale, crop without resampling, and derive
runtime PNGs through `prepare_transparent_frames.py`.

An additional batch is allowed only for a non-capacity continuity problem in an
already qualified tier. Record the reason outside the package, ground the next
batch with the canonical base and accepted boundary poses, keep crop geometry
fixed, and inspect the join.

## Modify

Prepare an exported V3 archive:

```bash
python3 <skill-dir>/scripts/petpack_workspace.py prepare \
  --operation modify \
  --input /absolute/input.petpack \
  --workspace /absolute/workspace
```

Read `.agent-pet-maker/context.json`. Preserve manifest ID, `created_at`, render
tier, all unrequested files, and their authored timing. Replace inherited
prompt and producer metadata with bounded facts for the new revision.

For each requested state change:

1. Use the strongest accepted unchanged frame as an identity reference.
2. Write the complete intended timing and action card.
3. Regenerate the action's pose guide and size-reference image from one shared
   geometry record, then regenerate or edit the complete sequence.
4. Run each new crop through the shared transparency script; never reprocess an
   unchanged frame.
5. Match PNG count to the timing-array length.
6. Rerun state Motion QA before continuing.

Changing durations, playback fields, settle/cooldown behavior, or the
reduced-motion frame is an authored state change. Do not adapt old frames by
retiming, sampling, padding, truncating, duplicating, interpolation, or
transforms.

## QA and finalization

After each accepted state:

```bash
python3 <skill-dir>/scripts/petpack_workspace.py motion-qa \
  --workspace /absolute/workspace \
  --state idle
```

After all states, rerun without `--state`. Inspect `keyframes.png`, every
authored-timing WebP, and `previews/presence-preview.webp`. Bind one concrete
note per audited state:

```bash
python3 <skill-dir>/scripts/petpack_workspace.py motion-review \
  --workspace /absolute/workspace \
  --state-note "idle=<intent, continuity, timing, return>" \
  --state-note "thinking=<intent, continuity, return>"
```

Repeat `--state-note` for every audited action. A frame or timing edit makes old
review evidence stale.

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

Repeat `--changed-state` for every actual change. The helper validates the
source, derives the changed set, checks fresh QA/review, builds and validates a
staged archive, then publishes it atomically.

For a localized edit, `motion-lock` may preserve explicitly non-moving pixels
from one accepted frame. Use a black-locked/white-moving mask, inspect seams,
copy only approved outputs back, and rerun Motion QA. Do not use it to freeze an
intended whole-character action or conceal a defective sequence.

If Motion QA reports subject displacement, compare its per-frame
`metrics.registration` body anchor and baseline with the action card and
deterministic pose guide before deciding that the movement is wrong. Preserve
intentional travel, bounce, recoil, jump arcs, and authored easing. When the
only defect is unintended whole-subject registration drift, try transparent-
frame alignment before another image-generation call:

```bash
python3 <skill-dir>/scripts/petpack_workspace.py motion-align \
  --source /absolute/workspace/petpack-source \
  --state thinking \
  --plan /absolute/workspace/thinking-motion-alignment-plan.json \
  --output-dir /absolute/workspace/thinking-aligned
```

The closed plan is bound to the current state's `motion_digest` from Motion QA
and records both the intended motion and why the observed path disagrees:

```json
{
  "schema_version": "apc.pet-motion-alignment-plan.v1",
  "state": "thinking",
  "source_motion_digest": "<states.thinking.motion_digest>",
  "motion_intent": "The pet travels right at equal frame spacing while its feet stay planted.",
  "correction_reason": "The generated body anchor jitters and the foot baseline drifts.",
  "body_anchor_x": {"mode": "linear"},
  "baseline_y": {"mode": "lock", "reference_frame": 0}
}
```

Each axis uses `preserve`, `lock`, `linear`, or `targets`. `linear` regularizes
the measured first-to-last path to equal per-frame spacing; `targets` takes one
normalized guide-derived coordinate per frame and preserves deliberate easing
or a non-linear arc. The helper performs integer whole-frame translation only:
no scale, rotation, resampling, Alpha filtering, or pose deformation. It
rejects clipping, lost Alpha, missing transparent padding, stale QA bindings,
and plans that preserve both axes. Inspect the complete authored-timing output
against the pose guide; copy only approved PNGs into `petpack-source`, rerun
Motion QA, and write fresh review evidence. Regenerate instead when correction
would hide an identity, anatomy, pose, scale, prop, Alpha, crop, or continuity
defect.

## Optional install

Installation is a separate, explicit operation:

```bash
python3 <skill-dir>/scripts/petpack_workspace.py install \
  --input /absolute/output/pet.petpack
```

Add `--activate` only when requested. The helper validates twice, imports
through online PetCore, rejects an ID collision by default, and verifies the
library snapshot. Treat `partial_success` as a possible mutation and inspect
its verification fields before retrying.
