# Project Audit Remediation Implementation Plan

> **Historical plan / 历史计划：** This plan belongs to the 2026-07-10 audit and is preserved as execution history. The current roadmap, open gates and release blockers are maintained in [current project status](../../PROJECT_STATUS.md) and the active implementation plan.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every item in `docs/audits/2026-07-10-project-review/REPORT.md` and leave a reproducible, secure, recoverable V1 implementation with fresh automated and real-UI verification.

**Architecture:** PetCore becomes the single authoritative writer for pets, jobs, settings and agent events. Filesystem changes use staged revisions and recoverable commit records; external payloads are reduced to a strict event envelope before persistence. The macOS app consumes resumable snapshots through a bounded asynchronous transport, while the overlay keeps disk/decode work off the main/render path. Agent adapters are versioned against official event fixtures, and host-mutating/real-agent validation is opt-in.

**Tech Stack:** Rust 2021, rusqlite, serde/JSON Schema, Unix domain sockets, Swift 6, SwiftUI, AppKit/NSPanel, Metal/MetalKit, XCTest, shell validation, Codex App Server JSONL.

## Global Constraints

- V1 navigation remains exactly Pet Studio, Enable & Behavior, Agent Connections.
- Pet Studio retains exactly New and Pet Library tabs.
- The app-owned package format remains `.petpack`; do not add Petdex/Codex asset compatibility, galleries, sharing, cloud accounts, Windows UI or mission control.
- Canonical states remain `idle`, `start`, `tool`, `waiting`, `review`, `done`, `failed`.
- Standard animation is exactly 12 FPS and smooth animation is exactly 20 FPS.
- Display size remains an overlay interaction through the bottom-right handle; do not add a settings size field.
- Runtime frame assets remain transparent PNG sequences; only one pet is active.
- The loopback HTTP listener remains `127.0.0.1` with a 0600 capability token; UDS remains 0600.
- Never read Agent auth, token, cookie, API-key or secret files; persist only an allowlisted status envelope.
- Preserve the user's pre-existing dirty worktree. Do not stage, commit, reset, discard or rewrite unrelated changes.
- Every production behavior change starts with a focused failing regression test or validation fixture and ends with fresh focused plus workspace verification.

---

## File and Interface Map

- `crates/petcore/src/db.rs`: schema migrations, atomic DB operations, event retention, monotonic revision.
- `crates/petcore/src/daemon.rs`: singleton acquisition, bounded UDS/HTTP servers, capability and runtime markers.
- `crates/petcore/src/event_envelope.rs` (new): payload-independent event normalization, redaction and namespaced identity.
- `crates/petcore/src/process_runner.rs` (new): bounded external command execution and process-group cancellation.
- `crates/petcore/src/petpack.rs`: staged package validation, image/zip budgets and revision commit protocol.
- `crates/petcore/src/generation.rs`: recoverable job state, message framing and cancellation.
- `crates/petcore/src/app_server.rs`: App Server transport and real-source completion gate.
- `crates/petcore/src/connections.rs`: official adapters, structural install/uninstall and capability checks.
- `crates/petcore/src/rpc.rs`: strict private RPC envelope, snapshots and limits.
- `crates/petcore-types/src/lib.rs`: shared strict DTOs and manifest rules.
- `apps/macos/Sources/AgentPetCompanionCore/`: asynchronous client, DTOs and pure testable state reducers.
- `apps/macos/Sources/AgentPetCompanion/App/`: service/job lifecycle and serialized mutations.
- `apps/macos/Sources/AgentPetCompanion/Overlay/`: geometry, keyboard accessibility and background frame pipeline.
- `apps/macos/Sources/AgentPetCompanion/Views/`: semantic colors, accessibility, truthful resource/connection status and localization.
- `apps/macos/Tests/`: XCTest coverage for pure model, transport, geometry and reducer behavior.
- `schemas/` and `fixtures/contracts/` (new): executable schemas and official Agent payload fixtures.
- `script/`, `.github/workflows/`, `rust-toolchain.toml`, `CONTRIBUTING.md`: isolated validation and reproducible delivery.

### Task 1: Strict Agent Event Envelope, Privacy and Idempotency

**Audit coverage:** APC-P1-004, APC-P1-005, APC-P2-008, APC-P2-012, APC-P3-002; optimization items 3, 4, 8 and 11.

**Files:**
- Create: `crates/petcore/src/event_envelope.rs`
- Create: `crates/petcore/tests/event_envelope_security.rs`
- Modify: `crates/petcore/src/lib.rs`
- Modify: `crates/petcore/src/db.rs`
- Modify: `crates/petcore/src/rpc.rs`
- Modify: `crates/petcore-cli/src/main.rs`
- Modify: `schemas/agent-event.schema.json`

**Interfaces:**
- Produces: `NormalizedAgentEvent::from_external(source, value, received_at) -> Result<AgentEvent>`.
- Produces: `Database::insert_event(&AgentEvent) -> Result<InsertEventOutcome>` with a unique `(source, session_id, external_event_id)` key.
- Produces: `Database::prune_events(EventRetentionPolicy) -> Result<usize>` and `Database::state_revision() -> Result<u64>`.
- Persisted `payload_json` contains only schema version, external id, source event name, tool name, outcome and diagnostic flag; it never contains prompt, args, command, output, transcript path, environment or arbitrary nested input.

