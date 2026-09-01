# Data Model

PetCore Rust types, SQLite migrations, runtime manifests, and JSON Schemas are authoritative. Swift models are bounded App projections and intentionally decode only what the UI needs. Persisted server values win over client defaults.

## Storage

The default root is `~/Library/Application Support/AgentPetCompanion`; tests and explicit maintenance may override it with `APC_HOME`. Private directories use restrictive permissions.

```text
AgentPetCompanion/
├── agent-pet.sqlite
├── run/                       locks, socket, runtime identity, local ingress token
├── runtime/
│   ├── versions/<build-id>/   PetCore, CLI, manifest, interaction attestation
│   ├── rollback-checkpoint/
│   ├── current -> versions/<build-id>
│   └── last-known-good.json
├── pets/<pet-id>/revisions/<revision-id>/
├── generation-jobs/<job-id>/
├── connectors/
├── managed-skills/             App-private portable-Skill ownership receipts
├── logs/
└── diagnostic-exports/
```

Path authority lives in [paths.rs](../../crates/petcore/src/paths.rs) and the App runtime/diagnostics stores.

## SQLite

The current schema is version 7. PetCore enables WAL, foreign keys, secure deletion, and integrity checks; it rejects a database newer than the running runtime. Candidate replacement uses a private digest-bound rollback checkpoint. Only a complete `ready` checkpoint for the exact source/candidate pair can restore data, and a restored checkpoint cannot be replayed.

| Table | Purpose and invariant |
|---|---|
| `pets` | Manifest-ID identity, display metadata, V3 render/timing contract, owned paths, provenance, one active pet |
| `retired_pet_records` | Rollback-compatible quarantine for unsupported pre-V3 or invalid stored pet rows; assets are preserved, never aliased |
| `generation_jobs` | Private form, status, workspace/session identity, result/retry ownership; at most one active job; terminal rows may be explicitly deleted |
| `generation_messages` | Ordered per-job progress/conversation records with explicit terminal and in-place continuation boundaries |
| `generation_message_migrations` | Idempotent legacy-message import marker |
| `agent_events` | Deduplicated `apc.agent-event.v1` envelopes with bounded typed payloads |
| `agent_event_daily_counts` | Content-free aggregates for pruned events |
| `suppressed_agent_sessions` | Bounded source/session suppression records |
| `agent_session_aliases` | Stable, content-free aliases for retained anonymous sessions |
| `privacy_migrations` | Recoverable privacy-scrub state, not product history |
| `pet_asset_validation` | Cached package/runtime-asset validation result; explicit repair bypasses it |
| `settings` | Versioned behavior, onboarding, placement/intent, completion acknowledgement, and connector state |
| `product_convergence_receipt` | Exact-build typed five-Agent convergence receipt |
| `state_revision` | Monotonic revision advanced by durable state mutations |

The exact schema and ordered migrations are in [storage/migrations.rs](../../crates/petcore/src/storage/migrations.rs). [storage/mod.rs](../../crates/petcore/src/storage/mod.rs) retains the single `Database`, connection policy, busy retry, and shared transaction helpers; settings, connection, Agent/event, generation, and pet queries are crate-private domain modules. Do not duplicate SQL in prose or introduce App/CLI SQLite access.

## Settings and first run

`onboarding_progress` uses `apc.onboarding-progress.v1` with `choose_pet`, `connect_agents`, `demo`, `completed`, and `skipped`. Missing data means `choose_pet` at revision `0`. Updates are compare-and-swap, move only forward or explicitly skip, and make `completed`/`skipped` terminal. Completion and enabling the pet commit together. Demo phases are App-local and never enter events or diagnostics.

`behavior` owns language, appearance, source/event enablement, timeouts, attention settings, bubble text scale, and `group_sessions_by_agent`. New state defaults `group_sessions_by_agent` to `false`, producing the cross-Agent flat tray; an explicit stored choice remains authoritative. Agent-group disclosure defaults come from the setting; flat-tray disclosure, card slots, hover, and scrolling remain App-local. Transparent-area pointer passthrough is an App invariant, not a behavior preference. The legacy `mouse_passthrough` field remains serialized as `true` for mixed-version compatibility; persisted `false` values canonicalize to `true`, and new patches to that field are rejected.

`overlay_placement` stores the hard-clamped absolute center, display identity, and logical `display_width_pt` (100–300, default 112). Coordinates canonicalize to a shared 1/256 pt grid. A placement-specific decimal revision provides compare-and-swap authority. During upgrade, values from the previous 80–224 contract below the current minimum are normalized once to 100; all other malformed or out-of-contract values remain rejected. `overlay_placement_intent` carries only explicit reset/reposition instructions and clears atomically when the App acknowledges them. App-side drag revisions and retry journals are presentation state, not a second durable placement model.

## Pet identity and revisions

Pet identity is `PetManifest.id` (`pet_[a-z0-9]+`); display names are not unique. Mutations publish immutable revisions under one pet-store lock:

