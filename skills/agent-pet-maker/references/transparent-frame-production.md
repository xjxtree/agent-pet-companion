# Flat-chroma transparent-frame production

## Contents

1. Fixed policy
2. Source contract
3. Job file and command
4. Deterministic pipeline
5. Failure handling
6. Acceptance

## Fixed policy

Use this contract for every new or regenerated Maker or Studio frame. Preserve
unchanged frames from a validated revision byte-for-byte.

Generate fully opaque art on one flat chroma background. Do not request
model-native transparency. Use only:

```text
<maker-skill-dir>/scripts/prepare_transparent_frames.py
```

The script owns background connectivity, matte thresholds, Alpha-boundary RGB
reconstruction at source and final runtime size, source-resolution master
retention, exact sizing, and multi-background QA. `visible_key_pixels` is a
diagnostic count, not a zero-tolerance gate: an isolated key-like subject pixel
does not by itself make a frame invalid. After both deterministic RGB repairs,
the only nonzero edge-fringe result that may remain usable is the script's
closed `review_warning`: no more than 4/8/12 raw pixels for low/standard/high,
no pixel above Alpha 48, no more than 0.5 equivalent opaque pixel in total, and
no connected component larger than two pixels. It still requires review on all
five backgrounds. Do not replace the script with custom Pillow, OpenCV,
ImageMagick, shell, background-removal, color-replacement, edge-cleaning,
Alpha, or resizing code. Do not tune its thresholds.

## Source contract

Request:

- one fully opaque, uniformly saturated background color absent from the
  subject, clothing, props, effects, and important reflected light;
- no floor, contact shadow, texture, gradient, horizon, glow, reflection,
  smoke, or background-colored rim light;
- neutral subject lighting and clear empty margins;
- stable 12:13 cell geometry, camera, scale, registration, baseline, and
  gutters across one action;
- all ordered poses in one batch when provider capacity permits.

Use green only when the subject has no meaningful green. Otherwise choose a
contrasting saturated key such as magenta or blue.

After every image call, save and inspect the untouched result, record stable
equal-size source-pixel crops, require each crop to be 12:13 and at least the
runtime target, and crop without resampling. Reject non-uniform background,
color cast, clipping, guide leakage, duplicate or missing poses, and undersized
crops. Never enlarge, pad, stretch, sharpen, or apply super-resolution.

After a frame passes this transparency gate, Motion QA may show that its whole
subject anchor or baseline does not follow the action card. If registration is
the only defect, `petpack_workspace.py motion-align` may create a separate
candidate row using integer whole-frame translation. It must preserve decoded
RGBA pixels, perform no resampling or Alpha filtering, reject any lost Alpha or
transparent-padding violation, and remain outside `petpack-source` until the
authored-timing sequence is inspected. Copy only approved outputs back, then
rerun Motion QA and motion review. This exception does not permit per-pose
scaling, body deformation, crop repair, or suppression of intentional motion.

## Job file and command

Create the job file outside `petpack-source`. Use absolute paths:

```json
{
  "schema_version": "apc.transparent-frame-jobs.v1",
  "target_size": {"width": 384, "height": 416},
  "key_color": "auto",
  "frames": [
    {
      "id": "idle/000",
      "source": "/absolute/workspace/raw/idle-sheet.png",
      "crop": {"x": 0, "y": 0, "width": 576, "height": 624},
      "master": "/absolute/workspace/transparent-masters/idle/000.png",
      "output": "/absolute/workspace/petpack-source/assets/frames/idle/000.png"
    }
  ]
}
```

Use `"key_color": "auto"` normally. An explicit `#RRGGBB` key still receives
the same validation. Omit `crop` only when the whole input is one 12:13 frame.

```bash
python3 <maker-skill-dir>/scripts/prepare_transparent_frames.py \
  --jobs /absolute/workspace/transparent-frame-jobs.json \
  --report /absolute/workspace/transparency-report.json \
  --preview-dir /absolute/workspace/transparency-previews
```

The command fails closed and does not overwrite by default. Keep jobs, reports,
previews, masks, raw sources, and transparent masters outside the package.

## Deterministic pipeline

The script, in order:

1. decodes the still image, applies the declared source crop, rejects native
   Alpha and insufficient source capacity;
2. samples the border key and rejects low saturation or excess variation;
3. removes only conservative key candidates connected to the frame border;
4. reconstructs contaminated RGB only inside the source Alpha boundary and
   verifies byte-identical opaque-interior RGB;
5. saves the source-resolution transparent master, then performs one
   linear-light premultiplied-Alpha Lanczos downscale or an exact copy;
6. applies an explicitly requested bounded Alpha fallback, then reconstructs
   newly exposed key contamination only inside the final runtime Alpha boundary
   without changing Alpha or opaque-interior RGB;
7. runs structural/chroma QA and renders checkerboard, white, gray, black, and
   complementary-color previews.

Do not reorder the stages or post-process the output.

## Failure handling

Treat a non-zero exit or any `"ok": false` frame as unusable.

- `invalid_chroma_source`: regenerate on a flatter, contrasting opaque key.
- `source_capacity_missing`: obtain a larger real source crop or ask the user
  to choose a lower tier; never upscale.
- Meaningful key-colored subject detail: inspect all five previews. Use another
  key only when automatic sampling is visibly wrong or the detail is actually
  confused with the matte; the diagnostic count alone is not a failure. Do not
  enumerate similar explicit key colors to repair an edge-fringe result.
- Enclosed background: prefer regeneration. If necessary, supply a visually
  inspected hard black/white sure-foreground mask; white must remain foreground
  and black remains matte-eligible. The mask may not trace or erode fine edges.
- A hard residual edge-contamination result after the default source- and
  runtime-size RGB repairs: inspect first, then rerun only the failing frames
  once from untouched sources with `--replace --edge-contract 1`.
- A staircase visibly caused by that contraction may add
  `--edge-feather 0.25`; `0.5` remains an exceptional manually inspected
  maximum, not another routine search candidate. Do not feather fur, lace,
  glows, translucency, or already-soft edges to conceal a bad matte.
- Keep the recorded equal-size shared action crop. Change it only when canvas
  contact or the deterministic geometry record proves the crop itself wrong;
  never search adjacent per-frame crops. If the subject overflows correct
  geometry, regenerate it at the proper scale.
- After that bounded local path, regenerate on a flatter contrasting opaque
  background. If the same source defect occurs twice, change the prompt, key
  choice, or action design instead of extending the parameter search.

Start every retry from the untouched opaque crop. Do not stack fallback runs or
rerun frames that already passed.

## Acceptance

Accept a state only when:

- the report root and every frame say `"ok": true`;
- normalization is `exact_copy` or `single_downscale`, the master keeps source
  dimensions, and the runtime PNG matches the package tier;
- opaque-interior RGB changes, transparent RGB residue, hard edge fringe, and
  visible canvas-edge contact are all zero; only a reported bounded
  `review_warning` may retain nonzero isolated low-Alpha edge evidence;
- `visible_key_pixels` remains reported for both master and runtime output but
  is review evidence only and never fails a frame by itself;
- enclosed transparent components have been intentionally reviewed;
- all five preview backgrounds are visually clean at 100%, including any pixels
  counted by `visible_key_pixels` or the bounded edge-fringe warning;
- the exact-tier authored-timing animation passes identity, action, anatomy,
  prop, continuity, crop, settle/loop, and reduced-motion review.

Package only exact-tier runtime PNGs. Retain untouched opaque sources and
source-resolution transparent masters as workspace evidence.