- [x] **Step 1: Add failing privacy, identity, retention and revision tests**

  Add tests named `external_payload_is_reduced_to_allowlisted_envelope`, `same_external_id_from_two_sources_is_not_deduplicated`, `same_id_in_two_sessions_is_not_deduplicated`, `recent_events_clamps_limit`, `event_retention_prunes_oldest_rows`, and `state_revision_changes_for_every_client_visible_pet_field`. Fixtures must include nested `prompt`, `tool_input`, `tool_response`, `command`, `env.API_KEY` and `transcript_path`, then assert none of those values appears in the serialized database row.

- [x] **Step 2: Run the focused tests and verify RED**

  Run: `cargo test -p petcore --test event_envelope_security -- --nocapture`
  Expected: FAIL because `event_envelope`/migration/retention APIs do not exist and current rows retain arbitrary payloads.

- [x] **Step 3: Implement the strict envelope and migration**

  Use these stable shapes:

  ```rust
  pub const MAX_EVENT_TITLE_BYTES: usize = 160;
  pub const MAX_EVENT_DETAIL_BYTES: usize = 512;
  pub const MAX_RECENT_EVENTS: usize = 200;

  pub struct EventRetentionPolicy {
      pub max_rows: u64,
      pub max_age_days: u32,
  }

  pub enum InsertEventOutcome { Inserted, Duplicate }
  ```

  Migrate with `PRAGMA user_version` to an internal primary key and a unique namespaced external identity. Existing arbitrary `payload_json` values must be replaced by a minimal legacy envelope, followed by WAL checkpoint/table rebuild/`VACUUM` on the app-owned database to minimize retained plaintext. Clamp recent limits to `0...200` (`0` returns no rows); default retention is 10,000 rows and 30 days, with daily source/type counts retained before raw-row pruning. Store a numeric state revision in a single-row table and increment it through write triggers/transactions instead of deriving an incomplete string.

- [x] **Step 4: Run focused tests and schema validation**

  Run: `cargo test -p petcore --test event_envelope_security -- --nocapture`
  Expected: PASS and no sensitive fixture value in failure output or database.

- [x] **Step 5: Run existing event/security regressions**

  Run: `cargo test -p petcore --test daemon_http_security --test core_validation agent -- --nocapture`
  Expected: PASS with namespaced idempotency and bounded payload behavior.

### Task 2: Daemon Singleton, Bounded Local Transports and Runtime Markers

**Audit coverage:** APC-P1-003, APC-P2-001, APC-P2-011, APC-P3-001, APC-P3-003; optimization items 1, 6 and 9.

**Files:**
- Create: `crates/petcore/src/instance_lock.rs`
- Create: `crates/petcore/tests/daemon_lifecycle.rs`
- Modify: `crates/petcore/src/daemon.rs`
- Modify: `crates/petcore/src/paths.rs`
- Modify: `crates/petcore/src/rpc.rs`
- Modify: `crates/petcore/src/main.rs`

**Interfaces:**
- Produces: `InstanceGuard::acquire(&AppPaths) -> Result<InstanceGuard>` before `CoreState::ensure_ready()` or job recovery.
- Produces: `RuntimeMarker { schema_version, pid, process_start, instance_id, http_port }`, written atomically and removed only by its owning guard.
- UDS accepts a maximum 256 KiB JSON frame, five-second read/write deadline and 32 concurrent clients. Its documented protocol is complete JSON-RPC 2.0 for single requests, notifications and non-empty batches.

- [x] **Step 1: Add failing lifecycle and transport tests**

  Add `second_daemon_does_not_recover_first_daemon_jobs`, `uds_rejects_request_larger_than_256k`, `uds_times_out_partial_line`, `uds_concurrency_is_bounded`, `rpc_rejects_missing_or_wrong_version`, `rpc_notification_has_no_response`, `rpc_batch_returns_only_request_responses`, `rpc_uses_standard_error_codes`, `stale_marker_is_replaced_atomically`, `old_instance_cannot_delete_new_marker`, and `capability_token_is_created_mode_0600`.

- [x] **Step 2: Verify RED**

  Run: `cargo test -p petcore --test daemon_lifecycle -- --nocapture`
  Expected: FAIL on pre-lock recovery, unbounded `read_line`, stale plain port marker and post-create chmod.

- [x] **Step 3: Implement acquisition and bounds**

  Acquire an advisory lock file containing PID/start/id before DB initialization; if a healthy socket belongs to the marker, return `AlreadyRunning` without mutation. Create home/run directories as 0700 and the token with `OpenOptionsExt::mode(0o600)`. Replace per-connection unlimited threads with a fixed permit counter; use `take(262_145)` plus deadline and reject any frame over 262,144 bytes. Require `jsonrpc: "2.0"`; support notifications and non-empty batches; return `-32700`, `-32600`, `-32601`, `-32602`, `-32603` and bounded `-32000` business errors.

- [x] **Step 4: Verify GREEN and existing HTTP security**

  Run: `cargo test -p petcore --test daemon_lifecycle --test daemon_http_security -- --nocapture`
  Expected: PASS.

### Task 3: Atomic Pet Revisions and Bounded `.petpack` Validation

**Audit coverage:** APC-P1-001, APC-P2-002, APC-P2-003, APC-P2-004, APC-P2-005, APC-P2-009, APC-P2-010; optimization items 1, 2, 6 and 11.

