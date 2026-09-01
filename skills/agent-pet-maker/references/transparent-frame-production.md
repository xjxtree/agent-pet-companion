# Native-Alpha-first transparent-frame production

## Contents

1. Fixed policy
2. Source-mode routing
3. Native-Alpha source contract
4. Chroma-key compatibility contract
5. Job file and command
6. Deterministic pipeline
7. Failure handling
8. Acceptance

## Fixed policy

Use this contract for every new or regenerated Maker or Studio frame. Preserve
unchanged frames from a validated revision byte-for-byte. Use only:

```text
<maker-skill-dir>/scripts/prepare_transparent_frames.py
```

ChatGPT/Codex built-in `imagegen` defaults to genuine transparent PNG source
art. The script preserves its authored Alpha and every nontransparent RGBA
pixel, clears only hidden RGB beneath Alpha 0, retains a source-resolution
transparent master, and performs the sole optional linear-light premultiplied-
Alpha downscale. It never remattes or color-keys native-Alpha artwork.

Flat chroma is a compatibility source mode for a selected provider or supplied
artwork that cannot emit genuine Alpha. In that mode the same script owns
background connectivity, matte thresholds, Alpha-boundary RGB reconstruction,
source-resolution master retention, exact sizing, and QA. Do not replace the
script with custom Pillow, OpenCV, ImageMagick, shell, background-removal,
color-replacement, edge-cleaning, Alpha, or resizing code. Do not tune its
thresholds.

## Source-mode routing

| Source | Required mode | Rule |
| --- | --- | --- |
| ChatGPT/Codex built-in `imagegen` | `native_alpha` | Product default for `low` and `standard`; request a real transparent canvas and preserve the returned PNG Alpha. |
| Another provider with verified decoded Alpha | `native_alpha` | Use only after decoded pixels prove genuine transparency. |
| Dreamina high workflow or another opaque-only source | `chroma_key` | Request one uniform contrasting key and use the bounded matte path. |

Version 2 jobs default to `native_alpha`. Version 1 job files remain readable as
`chroma_key` compatibility input. Do not silently switch a built-in `imagegen`
action from native Alpha to chroma. Regenerate only the failing action with a
targeted transparency prompt; if it still cannot produce valid Alpha, retain
the failure evidence and ask before changing image source or mode.

## Native-Alpha source contract

Ask built-in `imagegen` for:

- a genuinely transparent canvas with Alpha 0 outside every character;
- smooth authored antialiasing and translucent detail where the design needs
  it, without flattening onto a background color;
- no checkerboard pattern, solid or gradient backdrop, floor, contact shadow,
  reflection, glow, smoke, border, text, watermark, or floating background
  effect;
- clear transparent margins around all four edges and transparent gutters
  between every ordered pose;
- stable 12:13 cell geometry, camera, scale, registration, baseline, and
  gutters across the action.

Built-in outputs are initially saved below `$CODEX_HOME/generated_images`.
Copy the selected original PNG into the private pet workspace before crop or
QA, leave the built-in original in place, and never package or record the
Codex-cache path. Inspect decoded RGBA, not only the conversation preview.
Require real Alpha-0 exterior pixels, visible subject pixels, no baked
checkerboard, the exact frame count/order, and complete stable source crops at
least as large as the runtime target.

The script rejects a native source with no fully transparent pixels or no
visible subject. It preserves the complete Alpha plane even when the subject's
opaque-looking interior uses Alpha 253 or 254 rather than 255. Edge contraction,
feathering, sure-foreground masks, and key colors are forbidden in this mode;
regenerate source artwork when its native silhouette is defective.

## Chroma-key compatibility contract

Request:

- one fully opaque, uniformly saturated background color absent from the
  subject, clothing, props, effects, and important reflected light;
- no floor, contact shadow, texture, gradient, horizon, glow, reflection,
  smoke, or background-colored rim light;
- neutral subject lighting and clear empty margins;
- stable 12:13 cell geometry, camera, scale, registration, baseline, and
  gutters across one action.

Use green only when the subject has no meaningful green. Otherwise choose a
contrasting saturated key such as magenta or blue. Save and inspect the
untouched result, record stable equal-size source-pixel crops, require each crop
to be 12:13 and at least the runtime target, and crop without resampling. Reject
non-uniform background, color cast, clipping, guide leakage, duplicate or
missing poses, and undersized crops. Never enlarge, pad, stretch, sharpen, or
apply super-resolution.

After a frame passes either transparency mode, Motion QA may show that its
whole-subject anchor or baseline does not follow the action card. If
registration is the only defect, `petpack_workspace.py motion-align` may create
a separate candidate row using integer whole-frame translation. It must
preserve decoded RGBA pixels, perform no resampling or Alpha filtering, reject
lost Alpha or transparent-padding violations, and remain outside
`petpack-source` until the authored-timing sequence is inspected. Copy only
approved outputs back, then rerun Motion QA and motion review.

## Job file and command

