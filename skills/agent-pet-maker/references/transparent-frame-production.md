# Native-Alpha and flat-chroma transparent-frame production

## Contents

1. Fixed policy
2. Native-Alpha generation and retries
3. Source contract
4. Job file and command
5. Deterministic pipeline
6. Failure handling
7. Acceptance

## Fixed policy

Use this contract for every new or regenerated Maker or Studio frame. Preserve
unchanged frames from a validated revision byte-for-byte.

For ChatGPT/Codex built-in `imagegen`, including Codex-backed App Studio,
request native transparent RGBA first for the production base and each action.
Use `source_mode: native_alpha` only after inspecting the actual Alpha channel.
Other providers, including Dreamina, keep the `flat_chroma` path below. Codex
may fall back to that path only after the retry protocol below. Use only:

```text
<maker-skill-dir>/scripts/prepare_transparent_frames.py
```

For `flat_chroma`, the script owns background connectivity, matte thresholds, Alpha-boundary RGB
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
Alpha, or resizing code. Use its explicit placement controls for layout
corrections. Do not tune its thresholds.

For `native_alpha`, the same script preserves the decoded source RGBA master
and supports proportional scaling and transparent-canvas placement. It never
mattes, reconstructs RGB, contracts Alpha, or feathers the native image.
Hidden RGB where Alpha is zero and near-opaque interior Alpha (for example
253) are not defects by themselves; judge their visible compositing result.

## Native-Alpha generation and retries

Track attempts separately for the production base and for each action. A call
for another action, repeated QA on one output, or an unrelated provider call
cannot count toward that object's retry minimum. Stop early if a native result
passes; before falling back, make **at least 3 actual native-transparency image
calls for that same object**, changing the prompt in response to each failure.
Do not repeat an unchanged prompt or count an unexecuted request as an attempt.

1. Request an isolated full-body character or the complete ordered action on a
   transparent RGBA PNG canvas with no painted background, checkerboard,
   floor, shadow, or guide marks. Keep the canonical identity and the recorded
   action geometry and references.
2. If the result is RGB, fully opaque, or paints a checkerboard, simplify the
   prompt and explicitly request a real Alpha channel with empty pixels outside
   the subject. Remove conflicting background language; label pose/size guides
   as structure only, never artwork to reproduce.
3. Use the observed remaining failure to rewrite the next request: reinforce
   empty background Alpha for false transparency, remove accidental backdrops
   or halos, or clarify the same safe-box occupancy for clipping. Preserve
   complete frame count, timing, identity, and usable detail. Correct layout
   through quality-preserving processing before deciding regeneration is needed.

Use `scripts/generation_evidence.py` in the directory containing `petpack-source`.
Before a call, run:

```bash
python3 <maker-skill-dir>/scripts/generation_evidence.py check \
  --workspace /absolute/workspace --object thinking \
  --provider codex_imagegen --mode native_alpha
```

After inspecting each actual output, save its exact executed prompt as a UTF-8
file, and record the result (use its actual unique tool-call identifier):

```bash
python3 <maker-skill-dir>/scripts/generation_evidence.py record \
  --workspace /absolute/workspace --object thinking \
  --provider codex_imagegen --mode native_alpha --call-id actual-call-id \
  --source /absolute/raw-output.png --prompt-file /absolute/executed-prompt.txt \
  --outcome rejected --reason 'Decoded output is opaque; remove background language on retry.'
```

Use `base` or the exact action name, `accepted` only after actual Alpha,
geometry, and visual inspection, and `flat_chroma` only after `check` allows it.
Other providers use `--provider other`. Keep concrete failure/correction notes,
geometry sidecars, transparent masters and transparency reports in the workspace.
The helper retains untouched image and prompt copies under `.generation-inputs`
and appends bounded `generation-evidence.json`; never package these files.
On continuation, validate this existing ledger with `check` before deciding
which attempt comes next. A success closes its retry cycle; previous failures
cannot authorize fallback in a new cycle. Calls and provider labels are the
producer's declarations, not provider-authenticated attestations.