**Files:**
- Create: `crates/petcore/src/pet_revision.rs`
- Create: `crates/petcore/tests/petpack_resource_limits.rs`
- Modify: `crates/petcore/src/petpack.rs`
- Modify: `crates/petcore/src/db.rs`
- Modify: `crates/petcore-cli/src/main.rs`
- Modify: `crates/petcore-types/src/lib.rs`
- Modify: `schemas/petpack.schema.json`

**Interfaces:**
- Produces: `PetRevisionTransaction::stage`, `validate`, `commit(&Database)`, `rollback`.
- Active assets live at `pets/<pet-id>/revisions/<revision-id>/`; `pets/<pet-id>/active.json` is an atomically replaced pointer.
- Budgets: archive 1 GiB, expanded 4 GiB, maximum 40 frames per state/280 total, maximum 420 MiB decoded RGBA per state and 16,777,216 pixels per frame; references maximum 4 files, 20 MiB each, 40 MiB total and 16,000,000 pixels each.
- Supported source image extensions exactly match enabled decoders: PNG and WebP.

- [x] **Step 1: Add failing fault-injection and budget tests**

  Extend `petpack_import_atomic.rs` and add tests named `db_failure_keeps_previous_active_revision`, `concurrent_cli_import_cannot_bypass_daemon_writer`, `duplicate_flattened_frame_path_is_rejected`, `nested_frame_path_is_rejected`, `decoded_pixel_budget_is_enforced`, `decoded_state_budget_is_enforced`, `expanded_archive_budget_is_enforced`, `output_inside_source_is_rejected`, `manifest_rejects_unknown_and_empty_fields`, `reference_accept_list_matches_decoder_features`, `snapshot_uses_cached_validation_when_fingerprint_is_unchanged`, `snapshot_revalidates_after_fingerprint_change`, and `snapshot_exposes_repair_failure_without_retrying_unchanged_damage`.

- [x] **Step 2: Verify RED**

  Run: `cargo test -p petcore --test petpack_import_atomic --test petpack_resource_limits -- --nocapture`
  Expected: FAIL on current direct replacement/flattening/unbounded decode behavior.

- [x] **Step 3: Implement staged revisions and strict manifest validation**

  Stage into a sibling temporary revision, fsync validated metadata, commit the DB pet row and revision journal, then atomically replace `active.json`. On any error, remove only the uncommitted revision. Reject duplicate normalized paths before extraction and never flatten nested paths. Store a validation digest in DB so snapshot reads do not decode every frame; incremental repair failures become structured snapshot warnings.

- [x] **Step 4: Route CLI writes through daemon**

  `petpack import` first calls the daemon RPC. Offline mutation requires an explicit `--offline` flag and successful `InstanceGuard`; otherwise it fails without touching files.

- [x] **Step 5: Verify GREEN**

  Run: `cargo test -p petcore --test petpack_import_atomic --test petpack_resource_limits --test core_validation petpack -- --nocapture`
  Expected: PASS.

### Task 4: Recoverable Generation Jobs and Stable Message Log

**Audit coverage:** APC-P1-002, core half of APC-P1-009, APC-P3-002; optimization items 2 and 5.

**Files:**
- Create: `crates/petcore/tests/generation_recovery.rs`
- Modify: `crates/petcore/src/generation.rs`
- Modify: `crates/petcore/src/db.rs`
- Modify: `crates/petcore/src/rpc.rs`
- Modify: `crates/petcore-types/src/lib.rs`

**Interfaces:**
- Snapshot exposes `active_generation: Option<GenerationSessionSnapshot>` including the submitted form, stable message ids/revision and input-request state; PetCore permits at most one pending/running/waiting job.
- Every message is `GenerationMessageRecord { id, job_id, sequence, kind, content, created_at }` in SQLite; JSONL is an append-only diagnostic mirror, not the source of truth.
- Cancellation removes only an uncommitted revision and never the previous active pet revision.

- [x] **Step 1: Add failing recovery tests**

  Add `cancel_revision_preserves_existing_pet`, `second_generation_is_rejected_while_one_is_active`, `snapshot_includes_running_and_waiting_job`, `message_ids_survive_restart`, `truncated_jsonl_tail_does_not_hide_committed_messages`, and `recovery_marks_only_jobs_owned_by_dead_instance`.

- [x] **Step 2: Verify RED**

  Run: `cargo test -p petcore --test generation_recovery --test generation_lifecycle -- --nocapture`
  Expected: FAIL because messages are JSONL-derived, snapshot omits active jobs and cancel can remove installed resources.

- [x] **Step 3: Implement DB-backed ordered messages and ownership**

  Add `owner_instance_id` and heartbeat to active jobs. Append each message and status transition transactionally with a monotonic sequence. Recovery only fails jobs whose owner marker is provably dead. Preserve JSONL parsing diagnostics by quarantining a malformed/torn tail rather than silently filtering it.

- [x] **Step 4: Verify GREEN**

  Run: `cargo test -p petcore --test generation_recovery --test generation_lifecycle -- --nocapture`
  Expected: PASS.

### Task 5: App Server EOF Handling and Honest Real-Source Generation

**Audit coverage:** APC-P1-006, APC-P1-014; optimization item 5.

**Files:**
- Create: `crates/petcore/tests/app_server_transport.rs`
- Create: `crates/petcore/tests/fixtures/app-server/`
- Modify: `crates/petcore/src/app_server.rs`
- Modify: `crates/petcore/src/generation.rs`
- Modify: `skills/agent-pet-studio/SKILL.md`
- Modify: `skills/agent-pet-studio/scripts/`
- Modify: `script/validate_real_app_server.sh`
- Modify: `README.md`
- Modify: `README.zh-CN.md`

