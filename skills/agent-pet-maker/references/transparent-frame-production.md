# Flat-chroma transparent-frame production

## Contents

1. Scope and fixed policy
2. Source-image contract
3. Canonical job file and command
4. Deterministic pixel pipeline
5. Failure and fallback policy
6. Acceptance and artifact policy

## Scope and fixed policy

Use this contract for every newly generated or regenerated animation frame in
Maker and Studio. Existing unchanged frames from a validated revision may stay
byte-identical.

Do not ask the image model for native transparency. Generate fully opaque art
on one flat chroma background, then use the shared script to create transparent
PNG masters and runtime frames. Do not depend on the model returning the exact
runtime dimensions: the decoded source crop may be larger for any of the three
tiers and the shared script will normalize it once. This avoids
provider-specific Alpha and size behavior and makes the same source produce the
same result across agents.

The general Codex `imagegen` skill also starts simple transparent requests with
border key sampling, a soft matte, de-spill, and a bounded one-pixel retry. This
pet contract keeps those useful defaults but supersedes its general-purpose
`remove_chroma_key.py` helper: pet frames additionally require spatial
background connectivity, opaque-interior RGB preservation, source-resolution
master retention, Alpha-aware sizing, closed parameters, and five-background QA. Do
not call the general helper or offer its model-native transparency fallback for
Maker or Studio; regenerate with another flat key, use the bounded mask path,
choose a lower qualified tier, or return `capability_missing`.

The canonical implementation is:

```text
<maker-skill-dir>/scripts/prepare_transparent_frames.py
```

Do not replace it with agent-authored Pillow, OpenCV, ImageMagick, shell,
background-removal, color-replacement, or resizing code. Do not tune matte
thresholds. The script intentionally exposes crop geometry, target tier, key
selection, and an optional sure-foreground mask, but owns all pixel thresholds
and filters.

## Source-image contract

Ask the image producer for:

- one single, fully opaque, uniformly saturated background color;
- a background color absent from the character, clothing, props, effects, and
  important reflected light;
- no floor, contact shadow, background texture, gradient, horizon, glow,
  reflection, translucent smoke, or background-colored rim light;
- neutral subject lighting and enough empty margin around every visible pixel;
- fixed 12:13 cell geometry with stable camera, scale, registration, and
  gutters across the state;
- all ordered poses for one state in one batch whenever provider capacity
  permits.

Ask for enough source detail and safe spacing, but treat any requested pixel
dimensions as guidance only. A useful output is acceptable when its real
decoded dimensions differ from the prompt, provided every intended frame can
be recovered as a complete 12:13 source crop at least as large as the selected
runtime tier.

Green is acceptable only when the subject contains no meaningful green. Use a
different saturated key, commonly magenta or blue, when green appears in fur,
skin lighting, clothing, props, or effects. Changing the key is safer than
widening a matte.

After every image call:

1. Save the untouched decoded result outside `petpack-source`.
2. Inspect it at 100% and record one source-pixel crop for each cell. Keep one
   stable crop size and slot-relative registration across a state; do not fit,
   scale, or recenter each subject independently.
3. Require every crop to be exactly 12:13 and at least as large as the selected
   runtime tier in both dimensions.
4. Crop without resampling. Never pre-enlarge, pad, stretch, sharpen, or apply
   super-resolution.
5. Reject a non-uniform background, background cast across the subject,
   clipping, grid leakage, duplicate/missing poses, or an undersized crop.

The cropped opaque source is the input to the shared script. The transparent
master keeps that crop's source dimensions. A `low`, `standard`, or `high`
runtime frame is either an exact copy at the selected tier or one direct
downscale from that master. Never upscale and never resize through an
intermediate tier.

## Canonical job file and command

Create one job file outside `petpack-source`. Paths must be absolute. A source
sheet may be reused by multiple frame entries with different crop rectangles:

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

Use `"key_color": "auto"` normally. An explicit `#RRGGBB` value still receives
the same border-uniformity validation; it is not a threshold override. Omit
`crop` only when the whole image is exactly one 12:13 frame.

Run:

```bash
python3 <maker-skill-dir>/scripts/prepare_transparent_frames.py \
  --jobs /absolute/workspace/transparent-frame-jobs.json \
  --report /absolute/workspace/transparency-report.json \
  --preview-dir /absolute/workspace/transparency-previews
```

