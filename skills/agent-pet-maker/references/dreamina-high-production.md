# Dreamina 5.0 Pro high-resolution production

Use this provider-specific guide only when Dreamina is the selected image path.
Apply the generic visual, transparency, timing, QA, and security contracts in
the sibling references without repeating them here.

## Required parameters

Use `--model_version=5.0Pro` for every base and action request. Before the first
paid call in a session, inspect `dreamina text2image -h` and
`dreamina image2image -h` for the active CLI surface.

Generate one complete full-body production base with text-to-image at 4K, 3:4,
and one result:

```bash
dreamina text2image \
  --prompt="<complete full-body character on the required flat background>" \
  --model_version=5.0Pro \
  --resolution_type=4k \
  --ratio=3:4 \
  --generate_num=1 \
  --poll=60
```

Generate each action with image-to-image at 4K. Dreamina 5.0 Pro does not
reliably keep multiple figures equal-sized from text alone, so every action
sheet must pass the production base first, its deterministic pose guide second,
and its separate deterministic size-reference image third. Both guides come
from the same geometry record and exact request dimensions. Do not combine
`--ratio` with custom width and height.

Use these single-row starting layouts when their safe boxes fit the action:

| Frames | Request size | Invisible slot width | Largest centered 12:13 crop per slot |
| ---: | ---: | ---: | ---: |
| 8 | 6240×1536 | 780 | 780×845 |
| 6 | 5760×1536 | 960 | 960×1040 |
| 5 | 3840×1536 | 768 | 768×832 |
| 4 | 4096×1536 | 1024 | 1008×1092 |

Each listed crop exceeds 576×624, but requested dimensions are not evidence.
Inspect Dreamina's actual decoded output and prove every stable equal-size 12:13
crop before accepting it.

```bash
dreamina image2image \
  --images /absolute/character-base.png,/absolute/pose-guide.png,/absolute/size-reference.png \
  --prompt="<one action, ordered poses, shared reference-responsibility block>" \
  --model_version=5.0Pro \
  --resolution_type=4k \
  --width=6240 \
  --height=1536 \
  --generate_num=1 \
  --poll=60
```

Use both structural references even for a simple action; a near-static pose
guide is still the deterministic frame-count and registration authority, while
the separate size reference locks pixel scale and safe crop occupancy.
Substitute the table width for the authored frame count. Do not approximate an
unsupported count by adding or removing generated figures.

## Oversized-subject recovery layouts

First apply the shared decision: a complete figure that fits a stable larger
12:13 crop is normalized by the transparency script and does not need another
paid call. If a single-row result instead crosses its recorded safe box, use a
measured smaller `global_scale` and, when applicable, one of these verified
multi-row alternatives. They increase real per-slot crop capacity within the
4K canvas pixel budget; they are not permission to split an action into batches.

| Frames | Grid | Request canvas | Slot size | Largest centered 12:13 crop per slot |
| ---: | ---: | ---: | ---: | ---: |
| 4 | 2×2 | 3072×3072 | 1536×1536 | 1416×1534 |
| 6 | 2×3 | 3072×4608 | 1536×1536 | 1416×1534 |
| 8 | 2×4 | 2720×6144 | 1360×1536 | 1356×1469 |

Author and read these grids left to right, then top to bottom. Before the
corrected call, regenerate both structural references at the exact new canvas
dimensions. If the canonical identity image itself overstates occupancy, use
the provider-input-only proportional-downscale reference procedure from the
shared visual contract while preserving the untouched original as identity
authority. Save and inspect the corrected untouched output; prompted layout,
request dimensions, and the table above never prove returned crop capacity.

## Polling and credit use

Default every call to `--generate_num=1` to avoid unnecessary credit use.
Increase it only with explicit user authorization.

If the response contains `submit_id` and `gen_status=querying`, save the ID and
continue polling:

```bash
dreamina query_result --submit_id=<submit_id>
```

Stop only at `gen_status=success` or `gen_status=fail`. Preserve the reported
failure reason. On success, save and inspect the untouched image before crop or
transparency work.

## Dreamina-specific acceptance

- Keep the character away from all four corners to avoid provider corner
  marks and preserve exterior blank space.
- Require a perfectly uniform textureless solid background; reject gradients
  and paneled output.
- Require complete replacement of every pose-guide figure and reject any guide
  or size-reference pixel, mannequin, calibration silhouette, grid, label, or
  separator.
- Lock camera distance, head size, shoulder width, full-body scale, outfit, and
  materials across all poses.
- Compare every returned figure with the recorded size-reference measurements
  and verify it remains inside the shared safe subject box before proving the
  table's centered 12:13 crop. A prompted canvas or apparently equal row is not
  acceptance evidence.
- For jumps, apply `CRITICAL SCALE LOCK` and forbid floor, contact, cast, and
  oval shadows.
- For walk cycles, change scripted joint coordinates when poses repeat; do not
  keep extending the prompt.