**Interfaces:**
- EOF is a terminal transport event; if the child has exited, return its bounded stderr immediately.
- Production completion accepts only a Skill-authored full `petpack-source` that contains all seven validated state directories and records reference usage metadata when references were provided.
- Procedural single-frame materialization is available only when `APC_VALIDATION_MATERIALIZER=1` and is labeled `validation_fixture`, never `ai_generated`.

- [x] **Step 1: Add failing transport/source tests**

  Add `stdout_eof_fails_without_spinning`, `stderr_is_bounded`, `production_rejects_validation_materializer`, `full_source_requires_all_seven_states`, `reference_job_requires_reference_usage_record`, and `validation_materializer_is_explicitly_marked_non_ai`.

- [x] **Step 2: Verify RED**

  Run: `cargo test -p petcore --test app_server_transport -- --nocapture`
  Expected: FAIL on EOF loop and current built-in placeholder acceptance.

- [x] **Step 3: Implement terminal EOF and full-source gate**

  Replace polling ambiguity with an enum `AppServerRead::{Message(Value), Eof(ExitStatus), Timeout}`. Remove production fallback language that calls geometric frames real generation. The Skill contract must instruct Codex to use an available image-generation capability, write at least two transparent PNG frames for each of all seven states at the exact quality dimensions, validate/build through `petcore-cli`, and return form/reference digests plus exact provenance. Each state must contain motion (at least one adjacent hash differs) and seven states cannot all share one sequence. Unavailable image capability yields a clear actionable failure rather than fake success.

- [x] **Step 4: Verify focused and opt-in paths**

  Run: `cargo test -p petcore --test app_server_transport -- --nocapture`
  Expected: PASS.

  Run: `APC_VALIDATE_REAL_APP_SERVER=0 ./script/validate_real_app_server.sh`
  Expected: SKIP without starting an external agent. A real run remains explicit: `APC_VALIDATE_REAL_APP_SERVER=1`.

### Task 6: Bounded Process Runner and Safe Connector Install/Uninstall

**Audit coverage:** APC-P2-006, APC-P2-007; optimization item 9.

**Files:**
- Create: `crates/petcore/src/process_runner.rs`
- Create: `crates/petcore/tests/process_runner.rs`
- Modify: `crates/petcore/src/lib.rs`
- Modify: `crates/petcore/src/connections.rs`

**Interfaces:**
- Produces `run_bounded(ProcessSpec { program, args, timeout, max_stdout, max_stderr }) -> Result<ProcessResult>`; default connector timeout five seconds and each output maximum 64 KiB.
- Timeout terminates the child process group.
- Claude uninstall removes only entries whose canonical command belongs to Agent Pet Companion and preserves other entries/unknown JSON fields/order.

- [x] **Step 1: Add failing timeout and merge tests**

  Add `hung_cli_is_terminated_at_deadline`, `process_output_is_truncated`, `claude_uninstall_preserves_mixed_hook_group`, and `claude_uninstall_preserves_unknown_settings_fields`.

- [x] **Step 2: Verify RED**

  Run: `cargo test -p petcore --test process_runner -- --nocapture`
  Expected: FAIL on direct unbounded `Command::output` and group deletion.

- [x] **Step 3: Implement and adopt the shared runner**

  Replace every external check/repair command in `connections.rs` with `run_bounded`; structured removal walks each event/group/hooks array and deletes only matching command objects, then prunes genuinely empty containers.

- [x] **Step 4: Verify GREEN**

  Run: `cargo test -p petcore --test process_runner --test core_validation connections -- --nocapture`
  Expected: PASS.

### Task 7: Versioned Official Codex, Claude, Pi and OpenCode Adapters

**Audit coverage:** APC-P1-016, APC-P1-017, APC-P2-024, APC-P2-025, APC-P2-026, APC-P2-027.

**Files:**
- Create: `fixtures/contracts/codex/`
- Create: `fixtures/contracts/claude-code/`
- Create: `fixtures/contracts/pi/`
- Create: `fixtures/contracts/opencode-v1.17.18/`
- Create: `plugins/claude-code/settings.fragment.json.tpl`
- Create: `plugins/pi/agent-pet-companion.ts.tpl`
- Create: `plugins/opencode/agent-pet-companion.js.tpl`
- Modify: `plugins/codex/.codex-plugin/plugin.json`
- Create: `plugins/codex/hooks/hooks.json.tpl`
- Create: `crates/petcore/tests/connector_contracts.rs`
- Modify: `crates/petcore/src/connections.rs`
- Modify: `crates/petcore-cli/src/main.rs`
- Modify: `script/validate_connectors_runtime.sh`
- Modify: `script/validate_real_agent_connectors.sh`
- Modify: `docs/design/AgentPetCompanion_TechnicalPlan_V1_1.md`

**Interfaces:**
- Every fixture maps to `ContractEvent { source, session_id, kind, tool_name, outcome }` without raw payload persistence.
- Codex uses only current official hook names; unsupported failure is reported as unavailable instead of fabricated.
- Claude honors `CLAUDE_CONFIG_DIR`, uses quiet bounded hooks, and distinguishes `StopFailure` from `PostToolUseFailure`.
- Pi registers only official literal events and uses `agent_settled` for the final outcome. A later runtime correction established that `tool_execution_end.isError` is recoverable tool-level state; only a settled run whose final assistant message has `stopReason=error` is Failed. These structured extension events remain the authoritative capability path for title, message, state, and close signals.
- OpenCode reads `event.properties.sessionID`, `input.sessionID`, `output.args`, never assumes `output.error`, and handles permission asked/updated/replied compatibility without leaving replied sessions waiting.

