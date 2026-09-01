# Visual production and source-size normalization

## Contents

1. Source-capacity gate
2. Provider routing
3. Production base and action batches
4. Deterministic pose and size guides
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
   identity, anatomy, props, camera, scale, spacing, the selected transparency
   source contract, and action.
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
| ChatGPT/Codex built-in `imagegen` | `low`, `standard` | Default image path and default `native_alpha` source; its approximate 1K–2K decoded output envelope is not qualified for `high`. |
| Dreamina 5.0 Pro | `low`, `standard`, `high` | For `high`, follow `dreamina-high-production.md`, use its explicit `chroma_key` compatibility source, and verify the returned pixels. |
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
right beat order, playback outcome, safe margins, and the selected
native-Alpha or chroma compatibility rules.
Immediately inspect the result before another call.

Every multi-frame action uses two script-generated structural references: a
frameless pose guide as reference image 2 and a separate frameless size-
reference image as reference image 3. They must come from one geometry record
and have identical canvas dimensions, slot centers, centered 12:13 crop
windows, baseline, and `global_scale`. Text-only requests for equal-sized
figures are not scale evidence. If the active provider cannot accept the
character base and both structural references in one request, choose a
compatible provider or a supported lower tier instead of dropping the size
reference. If the same defect appears twice, change the guides or redesign the
action instead of extending the same prompt.

An exceptional multi-batch action is allowed only for a non-capacity continuity
constraint. Carry the base and one or two accepted boundary poses into the next
batch, keep cell geometry unchanged, and inspect both sides of the join. Never
fill a sequence with duplicate poses, crossfade, morph, optical flow,
procedural interpolation, or transformed copies.

## Deterministic pose and size guides

Create both guide images with one deterministic script, never an image model.
The script must:

1. Create a pure `#FF00FF` canvas at the target action-sheet dimensions.
2. Divide it into invisible equal-width slots:

   ```text
   slot_width = canvas_width / frame_count
   slot_center_x = (frame_index + 0.5) * slot_width
   ```

3. Compute one largest centered 12:13 crop per slot, then one safe subject box
   inset by at least 10% on every crop edge. Record the canvas, slot centers,
   crop rectangles, safe boxes, baseline, head diameter, shoulder width,
   subject height, and `global_scale` in a workspace sidecar.
4. Draw the pose guide from one skeleton definition, joint-length set, head
   size, and `global_scale`. Put one complete pose in each slot and keep it
   inside the recorded safe subject box.
5. Draw the separate size-reference image with one neutral-gray upright
   calibration silhouette repeated at the exact recorded head diameter,
   shoulder width, subject height, baseline, and `global_scale` in every slot.
   It controls scale and occupancy only, never the action pose.
6. Keep one foot baseline for ordinary actions. For a jump, change joint
   coordinates and whole-pose `y_offset`; never scale one frame.
7. Emit no border, cell, safe-box outline, grid, divider, number, text, label,
   shadow, or action effect. Light and dark gray may describe limb depth only.

The pose guide controls pose count, joints, sequence, spacing, and depth. The
size-reference image independently controls full-body pixel scale and safe crop
occupancy. Neither is production artwork, and no guide pixel may survive in a
pet frame. Regenerate both from the same sidecar whenever canvas, frame count,
crop geometry, baseline, or `global_scale` changes; never resize one guide to
match the other.

## Reference and prompt contract

Upload the character base first, the pose guide second, and the size-reference
image third. Include this responsibility block verbatim:

```text
Image 1 defines the exact character identity, face, hair, clothing,
body proportions and materials.

Image 2 is a script-generated frameless equal-scale pose guide. It
defines only pose count, joint positions, sequence, spacing and depth.

Image 3 is a separate script-generated frameless size reference. It
defines only full-body pixel height, head size, shoulder width, baseline
and safe crop occupancy. It does not define identity or action pose.

Use Image 2 for joints and Image 3 for scale. Replace every guide figure
completely with the character from Image 1. Do not preserve any
mannequin, silhouette, skeleton, guide color, frame, grid, label or
background artifact.

Keep the same camera distance, head size, shoulder width, body scale
and clothing design in every pose.
```

Every action prompt must also require:

- the exact frame count and left-to-right order;
- one complete same-scale character in each invisible slot;
- the same identity, face, outfit, proportions, materials, and camera in every
  pose;
- the recorded full-body pixel height, head size, shoulder width, baseline, and
  safe crop occupancy from the size-reference image;
- no touching, overlap, or cropped hair, appendages, hands, feet, or heels;
- for built-in `imagegen`, a genuinely transparent canvas with Alpha 0 exterior
  and gutters, no checkerboard, floor, shadow, reflection, glow, text, border,
  watermark, solid backdrop, gradient backdrop, or floating effect;
- for an explicit `chroma_key` source, one perfectly uniform textureless solid
  background with no floor, shadow, reflection, text, border, or floating
  effect;
- `CRITICAL SCALE LOCK` for jumps or other scale-sensitive motion;
- `contact -> settle -> passing -> advance` with alternating limbs for a walk;
- correctly connected feet and heels in every relevant pose.

Use `native_alpha` for built-in `imagegen`; choose a chroma background only for
the compatibility route defined by the transparency contract. The guide's
magenta canvas is structural input, not an instruction to copy its color or
opacity.

## Failure routing

- Corner marks: move subjects away from all four corners and preserve exterior
  blank space.
- Opaque, checkerboard, gradient, or paneled built-in output: regenerate only
  the failing action with the genuine-transparent-canvas constraints.
- Gradient or paneled chroma output: strengthen `perfectly uniform,
  textureless solid background`.
- Copied guide figures: require complete replacement and forbid retained guide
  pixels.
- Scale drift or oversized figures: do not fit cells independently. Regenerate
  both structural guides from one geometry record, reduce `global_scale` once
  for the whole action when needed, and lock camera distance, head size,
  shoulder width, full-body pixel height, and safe crop occupancy.
- Pose/size disagreement: repair the shared sidecar and regenerate both guides;
  never resize or reposition one reference independently.
- Whole-subject registration drift: compare Motion QA's per-frame body-anchor
  and baseline path with the action card and deterministic pose guide. Preserve
  intentional travel and easing. If registration is the only defect, first use
  one QA-bound `motion-align` pass on the transparent exact-tier frames; choose
  a locked, equal-spacing linear, or explicit guide-target path per axis. The
  pass may translate whole frames by integer pixels only and must be inspected
  and rerun through Motion QA. Regenerate when translation would clip Alpha or
  conceal any identity, anatomy, pose, scale, prop, crop, or continuity defect.
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
evidence, not an automatic aesthetic failure. Body-anchor or baseline motion
is accepted only when it matches the action card and deterministic pose guide;
uneven model drift may receive a reviewed integer-translation-only correction
after transparency, without scaling or deforming the pose. Clipping and
synthetic interpolation are hard failures.

Run state Motion QA immediately after acceptance. After all actions, inspect
all authored-timing previews, `keyframes.png`, and the 8–12 second presence
preview, then bind `motion-review`. Never retime authored frames to pass the
preview. Any frame or timing edit requires fresh evidence.
