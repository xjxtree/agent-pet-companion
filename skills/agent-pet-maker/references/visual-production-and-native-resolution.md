# Visual production and source-size normalization

## Contents

1. Runtime target and source quality
2. Provider routing
3. Production base and action batches
4. Deterministic pose and size guides
5. Reference and prompt contract
6. Layout correction and recovery
7. Failure routing
8. Runtime-size acceptance

## Runtime target and source quality

Treat `manifest.render_size` as the exact runtime PNG target, not an image-model
output instruction. Extract each complete pose from the actual returned image;
its source crop need not have a prescribed size or aspect ratio:

| Tier | Runtime PNG |
| --- | ---: |
| `low` | 192×208 |
| `standard` | 384×416 |
| `high` | 576×624 |

After every image call:

1. Save the untouched decoded image outside `petpack-source` and record its
   actual dimensions.
2. Verify exact frame count/order, distinct poses, full-body completeness,
   identity, anatomy, props, camera, scale, spacing, background, and action.
3. Record source-pixel rectangles containing complete poses. Equal cells are a
   useful starting point, not a reason to clip a complete returned figure.
4. Correct position, scale, and canvas differences when the artwork is clear
   and complete. Regenerate overlapping/missing anatomy, identity changes, or
   visibly inadequate detail that reasonable processing cannot fix.
5. Use the shared transparency script for Alpha-aware proportional scaling
   and transparent-canvas placement, with explicit per-frame adjustments when
   needed. Prefer a common action scale; correct accidental frame drift using
   stable anatomical landmarks rather than each pose's changing outer bounds.
6. Inspect the exact-tier runtime sequence and run Motion QA.

Agents may proportionally shrink or enlarge, translate, crop empty surroundings,
and add transparent margins when final image and motion quality remain intact.
Enlargement does not create real detail: inspect faces, costume, fine edges,
and materials at the runtime size. Keep untouched originals and rerender from
source-resolution masters with the combined transform instead of accumulating
resampling loss. Do not stretch anatomy, conceal clipping, or use transforms
to manufacture missing distinct poses. Processing is not itself a defect.

## Provider routing

Choose the tier first, then a provider whose real decoded pixels can satisfy it:

| Image path | Qualified tiers | Rule |
| --- | --- | --- |
| ChatGPT/Codex built-in `imagegen` | `low`, `standard` | Its approximate 1K–2K decoded output envelope is not qualified for `high`. |
| Dreamina 5.0 Pro | `low`, `standard`, `high` | For `high`, follow `dreamina-high-production.md` and verify the returned pixels. |
| Another provider or user artwork | Any tier supported by its visual detail | Apply the same transparency, motion, and final-quality checks. |

Do not repeatedly attempt built-in `imagegen` for `high`, combine separate
outputs to claim unproven detail, or silently downgrade. If no qualified source is available, stop
before a paid call or ask the user to select a lower tier.

## Production base and action batches

First create one complete full-body base. Lock the stated maturity or adult
identity, face, hair or defining features, body proportions, clothing,
materials, palette, lighting, camera distance, scale, crop, and persistent
props. Use this production base as reference image 1 for every later
image-to-image action.

Generate one action per call and normally keep all 4–8 ordered poses in one
batch. Use one action card that states the intent, exact frame count, the
geometry sidecar's reading order, playback outcome, safe margins, and selected
Alpha/background rules. Immediately inspect the result before another call.

Every multi-frame action uses two script-generated structural references: a
frameless pose guide as reference image 2 and a separate frameless size-
reference image as reference image 3. They must come from one geometry record
and have identical canvas dimensions, slot centers, centered 12:13 crop
windows, baseline, and `global_scale`. Text-only requests for equal-sized
figures are not scale evidence. If the active provider cannot accept the
character base and both structural references in one request, choose a
compatible provider or a supported lower tier instead of dropping the size
reference. Use guides as generation aids, not pixel-perfect acceptance rules.
Before spending another call, try quality-preserving correction of usable
artwork. If a source defect recurs, change the production approach rather than
repeating prompts that only restate exact coordinates or sizes.

