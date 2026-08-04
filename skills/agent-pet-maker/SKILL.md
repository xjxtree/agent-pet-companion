---
name: agent-pet-maker
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
   384×416. Use `low` 192×208 when requested. Use `high` 576×624 only after the
   active source proves a complete 12:13 crop of at least that size for every
   frame. Built-in ChatGPT/Codex `imagegen` is qualified only for `low` and
   `standard`; route `high` to Dreamina 5.0 Pro or another source-capable
   provider. Never upscale, pad, combine batches to manufacture pixels, or
   silently downgrade.
3. For a new pet, use the creation defaults in `petpack-v3.md` unless the user
   specifies another valid complete timing. For a revision, preserve all
   authored timing and unchanged state files byte-for-byte unless the user asks
   to change them. A timing change requires a newly authored complete sequence
   for that state.
4. Lock one production base, then create one complete action per image call.
   Verify the returned frame count, order, identity, anatomy, action, spacing,
   crop capacity, and flat background before accepting it. Use a deterministic
   pose guide for complex limb motion as required by the visual contract.
5. Crop stable equal-size 12:13 source windows without resampling. Run every
   new or regenerated crop through the shared transparency script; package only
   its exact-tier runtime PNGs. Accept a state only when the report and every
   frame say `"ok": true` and the multi-background previews pass inspection.

   ```bash
   python3 <skill-dir>/scripts/prepare_transparent_frames.py \
     --jobs /absolute/workspace/transparent-frame-jobs.json \
     --report /absolute/workspace/transparency-report.json \
     --preview-dir /absolute/workspace/transparency-previews
   ```

6. Run `motion-qa --state <state>` immediately after each accepted state. After
   all actions, run combined Motion QA, inspect every authored-timing preview,
   the keyframe sheet, and the 8–12 second presence preview, then bind one
   concrete `motion-review` note to every audited state. Repair objective
   defects in the artwork; never retime frames to make QA pass.
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