- [x] **Step 1: Add official-shape fixtures and failing contract tests**

  Include Codex Stop/PostToolUse, Claude UserPromptSubmit/PostToolUseFailure/StopFailure, Pi `agent_settled`/`tool_execution_end {isError}`/`session_shutdown`, and OpenCode `{type,properties}` plus direct before/after fixtures. Tests assert exact session/kind and assert templates contain no Pi invalid event, Codex `StopFailure`, OpenCode `session.done` or fabricated `tool.execute.failed`.

- [x] **Step 2: Verify RED**

  Run: `cargo test -p petcore --test connector_contracts -- --nocapture`
  Expected: FAIL on current template and parser assumptions.

- [x] **Step 3: Implement adapters and truthful checks**

  Move connector source templates out of Rust string literals and load them with `include_str!`; generate scripts from explicit literal handlers, quiet hook commands and version constants. Static checks structurally parse configuration; capability checks distinguish `configured`, `runtime_verified`, `unsupported` and `blocked_by_host_policy`. Codex advertises no hook-backed review/failed; Pi advertises Extension observation only and marks waiting as requiring an interactive bridge; OpenCode server is healthy only after an opt-in bounded process receives valid JSON from `/global/health`. Do not call help-text presence “RPC/server healthy”.

- [x] **Step 4: Verify GREEN without host mutation**

  Run: `cargo test -p petcore --test connector_contracts --test core_validation connections -- --nocapture`
  Expected: PASS using temporary homes only.

### Task 8: Asynchronous Swift Transport and Idempotent Service Startup

**Audit coverage:** APC-P1-007, APC-P1-012; optimization items 5 and 10.

**Files:**
- Create: `apps/macos/Sources/AgentPetCompanionCore/PetCoreTransport.swift`
- Create: `apps/macos/Tests/AgentPetCompanionCoreTests/PetCoreTransportTests.swift`
- Create: `apps/macos/Tests/AgentPetCompanionTests/PetCoreProcessManagerTests.swift`
- Modify: `apps/macos/Package.swift`
- Modify: `apps/macos/Sources/AgentPetCompanionCore/PetCoreClient.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/App/PetCoreProcessManager.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/App/AppStore.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/App/AgentPetCompanionApp.swift`

**Interfaces:**
- `PetCoreTransport` is an actor with `request(method:params:timeout:) async throws -> Data`; default timeout five seconds, cancellation closes the socket.
- `PetCoreProcessManager.ensureRunning() async -> ServiceStartResult` returns `.alreadyHealthy`, `.started`, or `.failed(reason)`.
- A healthy service never executes `kickstart -k`; forced restart is a separate user/diagnostic action.

- [x] **Step 1: Add Swift test targets and failing transport/startup tests**

  Add fake UDS tests `request_times_out`, `task_cancellation_closes_connection`, `partial_response_does_not_block_main_actor`, and process runner tests `healthy_service_skips_launchctl`, `missing_service_bootstraps_once`, `concurrent_bootstrap_calls_coalesce`.

- [x] **Step 2: Verify RED**

  Run: `cd apps/macos && swift test --filter 'PetCoreTransportTests|PetCoreProcessManagerTests'`
  Expected: FAIL because test targets/async actor do not exist and current manager always kickstarts.

- [x] **Step 3: Implement transport and startup state machine**

  Move connect/read/write into a non-main actor with bounded frames and cancellation handlers. Inject health/launchctl runners into the process manager for tests. App bootstrap calls `ensureRunning` once and then starts snapshot observation.

- [x] **Step 4: Verify GREEN**

  Run: `cd apps/macos && swift test --filter 'PetCoreTransportTests|PetCoreProcessManagerTests'`
  Expected: PASS.

### Task 9: Resumable Generation State Machine in macOS

**Audit coverage:** APC-P1-008, UI half of APC-P1-009, APC-P2-021, APC-P3-004.

**Files:**
- Create: `apps/macos/Sources/AgentPetCompanionCore/GenerationSessionState.swift`
- Create: `apps/macos/Tests/AgentPetCompanionCoreTests/GenerationSessionStateTests.swift`
- Modify: `apps/macos/Sources/AgentPetCompanionCore/AppModels.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/App/AppStore.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/Views/PetStudioView.swift`

**Interfaces:**
- `GenerationSessionState` cases are `idle`, `starting`, `running`, `waitingForInput`, `cancelling`, `succeeded`, `failed`, `cancelled`.
- `isActive` is true for starting/running/waitingForInput/cancelling.
- Snapshot reconciliation selects the newest active job, retains stable message ids and resumes the message wait loop.

- [x] **Step 1: Add failing reducer tests**

  Add `input_request_remains_active`, `waiting_job_restores_after_restart`, `active_form_is_immutable`, `cancel_is_visible_while_waiting`, `message_identity_is_stable`, and `terminal_job_stops_stream_once`.

- [x] **Step 2: Verify RED**

  Run: `cd apps/macos && swift test --filter GenerationSessionStateTests`
  Expected: FAIL because current booleans make input request inactive and IDs are regenerated.

