# Visual production and source-size normalization

## Contents

1. Source-capacity and one-resize gate
2. Transparent derivation gate
3. One-state batch protocol
4. Motion quality
5. Incremental and final verification

## Source-capacity and one-resize gate

`manifest.render_size` is the exact decoded runtime PNG target, not a pixel-size
instruction that an image model must obey. The untouched generated image may
have any dimensions. Every selected frame must instead provide one crop in
decoded source pixels that is exactly 12:13 and at least as large as its target:

| Tier | Exact runtime PNG | Minimum 12:13 source crop |
| --- | ---: | ---: |
| `low` | 192×208 | 192×208 |
| `standard` | 384×416 | 384×416 |
| `high` | 576×624 | 576×624 |

Do not reject a useful image merely because its overall dimensions differ from
the requested tier, and do not trust a prompt such as “output 384×416” as
resolution evidence. Prompts and optional layout guides control frame count,
order, spacing, safe margins, identity, and action; deterministic cropping and
the shared script control exact output pixels.

All tiers follow the same rule: exact-size crops are copied, larger crops are
downscaled once, and smaller crops fail. Package conformance and producer
capability remain separate. `high` is a valid App/runtime tier, but the
ChatGPT/Codex built-in `imagegen` path is qualified only through `standard` and
must not be repeatedly tried for `high`. Another provider or user-supplied
source may create `high` when every untouched decoded frame has a 12:13 crop of
at least 576×624. Splitting a state across multiple batches cannot replace
missing source pixels. If capacity is unknown, run the diagnostic-grid and
representative action probes before production instead of silently enlarging a
smaller result.

After each generation/editing call:

1. Persist the untouched decoded image outside `petpack-source`.
2. Record its real dimensions and one explicit source-pixel rectangle for every
   intended frame; never resize the whole sheet to make a grid fit.
3. Require every rectangle to be exactly 12:13 and at least the target size
   after margins and gutters. For one state, use stable equal-size crop windows
   and preserve the authored baseline and translation; never tight-crop and
   independently recenter each pose by its subject bounding box.
4. Reject overlapping, undersized, blurry pre-enlarged, padded-small-crop, or
   already-resampled cells.
5. Inspect the full source at 100% for exact frame count and order, distinct
   authored poses, grid leakage, clipping, anatomy, identity, props, stable
   camera/scale, flat-background compliance, and action continuity.
6. Extract each opaque cell by crop-only operations, then use the shared
   transparent-frame script for the sole permitted size normalization.
7. Decode the derived PNGs, verify source-resolution master and exact runtime
   dimensions, inspect the runtime-size action, and run Motion QA before any
   later state is accepted.

Trimming a larger source cell is valid. One direct downscale from the
source-resolution transparent master to the runtime tier is valid only through
the shared script for `low`, `standard`, and `high` alike.
Upscaling, super-resolution, stretching, cascaded resizing, resizing before
matting, or placing a smaller crop on a target-size canvas is invalid. Final PNG
dimensions alone do not prove sufficient source resolution.

## Transparent derivation gate

Read and follow
[transparent-frame-production.md](transparent-frame-production.md). Newly
generated artwork is fully opaque; do not ask an image model for transparent
output. The shared script owns matte thresholds, spatial background selection,
edge RGB reconstruction, the sole optional downscale, and multi-background QA.
Only reports whose root and every frame say `"ok": true` may proceed to Motion
QA. Keep the untouched source and source-resolution transparent master outside
the package; package only exact-tier runtime PNGs.

## One-state batch protocol

Generate one complete action per image batch. The normal V3 action has 4–8 cells,
which fits the measured capacity at the provider-qualified selected tier. Keep:

- one canonical production base;
- one action card;
- identical cell geometry and transparent safe area;
- distinct ordered authored poses;
- enough decoded source pixels per cell;
- no visual instructions or annotations inside accepted cells.

Multiple batches are an exceptional continuity fallback within an already
qualified tier. Record the non-capacity reason, carry accepted
boundary poses into the next batch, and inspect the join. Never use extra
batches to overcome undersized source cells or claim another tier. Never expand
a smaller storyboard through duplicate poses, crossfade, morph, optical flow,
procedural interpolation, or transformed copies.

## Motion quality

Every action must:

- communicate its fixed semantic intent at 192×208 without zoom;
- preserve recognizable identity, anatomy, costume, palette, and prop
  attachment;
- use deliberate spacing and per-frame holds;
- keep all visible pixels away from the canvas edge;
- avoid accidental wobble, popping, recentering, disappearance, or crop jumps;
- end at a readable settle/return appropriate to its playback mode;
- select a reduced-motion frame that reads independently and is not an
  in-between.

Apply these checks to the exact-tier runtime PNGs after the optional downscale,
not only to the larger source or transparent master. Downscaling does not waive
action readability, distinct-pose, identity, anatomy, prop, crop, or playback
quality requirements.

Whole-character translation, rotation, squash/stretch, recoil, or scale change
is valid when deliberate and continuous. Motion amplitude metrics are evidence,
not automatic failures. Resident/high-frequency actions normally keep the root
stable and move local features; low-frequency semantic reactions may use a
short prepared whole-body action.

For `loop` and `periodic`, inspect the final-to-first boundary. For a repeated
`burst_then_settle`, inspect the repeated boundary and final settle. For
`once_then_return`, inspect the completion-to-underlying-action handoff rather
than forcing a loop.

## Incremental and final verification

After each state:

```bash
python3 <maker-skill-dir>/scripts/petpack_workspace.py motion-qa \
  --workspace /absolute/workspace \
  --state <state>
```

Repair objective clipping or synthetic interpolation before any later image
call. Inspect the `authored_timing` preview at actual per-frame durations.

After all actions, rerun without `--state`, inspect `keyframes.png`, all nine
authored-timing previews, and the generated 8–12 second presence preview, then
bind `motion-review`. The presence preview uses authored durations, contains at
least three calm idle rests, remains bound to all nine actions, and rejects a
semantic action that freezes in under one second or loops mechanically for the
whole review. Never retime frames for this preview. Any frame or manifest timing
edit requires fresh evidence.

Before finalization, the existing `production-verify` path must report all
component gates and derive `usable` only when build, package, interaction,
runtime, and visual checks are all true. Finalization calls the same gate; do
not create a parallel visual QA path.