An exceptional multi-batch action is allowed only for a non-capacity continuity
constraint. Carry the base and one or two accepted boundary poses into the next
batch, keep cell geometry unchanged, and inspect both sides of the join. Never
fill a sequence with duplicate poses, crossfade, morph, optical flow,
procedural interpolation, or transformed copies.

## Deterministic pose and size guides

Create both guide images with one deterministic script, never an image model.
The script must:

1. Create a pure `#FF00FF` canvas at the target action-sheet dimensions.
2. Divide it into invisible equal-size slots. A one-row sheet uses:

   ```text
   slot_width = canvas_width / frame_count
   slot_center_x = (frame_index + 0.5) * slot_width
   ```

   A multi-row sheet uses:

   ```text
   slot_width = canvas_width / columns
   slot_height = canvas_height / rows
   slot_center_x = (column + 0.5) * slot_width
   slot_center_y = (row + 0.5) * slot_height
   frame_index = row * columns + column
   ```

   Read multi-row poses left to right, then top to bottom. Do not leave an
   unused slot that the provider could fill with an extra figure.

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
image third. Explain their separate responsibilities; this template may be
shortened without losing those distinctions:

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

- the exact frame count and the sidecar's one-row or row-major order;
- one complete same-scale character in each invisible slot;
- the same identity, face, outfit, proportions, materials, and camera in every
  pose;
- the recorded full-body pixel height, head size, shoulder width, baseline, and
  safe crop occupancy from the size-reference image;
- no touching, overlap, or cropped hair, appendages, hands, feet, or heels;
- actual transparent empty margins for native Alpha, or a perfectly uniform
  textureless solid background for flat chroma; neither mode may add a floor,
  shadow, reflection, text, border, or floating effect;
- `CRITICAL SCALE LOCK` for jumps or other scale-sensitive motion;
- `contact -> settle -> passing -> advance` with alternating limbs for a walk;
- correctly connected feet and heels in every relevant pose.

Choose native Alpha or the output chroma background by the transparency contract. The guide's
magenta canvas is structural input, not an instruction to copy its color.

## Layout correction and recovery

Inspect the untouched image before rejecting a model's placement. A figure
outside the planned safe box may still be complete in the source. Extract the
whole figure, preserve its source-resolution transparent master, and use the
shared script's `placement` to set proportional scale and pixel offsets on the
runtime canvas. Empty padding and differing source crop ratios are acceptable.

Compare face/head size, shoulders, torso, and costume across actions. A squat
should become shorter through joint motion, not an accidental camera zoom.
Use a common anatomical scale and intentional baseline/anchor path; per-frame
corrections may remove accidental size or position drift. Never blindly fit
each silhouette to an identical bounding box, since raised hands, bending,
and intentional travel change that box. Record the reason and transform, inspect
all backgrounds and the authored animation, then rerun Motion QA.

If the source itself loses anatomy, merges adjacent figures, changes identity,
or cannot retain adequate runtime detail, regenerate the affected action.
Adjust the guides, composition, provider-input scale, or action design based on
the observed defect. A normalized identity reference is a generation aid;
retain the original as the identity authority. Do not spend repeated calls
trying to obtain exact output coordinates that ordinary processing can fix.

## Failure routing

- Corner marks: move subjects away from all four corners and preserve exterior
  blank space.
- Gradient or paneled background: strengthen `perfectly uniform, textureless
  solid background`.
- Copied guide figures: require complete replacement and forbid retained guide
  pixels.
- Scale drift or oversized figures: follow layout correction above; review
  anatomical scale and motion after processing.
- Pose/size disagreement: repair the shared sidecar and regenerate both guides;
  never resize or reposition one reference independently.
- Whole-subject registration drift: compare Motion QA's per-frame body-anchor
  and baseline path with the action card and deterministic pose guide. Preserve
  intentional travel and easing. If registration is the only defect, first use
  one QA-bound `motion-align` pass on the transparent exact-tier frames; choose
  a locked, equal-spacing linear, or explicit guide-target path per axis. The
  `motion-align` pass translates whole frames by integer pixels only and must
  be inspected and rerun through Motion QA. For scale or framing corrections,
  rerender from the source master using the transparency script's `placement`.
  Regenerate defects that these adjustments cannot repair at acceptable quality.
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