When the latest retained output becomes usable after processing, use
`generation_evidence.py reassess --workspace /absolute/workspace --call-id
actual-call-id --outcome accepted --reason 'Concrete processing and review
result'`. It retains the previous assessment in `.generation-inputs`, validates
the same untouched source/prompt, and changes no call count. It cannot rewrite
an older retry cycle. Reassessment invalidates existing QA/review bindings;
rerun them. Never launch a new image call solely to change a review outcome.

To reuse an earlier source after successful processing and visual review, use
`generation_evidence.py select --workspace /absolute/workspace --call-id
actual-call-id --reason 'Concrete processing and review result'`. This records
the selected call without changing its original assessment or retry cycles.
The source must still match its declared Alpha mode and retained hashes. A new
call for the object clears its selection; every selection invalidates existing
QA/review bindings, which must be rebuilt against the chosen final frames.

Final combined Motion QA binds the ledger hash. PetCore production verification
independently checks artifact hashes, prompt changes, per-object retry counts,
and explicit selections or latest accepted outcomes for the base plus all actions on creation, or
exactly the regenerated actions on revision. Missing or changed evidence
requires restoring the real records and rerunning QA/review; never fabricate
past calls to satisfy validation.

After three failed native attempts, use one flat-chroma generation with the
bounded repair path below. Do not keep launching native retries indefinitely;
additional attempts need a concrete correction. Tool unavailability, exhausted
quota, cancellation, or a provider refusal is a stopping condition, not evidence
that three generation attempts succeeded or authorization to bypass a refusal.

Inspect actual Alpha and all preview backgrounds. RGBA encoding alone is not
proof: reject a flattened checkerboard, empty image, visible background layer,
clipped subject, or unacceptable translucency. Geometry/identity/action defects
still require correction even when changing the background method. Native
geometry may use the same proportional placement as flat chroma; do not apply
chroma filters to genuine native Alpha. Unrepairable source defects need
regeneration or the qualified chroma fallback after the attempt minimum.

## Source contract

For `native_alpha`, request genuine transparent empty margins and retain
subject lighting, geometry, frame order, and source capacity. For `flat_chroma`,
request:

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

