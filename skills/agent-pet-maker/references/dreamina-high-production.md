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

Generate each action with image-to-image at 4K and height 1536. Pass the
production base first and, for a complex action, the deterministic pose guide
second. Do not combine `--ratio` with custom width and height.

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
  --images /absolute/character-base.png,/absolute/pose-guide.png \
  --prompt="<one action, ordered poses, shared reference-responsibility block>" \
  --model_version=5.0Pro \
  --resolution_type=4k \
  --width=6240 \
  --height=1536 \
  --generate_num=1 \
  --poll=60
```

For a simple action, omit the pose-guide path but keep the base as image 1.
Substitute the table width for the authored frame count. Do not approximate an
unsupported count by adding or removing generated figures.

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
  pixel, mannequin, grid, label, or separator.
- Lock camera distance, head size, shoulder width, full-body scale, outfit, and
  materials across all poses.
- For jumps, apply `CRITICAL SCALE LOCK` and forbid floor, contact, cast, and
  oval shadows.
- For walk cycles, change scripted joint coordinates when poses repeat; do not
  keep extending the prompt.