- [x] **Step 3: Implement reducer and freeze submitted form**

  Replace `isGenerating` derivation with state `isActive`; preserve a submitted `GenerationFormSnapshot` separate from editable draft. On bootstrap, reconcile active jobs before rendering Studio. Waiting input exposes only reply/cancel, not a second start.

- [x] **Step 4: Verify GREEN**

  Run: `cd apps/macos && swift test --filter GenerationSessionStateTests`
  Expected: PASS.

### Task 10: Overlay Geometry, One-Shot Playback, Multi-Display and Keyboard Resize

**Audit coverage:** APC-P1-010, APC-P1-013, APC-P2-013, APC-P2-016.

**Files:**
- Create: `apps/macos/Tests/AgentPetCompanionTests/OverlayGeometryTests.swift`
- Create: `apps/macos/Sources/AgentPetCompanion/Overlay/OverlayResizeAccessibility.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/Overlay/OverlayGeometry.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/Overlay/OverlayRootView.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/Overlay/PetOverlayController.swift`
- Modify: `apps/macos/Sources/AgentPetCompanionCore/FrameScheduler.swift`

**Interfaces:**
- Clamp uses the complete interactive bounds: pet, shadow, menu and bottom-right resize handle.
- Drag selects the screen containing the current pointer, not the mouse-down screen.
- `FrameScheduler` accepts `loops: Bool`; one-shot states stop at the final frame and reset on state entry.
- Resize handle supports focus, arrow-key increments and AX increment/decrement with a five-percent step.
- New placements use a calibrated scale of `0.72`; legacy/custom nonzero placements are never overwritten.

- [x] **Step 1: Add failing pure geometry/scheduler tests**

  Add `resize_handle_stays_inside_each_screen_edge`, `drag_can_cross_between_displays`, `one_shot_stops_on_last_frame`, `looping_state_wraps`, `state_change_resets_frame`, and `keyboard_resize_clamps_scale`.

- [x] **Step 2: Verify RED**

  Run: `cd apps/macos && swift test --filter 'OverlayGeometryTests|FrameSchedulerTests'`
  Expected: FAIL on current pet-only clamp and modulo playback.

- [x] **Step 3: Implement complete bounds and accessible actions**

  Keep the visual handle in the bottom-right and preserve the no-settings-field constraint. Apply the same `setOverlayScale` path for mouse, `⌘⌥=`/`⌘⌥-`, and AX increment/decrement actions, each using a 0.05 step. Use the dynamically resolved `NSScreen.visibleFrame` during drag. Change only the never-positioned default from 0.12 to 0.72; retain every persisted user scale.

- [x] **Step 4: Verify GREEN and non-mouse validation**

  Run: `cd apps/macos && swift test --filter 'OverlayGeometryTests|FrameSchedulerTests'`
  Expected: PASS.

  Run: `APC_VALIDATE_OVERLAY_RUNTIME=0 ./script/validate_overlay_non_mouse.sh`
  Expected: deterministic validation PASS without GUI mutation.

### Task 11: Background Frame Pipeline and Event-Driven Pointer Tracking

**Audit coverage:** APC-P1-011, APC-P2-019; optimization item 7.

**Files:**
- Create: `apps/macos/Sources/AgentPetCompanion/Overlay/PetFramePipeline.swift`
- Create: `apps/macos/Tests/AgentPetCompanionTests/PetFramePipelineTests.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/Overlay/OverlayRootView.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/Overlay/PetOverlayController.swift`
- Modify: `script/validate_renderer_runtime_budget.sh`

**Interfaces:**
- `PetFramePipeline` is an actor with a bounded decode queue and in-memory LRU; `draw(in:)` only requests an already decoded `CIImage`/texture and never reads files.
- Original quality keeps a bounded ring window; other qualities predecode only the active state.
- Pointer visibility uses tracking areas/local-global event monitors; no permanent 108 Hz timer.

- [x] **Step 1: Add failing pipeline tests**

  Add `draw_lookup_never_reads_disk`, `decode_work_is_not_main_actor`, `lru_respects_byte_budget`, `original_quality_keeps_ring_window`, and `pointer_tracking_has_no_high_frequency_timer`.

- [x] **Step 2: Verify RED**

  Run: `cd apps/macos && swift test --filter PetFramePipelineTests`
  Expected: FAIL because current renderer decodes/warms synchronously in the draw path.

- [x] **Step 3: Implement actor pipeline and render handoff**

  Decode through ImageIO/CIImage off-main, calculate actual RGBA cost, publish immutable ready frames, and draw a prior/cover frame while prefetch is pending. Pause and release pipeline work when overlay is hidden.

- [x] **Step 4: Verify GREEN and collect real metrics**

  Run: `cd apps/macos && swift test --filter PetFramePipelineTests`
  Expected: PASS.

  Run: `APC_VALIDATE_OVERLAY_RUNTIME=1 ./script/validate_renderer_runtime_budget.sh`
  Expected: records real CPU/RSS/frame telemetry; no estimate-only success is accepted.

### Task 12: Canonical Behavior Mutations, Auto-Hide and Agent Arbitration

**Audit coverage:** APC-P2-014, APC-P2-015, APC-P2-020.

**Files:**
- Create: `crates/petcore/src/agent_state.rs`
- Create: `crates/petcore/tests/agent_state_arbitration.rs`
- Create: `apps/macos/Tests/AgentPetCompanionCoreTests/BehaviorSettingsTests.swift`
- Modify: `crates/petcore/src/db.rs`
- Modify: `crates/petcore/src/rpc.rs`
- Modify: `apps/macos/Sources/AgentPetCompanionCore/AppModels.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/App/AppStore.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/Overlay/PetOverlayController.swift`