The command fails closed and never overwrites output by default. Use
`--replace` only after deliberately revising the same jobs or applying the
bounded edge fallback below. Do not put the job file, report, previews, raw
sources, masks, or transparent masters inside the final package.

The report records the closed pipeline ID, script digest, Python/Pillow runtime,
source and optional mask digests, crop geometry, key sample, resize count,
output digests, and QA measurements. Keep it with workspace evidence so a later
revision can distinguish changed inputs from a changed implementation runtime.

## Deterministic pixel pipeline

The shared script performs these stages in order:

1. Decode one still image at its actual returned dimensions, crop in source
   pixels, confirm a 12:13 crop, reject model-native Alpha, and reject an
   undersized crop. The source image and crop do not need to equal the target
   dimensions.
2. Estimate the flat key from the border, then reject insufficient saturation
   or border variation instead of relaxing thresholds.
3. Build a conservative soft matte from key distance and color dominance. By
   default, only key candidates spatially connected to the frame border are
   removed. Disconnected key-colored subject detail remains opaque and causes
   QA failure rather than an unnoticed hole.
4. Reconstruct contaminated RGB only inside the Alpha boundary and only where
   chroma evidence exists. Opaque interior RGB is checked for byte-for-byte
   preservation; there is no global de-spill or global hue change.
5. Save the source-resolution transparent master, then create the runtime frame with one
   linear-light premultiplied Alpha Lanczos downscale or an exact-size copy.
   Fully transparent pixels are canonical transparent black.
6. Run structural and chroma QA and render a five-panel preview on transparent
   checkerboard, white, gray, black, and the key's complementary color.

These stages are indivisible. Agents must not reorder them, perform another
resize, post-sharpen RGB, replace Alpha, globally suppress a color channel, or
run an additional edge-cleaning filter after the script.

## Failure and fallback policy

Treat a non-zero exit or any frame with `"ok": false` as unusable, even when
inspection artifacts were written.

- `invalid_chroma_source`: regenerate with a flatter, fully opaque background.
  Do not widen the threshold or patch the background globally.
- `source_capacity_missing`: use a genuinely larger source crop or choose a lower
  tier with the user. Do not upscale or split batches to manufacture capacity.
- Visible key-colored subject pixels: regenerate with a contrasting key. The
  safe default preserves them rather than punching holes.
- Enclosed background between limbs, hair, clothing, or props: if regeneration
  cannot open a path to the border, supply a coarse sure-foreground mask. White
  pixels mean “must remain foreground”; black pixels remain eligible for matte
  removal. The mask may match the full source or the crop. It must contain both
  values, use hard black/white without gray or antialiased edges, be visually
  inspected, and not trace or erode fine Alpha edges. A mask is not permission
  to keep a conflicting key color.
- Remaining edge contamination after a valid default run: inspect the source
  and preview first. Regeneration with a better key is preferred. As a bounded
  last resort, rerun the same jobs with `--replace --edge-contract 1`; this
  contracts Alpha by at most one final-size pixel and leaves the master intact.
- Visible staircase after that bounded contraction: `--edge-feather 0.25` may
  be added. `0.5` is the absolute maximum. Do not feather fur, lace,
  translucency, glows, or already-soft edges merely to hide a bad matte.

Do not stack fallback runs. Every fallback starts again from the untouched
opaque crop and replaces the prior derived artifacts once.

## Acceptance and artifact policy

Accept a state only when:

- the report root and every frame contain `"ok": true`;
- master and runtime dimensions match the report, `size_normalization` is
  either `exact_copy` or `single_downscale`, and the runtime matches the package
  tier;
- `interior_opaque_rgb_changed_pixels` is zero;
- no visible pixel touches the canvas border;
- transparent RGB residue, visible key pixels, and edge chroma fringe are zero;
- every reported enclosed transparent component has been intentionally
  reviewed;
- the five-panel preview is clean at 100%, with no green/key halo, black/white
  fringe, lost hair, lace, fingers, clothing, or prop detail;
- the runtime frame is inspected at actual display size and the authored-timing
  animation passes the same identity, action, continuity, crop, prop, settle,
  and reduced-motion Motion QA as an exact-size source.

Keep the untouched opaque sources and source-resolution transparent masters as
workspace evidence. Package only the selected-tier runtime PNG frames and the
existing V3 source metadata. A larger master improves future revision and
downscale quality, but it does not upgrade the package tier or make an
undersized generated cell acceptable.