```text
pets/<pet-id>/
├── active.json
└── revisions/<revision-id>/
    ├── <pet-id>.petpack
    ├── <pet-id>-cover.png
    └── <pet-id>-frames/
```

Validation and runtime-frame preparation occur in private staging. Publication syncs files, rechecks identity policy, renames the immutable revision, atomically replaces `active.json`, then commits SQLite. A database failure restores the previous pointer and removes only the candidate.

`pet.list` and `state.snapshot` expose validated V3 action/timing data plus derived current revision metadata. `pet.history` revalidates a bounded set of owned revisions and projects only safe edit-baseline/job summary fields. It never exposes forms, prompts, messages, provider sessions, or private paths.

Bundled authority requires both a fixed manifest ID and PetCore-assigned origin/provenance. An ordinary same-ID pet is preserved and never gains bundled authority. A changed trusted bundled resource appends a revision without deleting history or changing the selected pet. Bundled pets remain read-only.

Runtime assets are derived from the immutable package. Cached asset fingerprints include the current validator-contract domain, so a stricter media gate revalidates unchanged installed packages without a database migration. `pet.assets.repair` forces package, cover, and all nine action directories through fresh staged validation and atomically replaces the derived assets.

## Generation

`GenerationForm` contains description, style, `low` or `standard` quality, and bounded copied PNG, JPG/JPEG, or WebP references. Extension, decoded format, byte count, pixel count, ownership, and no-follow snapshot identity are validated before use. Authored frame timing is package output, not an App form setting. Portable imported packages may be `high`; the Codex-backed in-App Studio rejects `high` before generation.

Jobs retain the compatible `pending`, `running`, `waiting_for_user`, `failed`, `completed`, and `canceled` storage enum. `recoverable`, `failure_code`, `pause_reason`, and cancellation timestamps project the finer paused, recoverable-failed, and cancellation-cleanup UI states. `started_at` is fixed at job creation. `ended_at` is set only for completion, terminal failure, or the user's `cancel_requested_at`; therefore waiting, sleep gaps, and recoverable failures continue to accrue duration while cancellation freezes it immediately. `execution_stopped_at` proves worker ownership ended, while `thread_archived_at` proves the exact cancellation archive boundary completed. PetCore may subsequently keep or restore that stopped thread as unarchived for terminal transcript viewing; route availability is always revalidated live rather than inferred from the timestamp. `active_turn_id`, `last_checkpoint_at`, and `visible_title` support exact control, recovery, and stable list presentation.

A partial unique index admits only one unfinished job: pending, running, waiting, recoverable failed, or any row with cancellation requested but thread archival incomplete. Every create, edit, and new-job retry also checks the same rule inside its transaction and returns `generation_active_conflict` with the occupying job ID/status. SQLite is the message authority and retains every job, including terminal jobs without a result pet, until explicit terminal deletion. `generation.history.list` puts the unfinished row first, then terminal rows newest-first, and returns bounded metadata plus PetCore-authoritative capabilities without reference paths, workspaces, messages, or raw provider identities.

`generation.history.delete` is irreversible and accepts only `completed`, `failed`, or `canceled` jobs. It removes the job row, cascading message and message-migration rows, and the descriptor-bound private `generation-jobs/<job-id>` workspace; pending, running, and waiting jobs fail with a conflict. A completed job's immutable Pet Library pet and revisions remain installed. The provider-owned Codex/ChatGPT thread is not archived or deleted by this local history operation; removing the local job also removes PetCore's route back to that thread. To prevent dangling local history, direct retry children are atomically relinked to the deleted job's own still-retained retry predecessor; if that predecessor is absent, self-referential, or the deleted job was a retry root, their `retry_of_job_id` is cleared. Relinking does not change child timestamps or history ordering. Workspace removal validates the exact owned jobs root and job directory with no-follow descriptor identity, removes symlinks as entries rather than traversing them, and never derives a deletion target from the stored path alone.

`generation_messages` stores a strict per-job sequence of user text, visible Agent text, phase/activity/checkpoint summaries, structured `input_request` payloads, recoverable or terminal errors, results, and cancellation. Input payloads contain only bounded request/question/option fields. Periodic liveness coalesces into `generation_jobs.heartbeat_at` and the wait revision instead of growing the table. `generation.messages.list` pages backward by sequence while returning each page in chronological order. `generation_action_requests` binds reply/resume request IDs to action and content digest so transport retries cannot start duplicate turns.

Only waiting accepts `generation.reply`; only a recoverable failure accepts `generation.resume`. Both persist the user text first and continue the same job/workspace and available thread. A completed task is closed and changes use a new edit task. A canceled task has an irreversible write fence and no reply, resume, or retry capability. Pending, running, waiting, recoverable-failed, and cancellation-cleanup jobs never expose ChatGPT navigation; completed, canceled, and terminal-failed jobs may expose it only when App Server confirms the exact unarchived thread in the exact job workspace. Terminal failed tasks may create a distinct retry job linked by `retry_of_job_id`.

