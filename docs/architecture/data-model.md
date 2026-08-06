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
├── logs/
└── diagnostic-exports/
```

Path authority lives in [paths.rs](../../crates/petcore/src/paths.rs) and the App runtime/diagnostics stores.

## SQLite

The current schema is version 6. PetCore enables WAL, foreign keys, secure deletion, and integrity checks; it rejects a database newer than the running runtime. Candidate replacement uses a private digest-bound rollback checkpoint. Only a complete `ready` checkpoint for the exact source/candidate pair can restore data, and a restored checkpoint cannot be replayed.

| Table | Purpose and invariant |
|---|---|
| `pets` | Manifest-ID identity, display metadata, V3 render/timing contract, owned paths, provenance, one active pet |
| `retired_pet_records` | Rollback-compatible quarantine for unsupported pre-V3 or invalid stored pet rows; assets are preserved, never aliased |
| `generation_jobs` | Private form, status, workspace/session identity, result/retry ownership; at most one active job |
| `generation_messages` | Ordered per-job progress/conversation records with terminal monotonicity |
| `generation_message_migrations` | Idempotent legacy-message import marker |
| `agent_events` | Deduplicated `apc.agent-event.v1` envelopes with bounded typed payloads |
| `agent_event_daily_counts` | Content-free aggregates for pruned events |
| `suppressed_agent_sessions` | Bounded source/session suppression records |
| `agent_session_aliases` | Stable, content-free aliases for retained anonymous sessions |
| `privacy_migrations` | Recoverable privacy-scrub state, not product history |
| `pet_asset_validation` | Cached package/runtime-asset validation result; explicit repair bypasses it |
| `settings` | Versioned behavior, onboarding, placement/intent, completion acknowledgement, and connector state |
| `product_convergence_receipt` | Exact-build typed four-Agent convergence receipt |
| `state_revision` | Monotonic revision advanced by durable state mutations |

The exact schema and migrations are in [db.rs](../../crates/petcore/src/db.rs); do not duplicate SQL in prose.

## Settings and first run

`onboarding_progress` uses `apc.onboarding-progress.v1` with `choose_pet`, `connect_agents`, `demo`, `completed`, and `skipped`. Missing data means `choose_pet` at revision `0`. Updates are compare-and-swap, move only forward or explicitly skip, and make `completed`/`skipped` terminal. Completion and enabling the pet commit together. Demo phases are App-local and never enter events or diagnostics.

`behavior` owns language, appearance, source/event enablement, timeouts, attention settings, bubble text scale, and `group_sessions_by_agent`. Agent-group disclosure defaults come from the setting; flat-tray disclosure, card slots, hover, and scrolling remain App-local.

`overlay_placement` stores the hard-clamped absolute center, display identity, and logical `display_width_pt` (80–224, default 112). Coordinates canonicalize to a shared 1/256 pt grid. A placement-specific decimal revision provides compare-and-swap authority. `overlay_placement_intent` carries only explicit reset/reposition instructions and clears atomically when the App acknowledges them. App-side drag revisions and retry journals are presentation state, not a second durable placement model.

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

Runtime assets are derived from the immutable package. `pet.assets.repair` forces package, cover, and all nine action directories through fresh staged validation and atomically replaces the derived assets.

## Generation

`GenerationForm` contains description, style, `low` or `standard` quality, and bounded copied references. Authored frame timing is package output, not an App form setting. Portable imported packages may be `high`; the Codex-backed in-App Studio rejects `high` before generation.

Jobs are `pending`, `running`, `waiting_for_user`, `failed`, `completed`, or `canceled`. SQLite is the message authority. Private job directories may contain source rows, copied references, deterministic guides, transparent masters, runtime frames, QA previews/reports, App Server state, and an optional validated edit baseline. These artifacts never enter the package or library projection unless the closed V3 builder explicitly includes them.

An edit context pins the selected immutable baseline and the active-head digest confirmed by the user. Commit fails if the active head changes. Timing or playback edits are authored state changes and require a complete fresh sequence plus fresh production evidence; sampling, padding, duplicating, retiming, or interpolation is rejected.

The [V3 specification](../specifications/AgentPetCompanion_Petpack_Whitepaper_V3.md) owns package and production requirements.

## Agent events and session projection

Supported sources are `codex`, `claude_code`, `pi`, and `opencode`. Persisted events are `start`, `thinking`, `plan`, `tool`, `waiting`, `done`, and `failed`. The event title is canonical audit data; localized UI labels and pet-action mapping are separate.

`apc.agent-event.v1` accepts only bounded fields needed for identity, ordering, navigation, and display. Session title, first/latest user message, current-turn Agent message, and selected scalar activity detail are distinct fields. Activity normalization may retain bounded reasoning, commands, tool input/output, and errors, but never stringifies arbitrary host objects or exports credential-shaped containers, headers, complete environments, or transcripts. String ceilings are enforced as UTF-8 bytes by both schema and PetCore.

`state.snapshot` exposes opaque domain-separated identities, bounded session fields, closed summary kind, animation identity, completion acknowledgement identity, and validated navigation capability. Only a routable Codex App UUID may cross separately for exact ChatGPT/Codex navigation. Unknown or mismatched targets fail closed.

Ordinary `start`, `thinking`, `plan`, `tool`, and `done` activity uses bounded leases; `waiting` and `failed` persist until a newer session event resolves them. At most eight concrete sessions are projected, with an omitted count for the remainder. A completion is hidden only after its declared destination opens and PetCore accepts the opaque acknowledgement. Repeated terminal tails in the same activity epoch remain aliases of that acknowledgement; a genuine later activation is new work.

Group disclosure, flat-list stable slots, manual bubble hiding, and transient navigation errors are App presentation state. The [connector contract](../integrations/agent-connectors.md) owns host-specific mapping and routing.

## Versioned contracts

| Contract | Identity | Authority |
|---|---|---|
| Runtime set | `apc.runtime-manifest.v1` | Rust/Swift runtime manifests |
| PetCore RPC | `apc.petcore-rpc.v2` | Rust server and Swift client |
| SQLite | schema `6` | `db.rs` |
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
- `events.recent`: at most 200 rows; snapshots use smaller bounded projections.
- Package and diagnostic limits are owned by the [V3 specification](../specifications/AgentPetCompanion_Petpack_Whitepaper_V3.md) and [Runtime and IPC](runtime-and-ipc.md).

For a data-model change, update storage/types first, then migration and compatibility boundaries, schemas, Swift projection, fixtures, tests, and this current-state summary.
