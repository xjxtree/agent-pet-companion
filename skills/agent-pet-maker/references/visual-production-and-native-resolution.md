# Visual production and source-size normalization

## Contents

1. Source-capacity gate
2. Provider routing
3. Production base and action batches
4. Deterministic pose guides
5. Reference and prompt contract
6. Failure routing
7. Runtime-size acceptance

## Source-capacity gate

Treat `manifest.render_size` as the exact runtime PNG target, not an image-model
output instruction. For every frame, recover a complete decoded source crop
that is exactly 12:13 and at least the selected target:

| Tier | Runtime PNG | Minimum source crop |
| --- | ---: | ---: |
| `low` | 192×208 | 192×208 |
| `standard` | 384×416 | 384×416 |
| `high` | 576×624 | 576×624 |

After every image call:

1. Save the untouched decoded image outside `petpack-source` and record its
   actual dimensions.
2. Verify exact frame count/order, distinct poses, full-body completeness,
   identity, anatomy, props, camera, scale, spacing, background, and action.
3. Record one stable equal-size source-pixel rectangle per cell. Preserve the
   action's baseline and intended translation; never fit or recenter poses
   independently by their subject bounds.
4. Reject overlapping, clipped, undersized, padded, blurry pre-enlarged, or
   already-resampled cells.
5. Crop only, then use the shared transparency script for an exact copy or one
   direct linear-light premultiplied-Alpha downscale.
6. Inspect the exact-tier runtime sequence and run Motion QA.

Never upscale, stretch, use super-resolution, resize before matting, cascade
resizes, or place a small crop on a target-size canvas. Additional batches do
not create missing source pixels.

## Provider routing

Choose the tier first, then a provider whose real decoded pixels can satisfy it:

| Image path | Qualified tiers | Rule |
| --- | --- | --- |
| ChatGPT/Codex built-in `imagegen` | `low`, `standard` | Its approximate 1K–2K decoded output envelope is not qualified for `high`. |
| Dreamina 5.0 Pro | `low`, `standard`, `high` | For `high`, follow `dreamina-high-production.md` and verify the returned pixels. |
| Another provider or user artwork | Any tier proven by its pixels | Apply the same capacity, transparency, motion, and final gates. |

Do not repeatedly attempt built-in `imagegen` for `high`, combine separate
outputs, or silently downgrade. If no qualified source is available, stop
before a paid call or ask the user to select a lower tier.

## Production base and action batches

First create one complete full-body base. Lock the stated maturity or adult
identity, face, hair or defining features, body proportions, clothing,
materials, palette, lighting, camera distance, scale, crop, and persistent
props. Use this production base as reference image 1 for every later
image-to-image action.

Generate one action per call and normally keep all 4–8 ordered poses in one
batch. Use one action card that states the intent, exact frame count, left-to-
right beat order, playback outcome, safe margins, and flat-background rules.
Immediately inspect the result before another call.

Use text control for a simple action. Walking, jumping, turning, and other
complex limb/depth sequences require a deterministic frameless equal-scale pose
guide as reference image 2. If the same defect appears twice, change the guide
or redesign the action instead of extending the same prompt.

An exceptional multi-batch action is allowed only for a non-capacity continuity
constraint. Carry the base and one or two accepted boundary poses into the next
batch, keep cell geometry unchanged, and inspect both sides of the join. Never
fill a sequence with duplicate poses, crossfade, morph, optical flow,
procedural interpolation, or transformed copies.

## Deterministic pose guides

Create every complex-action guide with a deterministic script, never an image
model. The script must:

1. Create a pure `#FF00FF` canvas at the target action-sheet dimensions.
2. Divide it into invisible equal-width slots:

   ```text
   slot_width = canvas_width / frame_count
   slot_center_x = (frame_index + 0.5) * slot_width
   ```

3. Draw every pose from one skeleton definition, joint-length set, head size,
   and `global_scale`.
4. Put one complete pose in each slot and keep horizontal occupancy at or below
   80–85% of the slot.
5. Keep one foot baseline for ordinary actions. For a jump, change joint
   coordinates and whole-pose `y_offset`; never scale one frame.
6. Emit no border, cell, grid, divider, number, text, label, shadow, or action
   effect. Light and dark gray may describe limb depth only.

The guide controls pose count, joints, sequence, spacing, and depth. It is not
production artwork and no guide pixel may survive in a pet frame.

## Reference and prompt contract

Upload the character base first and the pose guide second. When both are used,
include this responsibility block verbatim:

```text
Image 1 defines the exact character identity, face, hair, clothing,
body proportions and materials.

Image 2 is a script-generated frameless equal-scale pose guide. It
defines only pose count, joint positions, sequence, spacing and depth.

Replace every guide figure completely with the character from Image 1.
Do not preserve any mannequin, skeleton, guide color, frame, grid,
label or background artifact.

Keep the same camera distance, head size, shoulder width, body scale
and clothing design in every pose.
```

Every action prompt must also require:

- the exact frame count and left-to-right order;
- one complete same-scale character in each invisible slot;
- the same identity, face, outfit, proportions, materials, and camera in every
  pose;
- no touching, overlap, or cropped hair, appendages, hands, feet, or heels;
- a perfectly uniform textureless solid background with no floor, shadow,
  reflection, text, border, or floating effect;
- `CRITICAL SCALE LOCK` for jumps or other scale-sensitive motion;
- `contact -> settle -> passing -> advance` with alternating limbs for a walk;
- correctly connected feet and heels in every relevant pose.

Choose the output chroma background by the transparency contract. The guide's
magenta canvas is structural input, not an instruction to copy its color.

## Failure routing

- Corner marks: move subjects away from all four corners and preserve exterior
  blank space.
- Gradient or paneled background: strengthen `perfectly uniform, textureless
  solid background`.
- Copied guide figures: require complete replacement and forbid retained guide
  pixels.
- Scale drift: lock camera distance, head size, shoulder width, and full-body
  scale.
- Jump shadows: forbid floor, cast, contact, and oval shadows explicitly.
- Repeated walk poses: revise scripted joint coordinates instead of stacking
  prompt variants.

## Runtime-size acceptance

Review the exact-tier runtime PNGs, not only the source sheet or transparent
master. Every action must retain identity, anatomy, costume, palette, prop
attachment, readable intent, distinct poses, deliberate spacing, safe crop,
and the mode-appropriate loop, settle, or return. Choose a reduced-motion pose
that reads independently.

Intentional translation, rotation, recoil, bounce, squash/stretch, or scale
change is valid when continuous and coherent. Motion magnitude is review
evidence, not an automatic aesthetic failure. Clipping and synthetic
interpolation are hard failures.

Run state Motion QA immediately after acceptance. After all actions, inspect
all authored-timing previews, `keyframes.png`, and the 8–12 second presence
preview, then bind `motion-review`. Never retime authored frames to pass the
preview. Any frame or timing edit requires fresh evidence.