**Interfaces:**
- PetCore returns `active_agent_state` selected by priority, event timestamp, source/session sequence and TTL; UI does not re-arbitrate.
- Behavior changes use `behavior.patch { expected_revision, changes }`; stale patches return conflict and trigger refresh.
- `auto_hide` means status bubbles are hidden when there is no active event; idle pet visibility remains controlled by `enabled`.

- [x] **Step 1: Add failing arbitration/patch/visibility tests**

  Add `newer_lower_priority_event_replaces_expired_state`, `stale_event_does_not_override_current_state`, `concurrent_behavior_patches_do_not_lose_fields`, `stale_revision_returns_conflict`, and `idle_auto_hide_semantics_are_consistent`.

- [x] **Step 2: Verify RED**

  Run: `cargo test -p petcore --test agent_state_arbitration -- --nocapture && (cd apps/macos && swift test --filter BehaviorSettingsTests)`
  Expected: FAIL because arbitration is in AppStore and writes replace the full object.

- [x] **Step 3: Implement canonical core state and serialized patches**

  Use a 30-second default lease for nonterminal activity, five seconds for done/failed and explicit session sequence ordering. Make copy/UI text match the precise auto-hide definition.

- [x] **Step 4: Verify GREEN**

  Run: `cargo test -p petcore --test agent_state_arbitration -- --nocapture && (cd apps/macos && swift test --filter BehaviorSettingsTests)`
  Expected: PASS.

### Task 13: Accessible, Adaptive and Truthful macOS UI

**Audit coverage:** APC-P2-017, APC-P2-018, APC-P2-022, APC-P2-023, APC-P3-005, APC-P3-006, APC-P3-007, APC-P3-008.

**Files:**
- Create: `apps/macos/Sources/AgentPetCompanion/Resources/Localizable.xcstrings`
- Create: `apps/macos/Tests/AgentPetCompanionTests/UIModelTests.swift`
- Modify: `apps/macos/Package.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/Views/DesignSystem.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/Views/ContentView.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/Views/BehaviorSettingsView.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/Views/AgentConnectionsView.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/Views/PetLibraryView.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/Views/PetStudioView.swift`

**Interfaces:**
- All colors are semantic and provide light/dark/increased-contrast resolution.
- Every switch/button/card/picker has a stable label, value/selected state, keyboard action and non-color status text.
- Connection grid items align `.top`; `PetCard` is a Button.
- Library integrity and manifest facts come from PetCore `runtime_assets` (`validation_status`, issues, per-state frame count/loop, FPS profiles and default profile); only `.petpack` is importable through a declared `dev.agentpet.petpack` UTType.
- Empty library uses a localized CTA back to New; no hand-drawn fake pet asset.

- [x] **Step 1: Add failing UI model/resource tests**

  Add `all_v1_copy_keys_exist_in_english_and_chinese`, `event_and_source_controls_have_distinct_labels`, `connection_grid_is_top_aligned`, `library_uses_validation_summary`, `import_accepts_only_petpack`, `non_active_pet_does_not_show_global_event`, and `default_scale_meets_minimum_visible_size`.

- [x] **Step 2: Verify RED**

  Run: `cd apps/macos && swift test --filter UIModelTests`
  Expected: FAIL because localization resources/semantic models do not yet exist.

- [x] **Step 3: Implement using the existing design system**

  Preserve current layout language and tokens, replacing only fixed colors/ambiguous semantics. Add visible selection marks and `.accessibilityAddTraits(.isSelected)`, switch labels that include source/event names, live announcements for generation/connection results, top alignment and truthful validation copy. Use dynamic semantic colors that meet 4.5:1 body-text and 3:1 non-text contrast in light/dark/increased-contrast modes. Bundle a real starter pet only if an existing licensed project asset is available; otherwise show a localized empty state with a Pet Library CTA and without a fake drawing.

- [x] **Step 4: Verify GREEN and real appearance modes**

  Run: `cd apps/macos && swift test --filter UIModelTests`
  Expected: PASS.

  Run: `APC_VALIDATE_MAIN_WINDOW_UI=1 ./script/validate_main_window_ui.sh`
  Expected: PASS in light, dark and increased-contrast captures with keyboard/AX traversal evidence.

### Task 14: Reproducible Tests, CI, Packaging and Documentation