After every image call, save and inspect the untouched result and record crops
that retain every complete pose. Source dimensions, aspect ratio, occupancy,
and registration need not match the runtime canvas or guides exactly. Correct
these with proportional scale, translation, and transparent margins; inspect
the final detail and animation. Regenerate missing anatomy, inseparable
overlap, identity changes, or inadequate detail. The shared
[layout correction](visual-production-and-native-resolution.md#layout-correction-and-recovery)
contract owns the quality criteria.

After a frame passes this transparency gate, Motion QA may show that its whole
subject anchor or baseline does not follow the action card. If registration is
the only defect, `petpack_workspace.py motion-align` may create a separate
candidate row using integer whole-frame translation. It must preserve decoded
RGBA pixels, perform no resampling or Alpha filtering, reject any lost Alpha or
transparent-padding violation, and remain outside `petpack-source` until the
authored-timing sequence is inspected. Copy only approved outputs back, then
rerun Motion QA and motion review. For scaling or source-framing corrections,
use this script's `placement` from retained originals instead of repeatedly
resampling runtime frames. Neither path may suppress intentional motion or
deform anatomy.

## Job file and command

Create the job file outside `petpack-source`. Use absolute paths:

```json
{
  "schema_version": "apc.transparent-frame-jobs.v1",
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

`source_mode` is `native_alpha` or `flat_chroma` at job level, with an optional
frame override. Omission preserves the default `flat_chroma` behavior; the
script never silently switches modes. Native jobs reject chroma keys, masks,
and nonzero `--edge-contract`/`--edge-feather` options. For flat-chroma jobs,
use `"key_color": "auto"` normally. An explicit `#RRGGBB` key still receives
the same validation. Omit `crop` when the whole input is one complete pose.

Without `placement`, the script proportionally fits the source crop into the
runtime canvas and centers it. A frame may instead declare:

```json
"placement": {
  "scale": 0.8,
  "x": 38,
  "y": -20,
  "reason": "Match the standing head scale and foot baseline while preserving the raised hand."
}
```

`scale` multiplies both source-crop dimensions. `x`/`y` place the resized crop's
top-left in runtime pixels; negative offsets may discard empty surrounding
pixels, never subject Alpha. The output is always the selected exact tier.
The report records scale, rounded size, offset, filter, and review reason.
Enlargement is permitted with an explicit detail-review warning, not treated
as proof of resolution. Compare faces, edges, clothing, and authored motion.

```bash
python3 <maker-skill-dir>/scripts/prepare_transparent_frames.py \
  --jobs /absolute/workspace/transparent-frame-jobs.json \
  --report /absolute/workspace/transparency-report.json \
  --preview-dir /absolute/workspace/transparency-previews
```

The command fails closed and does not overwrite by default. Even with `--replace`,
no output, master, report, or preview may alias any batch source, mask, or jobs
file, including through parent-directory symlinks or hard links. Keep jobs, reports,
previews, masks, raw sources, and transparent masters outside the package.

## Deterministic pipeline

Both modes decode and crop without resampling,
retain a source-resolution transparent master, normalize once, and run
structural Alpha QA plus checkerboard, white, gray, black, and color previews.
Native Alpha requires at least 1% visible subject and 1% fully transparent
background, with no visible frame-edge contact. Its hidden RGB is reported
without rejection; chroma metrics are inapplicable. A passing numerical report
still requires visual inspection for a backdrop, painted grid, halo, or holes.

For `flat_chroma`, the script, in order:

1. decodes the still image, applies the declared source crop, rejects native
   Alpha in this mode;
2. samples the border key and rejects low saturation or excess variation;
3. removes only conservative key candidates connected to the frame border;
4. reconstructs contaminated RGB only inside the source Alpha boundary and
   verifies byte-identical opaque-interior RGB;
5. saves the source-resolution transparent master, then performs one
   linear-light premultiplied-Alpha Lanczos proportional resize or an exact
   copy, then places it on the transparent runtime canvas;
6. applies an explicitly requested bounded Alpha fallback, then reconstructs
   newly exposed key contamination only inside the final runtime Alpha boundary
   without changing Alpha or opaque-interior RGB;
7. runs structural/chroma QA and renders checkerboard, white, gray, black, and
   complementary-color previews.

Keep this stage order. Revise transforms from retained sources when possible
to avoid cumulative resampling; rerun QA after any pixel change.

## Failure handling

Treat a non-zero exit or any `"ok": false` frame as unusable. For native Alpha,
fix job or placement errors without a new image call; unrepairable source
defects use the native retry protocol above. The following matte repairs apply only to
`flat_chroma`:

- `invalid_chroma_source`: regenerate on a flatter, contrasting opaque key.
- `placement_clips_subject`: adjust scale, crop, or position while preserving
  the complete subject. Judge detail at the target size before regeneration.
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
- Extract complete poses and record layout corrections. Do not enumerate
  adjacent crops as an indirect way to tune chroma-key sampling; correct
  framing and scale explicitly with `placement` and inspect the result.
- After that bounded local path, regenerate on a flatter contrasting opaque
  background. If the same source defect occurs twice, change the prompt, key
  choice, or action design instead of extending the parameter search.

Start every retry from the untouched opaque crop. Do not stack fallback runs or
rerun frames that already passed.

## Acceptance

Accept a state only when:

- the report root and every frame say `"ok": true`;
- the master keeps source dimensions, normalization records the applied
  proportional transform, and the runtime PNG matches the package tier;
- visible canvas-edge contact is zero in both modes; native RGBA is preserved
  in the source master before proportional placement, with no Alpha or RGB edge repair;
- for flat chroma, opaque-interior RGB changes, transparent RGB residue, and
  hard edge fringe are all zero; only a reported bounded
  `review_warning` may retain nonzero isolated low-Alpha edge evidence;
- for flat chroma, `visible_key_pixels` remains reported for both master and runtime output but
  is review evidence only and never fails a frame by itself;
- enclosed transparent components have been intentionally reviewed;
- all five preview backgrounds are visually clean at 100%, including any pixels
  counted by `visible_key_pixels` or the bounded edge-fringe warning;
- the exact-tier authored-timing animation passes identity, action, anatomy,
  prop, continuity, crop, settle/loop, and reduced-motion review.

Package only exact-tier runtime PNGs. Retain untouched native-Alpha or opaque sources and
source-resolution transparent masters as workspace evidence.
