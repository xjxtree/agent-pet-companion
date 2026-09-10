---
name: agent-pet-maker
version: 0.5.10
description: Create or revise portable Agent Pet Companion .petpack V3 pets at low, standard, or high resolution from text and optional reference images. Use for new pets, exported-package revisions, action or timing edits, provider-aware image production, motion QA, packaging, or an explicitly requested install.
---

# Agent Pet Maker

Produce one coherent nine-action pet and a validated `.petpack`. Use real image
generation or editing for new visuals, preserve identity across actions, and
record the actual producer. Never present a preview, fixture, or copied artwork
as generated production art.

## Load the applicable contracts

- Always read [petpack-v3.md](references/petpack-v3.md) and
  [security.md](references/security.md).
- Read [create-modify.md](references/create-modify.md) for the selected
  operation and all helper commands.
- When creating or regenerating visuals, read
  [visual-production-and-native-resolution.md](references/visual-production-and-native-resolution.md)
  and
  [transparent-frame-production.md](references/transparent-frame-production.md).
- When using Dreamina for `high`, also read
  [dreamina-high-production.md](references/dreamina-high-production.md).

Resolve every path relative to this skill directory.

## Preflight

Run the helper before creating a workspace:

```bash
python3 <skill-dir>/scripts/petpack_workspace.py preflight
```

Use a real Python runtime with Pillow PNG and animated WebP support. Do not
replace Pillow, either bundled script, or PetCore with a compatibility shim. If
image generation, required image inspection, Pillow, or PetCore is unavailable,
stop and write an honest result:

```bash
python3 <skill-dir>/scripts/petpack_workspace.py capability-missing \
  --operation create \
  --capability image-generation \
  --result /absolute/output/result.json
```

## Produce the package

1. Prepare an absent or empty workspace. For a revision, provide the exported
   V3 archive as `--input`; never edit an installed package directory.

   ```bash
   python3 <skill-dir>/scripts/petpack_workspace.py prepare \
     --operation create \
     --workspace /absolute/workspace
   ```

2. Select one render tier for the whole package. Default to `standard`
   384×416. Use `low` 192×208 when requested. Use `high` 576×624 with a qualified
   producer. Built-in ChatGPT/Codex `imagegen` is qualified only for `low` and
   `standard`; route `high` to Dreamina 5.0 Pro or another source-capable
   provider. Never silently downgrade or claim that enlargement creates detail.
3. For a new pet, use the creation defaults in `petpack-v3.md` unless the user
   specifies another valid complete timing. For a revision, preserve all
   authored timing and unchanged state files byte-for-byte unless the user asks
   to change them. A timing change requires a newly authored complete sequence
   for that state.
4. For built-in Codex `imagegen`, request native transparent RGBA first for the
   base and each action. Follow the shared retry protocol: before chroma
   fallback, execute at least 3 native attempts for the same base/action and
   adjust the prompt to each observed failure. Stop early on an accepted native
   result; record actual calls and failures outside the package. Other providers
   keep flat chroma. Lock one production base, then create one complete action per image call.
   For every multi-frame action, create a deterministic pose guide and a
   separate deterministic size-reference image from the same slot, crop, and
   `global_scale` record. Pass the character base, pose guide, and size
   reference in that order; `high` production may not rely on text-only equal-
   scale control. Verify the returned frame count, order, identity, anatomy,
   action, spacing, subject scale, crop capacity, and the selected Alpha/background contract before
   accepting it. AI output need not match the requested position, scale, aspect
   ratio, or resolution exactly. Prefer reusing complete, clear artwork:
   proportionally scale, translate, crop empty surroundings, and add transparent
   canvas as needed. Per-frame corrections may remove model drift while
   preserving intended movement and consistent anatomy, head size, and costume.
   Judge the final runtime sequence; regenerate defects that reasonable
   processing cannot resolve without visible quality loss.
5. Extract complete source poses without resampling. Run every
   new or regenerated crop through the shared transparency script; package only
   its exact-tier runtime PNGs. Accept a state only when the report and every
   frame say `"ok": true` and the multi-background previews pass inspection.
   Use automatic fit or explicit `placement` scale/offsets. Rerender from
   retained originals, record adjustments, and inspect detail after enlargement.
   Set `source_mode` explicitly. Native Alpha receives no matte, RGB edge
   repair, contraction, or feathering. In flat-chroma mode, the script performs
   its closed runtime-size RGB edge repair automatically;
   an isolated low-Alpha fringe warning still requires preview review but is
   not a reason to search nearby crop, key-color, or feather values.

   ```bash
   python3 <skill-dir>/scripts/prepare_transparent_frames.py \
     --jobs /absolute/workspace/transparent-frame-jobs.json \
     --report /absolute/workspace/transparency-report.json \
     --preview-dir /absolute/workspace/transparency-previews
   ```

   For native failures, follow the shared generation retry protocol. For a hard
   flat-chroma transparency failure, rerun only the failing frames. Start from
   the recorded source crop and automatic key color. Permit at most
   one `--edge-contract 1` retry, then add `--edge-feather 0.25` only when the
   contracted preview visibly stair-steps. Change the shared crop only for a
   complete-pose framing or placement correction, and use an explicit key only when automatic key
   sampling or a real subject-color conflict is visibly wrong. Never enumerate
   adjacent crops, similar key colors, or feather values. If this bounded path
   still fails, regenerate the opaque source with a flatter, more contrasting
   background; if the same source defect recurs, change the production prompt
   or action design instead of extending the search.

6. Run `motion-qa --state <state>` immediately after each accepted state. After
   every run, compare its per-frame body-anchor and baseline path with the
   action card and deterministic pose guide. Preserve intentional travel and
   authored easing. If the path is inconsistent but identity, anatomy, pose,
   scale, props, Alpha, and crop are otherwise accepted, do not regenerate
   first: author a QA-digest-bound `motion-align` plan, apply integer-only
   whole-frame translation to the transparent PNGs, inspect the result, copy
   only approved frames back, and rerun Motion QA. After all actions, run
   combined `motion-qa --workspace /absolute/workspace` without `--state`; it
   derives revised actions from the saved baseline and binds retained generation
   evidence. Use `generation_evidence.py check/record` after each actual call as
   defined in the shared transparency contract. Inspect every authored-timing preview, the keyframe
   sheet, and the 8–12 second presence preview, then bind one concrete
   `motion-review` note to every audited state. Repair objective defects in the
   artwork; never retime frames to make QA pass.
7. Finalize through the helper. It derives changed states, runs the shared
   production gate, validates the source and staged archive, and publishes the
   result atomically.

   ```bash
   python3 <skill-dir>/scripts/petpack_workspace.py finalize \
     --operation create \
     --workspace /absolute/workspace \
     --output /absolute/output/pet.petpack
   ```

For a revision, use `--operation modify` and repeat `--changed-state` for every
requested state. The helper rejects missing, extra, or stale change evidence.

## Install only when requested

Finalization never imports, activates, or enables a pet. If the user explicitly
requests installation, run:

```bash
python3 <skill-dir>/scripts/petpack_workspace.py install \
  --input /absolute/output/pet.petpack
```

Add `--activate` only when requested. Use `--allow-existing-id-revision` only
for an intentional same-ID revision.