The App may render this job-scoped conversation directly, but heartbeat/activity records are separate from Agent conversation bubbles and the entire Maker stream is excluded from ordinary Agent session projection and diagnostics; the thread/job identity is persisted before the first Studio turn so concurrent Codex hooks are suppressed, and startup removes legacy Studio bubble rows. Tool payloads, hidden reasoning, credentials, and arbitrary App Server objects are not copied into the Maker projection. Private job directories may contain native-Alpha or chroma source rows with their selected source-mode report, copied references, deterministic guides, transparent masters, runtime frames, QA previews/reports, App Server state, and an optional validated edit baseline. Selected built-in image outputs are copied into that private workspace; Codex cache paths never enter package metadata. These artifacts never enter the package or library projection unless the closed V3 builder explicitly includes them.

An edit context pins the selected immutable baseline and the active-head digest confirmed by the user. Commit fails if the active head changes. Timing or playback edits are authored state changes and require a complete fresh sequence plus fresh production evidence; sampling, padding, duplicating, retiming, or interpolation is rejected.

The [V3 specification](../specifications/AgentPetCompanion_Petpack_Whitepaper_V3.md) owns package and production requirements.

## Agent events and session projection

Supported sources are `codex`, `claude_code`, `pi`, `opencode`, and `dsh`. Persisted events are `start`, `thinking`, `plan`, `tool`, `waiting`, `done`, and `failed`. The event title is canonical audit data; localized UI labels and pet-action mapping are separate.

`apc.agent-event.v1` accepts only bounded fields needed for identity, ordering, navigation, and display. Session title, first/latest user message, Agent message, and selected scalar activity detail are distinct stored fields. The bubble-body projection chooses the newest Agent message or explicit thinking/plan content and retains it across user, tool, and lifecycle events; those other events continue to own context, semantic state, and the status indicator but never replace body copy. Activity normalization may retain bounded reasoning, commands, tool input/output, and errors, but never stringifies arbitrary host objects or exports credential-shaped containers, headers, complete environments, or transcripts. String ceilings are enforced as UTF-8 bytes by both schema and PetCore.

`state.snapshot` exposes opaque domain-separated identities, bounded session fields, closed summary kind, animation identity, completion acknowledgement identity, and validated navigation capability. Only a routable Codex App UUID may cross separately for exact ChatGPT/Codex navigation. Unknown or mismatched targets fail closed.

Ordinary `start`, `thinking`, `plan`, `tool`, and `done` activity uses bounded leases; `waiting` and `failed` persist until a newer session event resolves them. At most eight concrete sessions are projected, with an omitted count for the remainder. A completion is hidden only after its declared destination opens and PetCore accepts the opaque acknowledgement. Repeated terminal tails in the same activity epoch remain aliases of that acknowledgement; a genuine later activation is new work.

Group disclosure, flat-list stable slots, manual bubble hiding, and transient navigation errors are App presentation state. The [connector contract](../integrations/agent-connectors.md) owns host-specific mapping and routing.

## Versioned contracts

| Contract | Identity | Authority |
|---|---|---|
| Runtime set | `apc.runtime-manifest.v1` | Rust/Swift runtime manifests |
| PetCore RPC | `apc.petcore-rpc.v2` | Rust server and Swift client |
| SQLite | schema `7` | `storage/migrations.rs` |
| Product convergence | `apc.product-convergence-receipt.v1` | database and RPC |
| Onboarding | `apc.onboarding-progress.v1` | Rust type and Swift mirror |
| Agent event | `apc.agent-event.v1` | event envelope and schema |
| Portable pet | `apc.petpack.v3` | shared type, schema, specification |
| Active revision | `apc.pet-active-revision.v1` | pet revision service |
| Diagnostics | `apc.diagnostic-log.v1`, `apc.diagnostics-bundle.v1` | App/PetCore diagnostics |

Do not change an identity without an explicit compatibility or migration design. Update Rust authority, Swift mirror, schema, fixtures, manifest, and tests together.

## Retention

- Agent events: at most 10,000 rows and 30 days by default; removed content contributes only to daily counts.
- Suppressed sessions: at most 10,000 entries and 30 days.
- Anonymous aliases exist only while their session retains an event and are never reused.
- Maker tasks persist until an explicit terminal-only delete; deleting a task retains its published Pet Library result and safely repairs retained retry links.
- `events.recent`: at most 200 rows; snapshots use smaller bounded projections.
- Package and diagnostic limits are owned by the [V3 specification](../specifications/AgentPetCompanion_Petpack_Whitepaper_V3.md) and [Runtime and IPC](runtime-and-ipc.md).

For a data-model change, update storage/types first, then migration and compatibility boundaries, schemas, Swift projection, fixtures, tests, and this current-state summary.