Create the version 2 job file outside `petpack-source`. `native_alpha` is the
default, but write it explicitly in production evidence:

```json
{
  "schema_version": "apc.transparent-frame-jobs.v2",
  "target_size": {"width": 384, "height": 416},
  "source_mode": "native_alpha",
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

For an explicit opaque compatibility source, set
`"source_mode": "chroma_key"` and add `"key_color": "auto"`. A per-frame
mode override is allowed only when the job genuinely contains mixed accepted
sources. An explicit `#RRGGBB` chroma key still receives border validation.
Omit `crop` only when the complete source is one 12:13 frame.

```bash
python3 <maker-skill-dir>/scripts/prepare_transparent_frames.py \
  --jobs /absolute/workspace/transparent-frame-jobs.json \
  --report /absolute/workspace/transparency-report.json \
  --preview-dir /absolute/workspace/transparency-previews
```

The command fails closed and does not overwrite by default. Keep jobs, reports,
previews, masks, raw sources, and transparent masters outside the package.

## Deterministic pipeline

For `native_alpha`, the script:

1. decodes the still image, applies the declared source crop, and verifies
   source capacity;
2. requires both fully transparent and visible pixels;
3. preserves the complete authored Alpha plane and all nontransparent RGBA,
   clearing only hidden RGB beneath Alpha 0;
4. saves the source-resolution transparent master.

For `chroma_key`, the script:

1. decodes the still image, applies the crop, rejects source Alpha, and verifies
   capacity;
2. samples the border key and rejects low saturation or excess variation;
3. removes only conservative key candidates connected to the frame border;
4. reconstructs contaminated RGB only inside the source Alpha boundary and
   verifies byte-identical opaque-interior RGB;
5. saves the source-resolution transparent master.

Both modes then perform one linear-light premultiplied-Alpha Lanczos downscale
or an exact copy, zero hidden RGB where final Alpha is 0, run structural/Alpha
QA, and render checkerboard, white, gray, black, and a deterministic
high-contrast-color preview. Only `chroma_key` may apply its explicitly
requested bounded Alpha fallback and final chroma-evidence RGB reconstruction.
Do not reorder stages or post-process output.

## Failure handling

Treat a non-zero exit or any `"ok": false` frame as unusable.

For `native_alpha`:

- `invalid_native_alpha_source`: regenerate only that base/action with the
  exact transparent-canvas constraints; reject a baked checkerboard or opaque
  backdrop.
- Visible canvas contact, poor antialiasing, unwanted shadow/glow, or dirty
  edges: inspect all five previews, then regenerate. Do not contract, feather,
  recolor, or rematte native Alpha.
- Repeated built-in output failure: keep accepted actions, preserve the failing
  source and report, and ask before changing provider or source mode.

For `chroma_key`:

- `invalid_chroma_source`: regenerate on a flatter, contrasting opaque key.
- Meaningful key-colored subject detail: inspect all previews. Use another key
  only when automatic sampling is visibly wrong or the detail is confused with
  the matte; the diagnostic count alone is not a failure.
- Enclosed background: prefer regeneration. If necessary, supply a visually
  inspected hard black/white sure-foreground mask; white remains foreground
  and black remains matte-eligible.
- A hard residual edge result after both deterministic RGB repairs: rerun only
  failing frames once from untouched sources with `--replace --edge-contract
  1`. Add `--edge-feather 0.25` only for a staircase visibly caused by that
  contraction. `0.5` is an exceptional inspected maximum.
- After the bounded local path, regenerate on a flatter contrasting opaque
  background. Do not stack fallback runs or enumerate adjacent crops, similar
  key colors, or feather values.

For either mode, `source_capacity_missing` requires a larger real source crop
or a lower tier; never upscale. Keep the recorded equal-size shared action crop
unless deterministic geometry proves it wrong. Regenerate at the proper scale
when the subject overflows correct geometry.

## Acceptance

Accept a state only when:

- the report root and every frame say `"ok": true`;
- the report records the intended `source_mode` and the native mode preserves
  Alpha plus all nontransparent RGBA;
- normalization is `exact_copy` or `single_downscale`, the master keeps source
  dimensions, and the runtime PNG matches the package tier;
- every frame has at least 1% visible and 1% fully transparent coverage, no
  visible canvas-edge contact, and no hidden RGB beneath Alpha 0;
- chroma mode reports zero opaque-interior RGB changes and zero hard edge
  fringe; `visible_key_pixels` remains review evidence only, and only its
  bounded `review_warning` may retain no more than 0.5 equivalent opaque pixel;
- enclosed transparent components are intentional;
- all five preview backgrounds are clean at 100%, including soft hair, fur,
  fabric, translucent effects, and any chroma warning;
- the exact-tier authored-timing animation passes identity, action, anatomy,
  prop, continuity, crop, settle/loop, and reduced-motion review.

Package only exact-tier runtime PNGs. Retain untouched raw sources and
source-resolution transparent masters as private workspace evidence.