**Audit coverage:** APC-P1-015, APC-P3-009; delivery and test optimization items 10–12.

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/dependabot.yml`
- Create: `rust-toolchain.toml`
- Create: `CONTRIBUTING.md`
- Create: `docs/release/macos-release.md`
- Create: `docs/design/README.md`
- Create: `script/build_app_bundle.sh`
- Create: `script/build_release.sh`
- Create: `script/sign_and_notarize.sh`
- Create: `script/validate_build_scripts_safety.sh`
- Create: `script/validate_test_isolation.sh`
- Modify: `.gitignore`
- Modify: `Cargo.toml`
- Modify: `crates/petcore-types/src/lib.rs`
- Modify: `crates/petcore/src/petpack.rs`
- Modify: `apps/macos/Sources/AgentPetCompanionCore/AppModels.swift`
- Modify: `apps/macos/Sources/AgentPetCompanion/App/AppStore.swift`
- Modify: `apps/macos/Package.swift`
- Modify: `script/build_and_run.sh`
- Modify: `script/test_all.sh`
- Modify: `script/validate_*.sh`
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `docs/plan/AgentPetCompanion_ImplementationPlan_V2.md`
- Modify: `docs/design/product-plan-v5/AgentPetCompanion_ProductPlan_V5.md`
- Modify: `docs/design/AgentPetCompanion_TechnicalPlan_V1_1.md`

**Interfaces:**
- `script/test_all.sh` defaults to isolated unit/integration work only and never starts GUI, kills processes, changes LaunchAgents or calls real external agents.
- Host-mutating checks require `APC_VALIDATE_HOST_UI=1`; real agents require their existing explicit gates.
- CI runs format, strict clippy, locked Rust tests, Swift tests, schema fixtures and shell/Python syntax.
- Release documentation/build supports universal Release, Developer ID signing, hardened runtime, notarization and stapling when credentials are supplied; absence of credentials is reported, not faked.

- [x] **Step 1: Add a host-side-effects guard and verify it fails**

  Add a validation that injects fake `launchctl`, `pkill`, `open`, `codex`, `claude`, `pi` and `opencode` binaries which fail if invoked, then runs default build/test commands. Also add a cleanup assertion for connector temporary files and Python caches.

  Run: `./script/validate_test_isolation.sh`
  Expected: FAIL because `build_and_run.sh` touches processes before parsing mode.

- [x] **Step 2: Make build/test modes isolated and deterministic**

  Parse arguments first; build-only performs compilation only. Use temporary APC_HOME/socket/labels in integration tests, unique `mktemp -d` paths with traps, and split real gates from default. Reuse builds and emit JUnit where the runner supports it.

- [x] **Step 3: Fix static quality and executable schema checks**

  Derive `Default` instead of the clippy-warning manual implementation, set the canonical repository to `https://github.com/xjxtree/agent-pet-companion`, pin Rust 1.96.0 with rustfmt/clippy, add Swift test targets, and validate all positive/negative schema fixtures in CI.

- [x] **Step 4: Align docs and packaging**

  Update V1.1 references, the product-plan four-field form (description/style/quality/references; remove the unused `note` field from technical/schema/runtime claims), canonical `.petpack` layout, only-app-owned import semantics, current connector contracts, macOS 14+, Swift 6/Xcode 16+, Rust 1.96.0 and preview/full AI distinction. Index old design assets rather than deleting uncertain user files. Exclude `__pycache__`, `.pyc`, jobs, DerivedData and temporary assets from source/bundle. Provide exact signed/notarized release commands but never read credentials.

- [x] **Step 5: Verify the delivery gate**

  Run: `./script/validate_test_isolation.sh && cargo fmt --all -- --check && cargo clippy --workspace --all-targets --all-features -- -D warnings && cargo test --workspace --locked && (cd apps/macos && swift test) && ./script/validate_app_bundle.sh`
  Expected: PASS; bundle validator distinguishes a valid development build from a distributable signed/notarized build.

### Task 15: Full Regression, Real UI Review and Issue Ledger Closure

**Audit coverage:** all 54 issues (including the remediation-time renderer measurement finding APC-P2-028) and all 12 optimization items.

**Files:**
- Modify: `docs/audits/2026-07-10-project-review/REPORT.md`
- Create: `docs/audits/2026-07-10-project-review/FINAL-VERIFICATION.md`
- Update: `docs/audits/2026-07-10-project-review/screenshots/` only with fresh post-fix captures.

**Interfaces:**
- Every audit id has one final state: `FIXED` with test/evidence, `MITIGATED` with a bounded residual risk, or `DEFERRED` only when an external credential/service is the sole blocker and the local implementation is complete.
- No unexplained `OPEN` remains.

- [x] **Step 1: Run the complete isolated gate from a fresh build**

  Run: `APC_VALIDATE_OVERLAY_RUNTIME=0 APC_VALIDATE_REAL_AGENT_CONNECTORS=0 APC_VALIDATE_REAL_APP_SERVER=0 ./script/test_all.sh`
  Expected: PASS with Rust, Swift, schemas, scripts, security, event storm and bundle validation.

- [x] **Step 2: Run strict static checks**

  Run: `cargo fmt --all -- --check && cargo clippy --workspace --all-targets --all-features -- -D warnings && git diff --check`
  Expected: PASS with zero warnings/errors.

- [x] **Step 3: Run host UI/performance verification**

  Run the macOS app in an isolated APC_HOME and verify Pet Studio New/Library, Behavior, Connections, active/waiting/recovered generation, overlay each screen edge, cross-display drag, mouse/keyboard/AX resize, one-shot playback, hide/pause, dark/high-contrast and real renderer CPU/RSS. Capture before/after comparisons at the same viewport/state.

- [x] **Step 4: Run explicitly authorized real integration gates when available**

  Run only with existing local user authorization: `APC_VALIDATE_REAL_AGENT_CONNECTORS=1 ./script/validate_real_agent_connectors.sh` and `APC_VALIDATE_REAL_APP_SERVER=1 ./script/validate_real_app_server.sh`. Do not read auth files. If unavailable, record `MITIGATED` with the passing fixture/contract gate and exact external condition needed.

- [x] **Step 5: Close the report**

  Replace every issue status, link each to its regression test/verification section, record remaining external release credential limitations, and perform a final diff review that separates this remediation from the user's pre-existing changes.
