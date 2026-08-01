# Visual production and native resolution

## Contents

1. Native source-pixel gate
2. One-state batch protocol
3. Motion quality
4. Incremental and final verification

## Native source-pixel gate

`manifest.render_size` is both the exact decoded PNG size and the minimum native
source-pixel crop for every frame:

| Tier | Exact crop |
| --- | ---: |
| `low` | 192×208 |
| `standard` | 384×416 |

Both tiers require crop-only extraction from decoded source pixels. The final
PNG dimensions alone never establish native capacity. The currently qualified
generation path supports no larger tier: splitting a state across multiple
batches cannot replace missing native single-batch capacity. If the provider or
generation path changes, rerun both the diagnostic-grid and representative
eight-frame probes before proposing any new tier, then revise the schema,
runtime, producers, fixtures, and documentation together.

After each generation/editing call:

1. Persist the untouched decoded image outside `petpack-source`.
2. Record its real dimensions and explicit rectangle for every intended cell.
3. Require every rectangle to contain at least one independent exact
   target-size crop after margins and gutters.
4. Reject overlapping, undersized, blurry pre-enlarged, padded-small-crop, or
   resampling-dependent cells.
5. Inspect the full source at 100% for missing/duplicate cells, grid leakage,
   clipping, anatomy, identity, props, transparency, and action order.
6. Extract by crop-only operations. Decode each PNG and verify the exact tier.
7. Inspect extracted frames before another image call.

Trimming a larger cell is valid. Upscaling, super-resolution, stretching,
resizing, or placing a smaller crop on a target-size canvas is invalid. Final
PNG dimensions alone do not prove native source resolution.

## One-state batch protocol

Generate one complete state per image batch. The normal V2 action has 4–8 cells,
which fits the measured capacity at both supported tiers. Keep:

- one canonical production base;
- one state action card;
- identical cell geometry and transparent safe area;
- distinct ordered authored poses;
- enough target pixels per cell;
- no visual instructions or annotations inside accepted cells.

Multiple batches are an exceptional continuity fallback within an already
qualified supported tier. Record the non-capacity reason, carry accepted
boundary poses into the next batch, and inspect the join. Never use extra
batches to overcome undersized source cells or claim another tier. Never expand
a smaller storyboard through duplicate poses, crossfade, morph, optical flow,
procedural interpolation, or transformed copies.

## Motion quality

Every state must:

- communicate its fixed semantic intent at 192×208 without zoom;
- preserve recognizable identity, anatomy, costume, palette, and prop
  attachment;
- use deliberate spacing and per-frame holds;
- keep all visible pixels away from the canvas edge;
- avoid accidental wobble, popping, recentering, disappearance, or crop jumps;
- end at a readable settle/return appropriate to its playback mode;
- select a reduced-motion frame that reads independently and is not an
  in-between.

Whole-character translation, rotation, squash/stretch, recoil, or scale change
is valid when deliberate and continuous. Motion amplitude metrics are evidence,
not automatic failures. Resident/high-frequency actions normally keep the root
stable and move local features; low-frequency semantic reactions may use a
short prepared whole-body action.

For `loop` and `periodic`, inspect the final-to-first boundary. For a repeated
`burst_then_settle`, inspect the repeated boundary and final settle. For
`once_hold`, inspect the settle frame rather than forcing a loop.

## Incremental and final verification

After each state:

```bash
python3 <maker-skill-dir>/scripts/petpack_workspace.py motion-qa \
  --workspace /absolute/workspace \
  --state <state>
```

Repair objective clipping or synthetic interpolation before any later image
call. Inspect the `authored_timing` preview at actual per-frame durations.

After all states, rerun without `--state`, inspect `keyframes.png` and all seven
previews, then bind `motion-review`. Any frame or manifest timing edit requires
fresh evidence.

Before finalization, the existing `production-verify` path must report all
component gates and derive `usable` only when build, package, interaction,
runtime, and visual checks are all true. Finalization calls the same gate; do
not create a parallel visual QA path.
