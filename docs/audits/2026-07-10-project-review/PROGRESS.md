# Remediation Progress Ledger

Branch: `codex/project-audit-remediation`
Plan: `docs/superpowers/plans/2026-07-10-project-audit-remediation.md`

## Completed slices

- 2026-07-10 — Petpack strict validation slice:
  - Reject blank manifest name/style, invalid RFC3339 `created_at`, unknown manifest/state/render fields.
  - Reject nested frame directories, more than 40 frames per state, decoded state data over 420 MiB, and build output located inside its input tree.
  - Reject duplicate/case-colliding archive paths and backslash archive paths.
  - Evidence: `cargo test -p petcore --test petpack_resource_limits`; existing petpack-focused core/import tests pass.
- 2026-07-10 — Shared reference-image policy slice:
  - Only decoded PNG/WebP; extension must match content.
  - Maximum 4 files, 20 MiB each, 40 MiB total, 16,000,000 pixels each.
  - Generation staging and petpack materialization share the validator.
  - Evidence: `cargo test -p petcore --test reference_image_policy`; generation-focused regressions pass.
- 2026-07-10 — App Server stdout EOF handling slice:
  - Reader distinguishes line, timeout, I/O failure and terminal EOF.
  - Initialize-response and mid-turn EOF fail immediately with child exit code and bounded stderr diagnostics instead of spinning/polling until timeout.
  - Evidence: `cargo test -p petcore --test app_server_transport`; existing Codex App Server core regressions pass.
- 2026-07-10 — Generation message-log recovery slice:
  - New messages carry server-stable ids; legacy messages receive deterministic ids on read.
  - Complete corrupt records become bounded hash/category diagnostics without echoing content, while later valid records remain visible.
  - A torn trailing record is repaired before append, preventing it from poisoning the next message.
  - Evidence: `cargo test -p petcore --test generation_jsonl_recovery`.
- 2026-07-10 — Immutable pet revision and atomic import slice:
  - Assets are staged and fsynced under `pets/<id>/revisions/<revision>/`; `active.json` is atomically replaced and the prior revision is never overwritten.
  - Database insert/update failure removes only the uncommitted revision and restores the previous pointer. Generation cancellation restores the previous DB row/revision and ignores a late rollback after a newer manual import.
  - Direct CLI import routes through the daemon; explicit `--offline` requires the daemon singleton lock. Cross-process pet writes share a dedicated store lock.
  - Evidence: `petpack_import_atomic` 12/12 and `petpack_import_routing` 3/3 pass.
- 2026-07-10 — Petpack archive/decode budgets and validation cache slice:
  - Enforces 1 GiB archive, 4 GiB expanded tree, 256 MiB entry, 5,000 entry, 40 frame/state, 280 frame total, 16,777,216 pixel/frame and 420 MiB decoded/state limits.
  - Snapshot validation is fingerprint-cached. Changed assets are repaired/revalidated; unchanged failures are not retried and appear as structured `pet_asset_warnings`.
  - Petpack JSON Schema now matches fixed frame paths/loop semantics and the standard 12 FPS default.
  - Evidence: `petpack_resource_limits` 10/10, `petpack_import_atomic` 12/12, and snapshot regressions pass.
- 2026-07-10 — Rust lint gate restored:
  - `cargo clippy --workspace --all-targets --all-features -- -D warnings` passes.
- 2026-07-10 — Daemon singleton, identity and bounded local transport slice:
  - Singleton acquisition precedes mutable initialization; runtime markers bind PID, process start, instance id and HTTP port and are removed only by their owner.
  - UDS/HTTP frames, clients, deadlines and responses are bounded; JSON-RPC notifications/batches/error codes and strict parameter rejection are covered.
  - Contended identity health probing now shares one absolute deadline for write plus a 64 KiB response, including a drip-response regression.
  - Evidence: `daemon_lifecycle` 25/25 and daemon HTTP security regressions pass.
- 2026-07-10 — Asynchronous Swift transport and owned service recovery slice:
  - UDS work is off the main actor, bounded and cancellation-aware; process execution has timeout/output limits and TERM→KILL cleanup.
  - Healthy startup is idempotent, concurrent startup/recovery coalesces and the app recovers a killed owned PetCore without global process discovery.
  - Evidence: `AgentPetCompanionTransportValidation` executes 13/13 checks; owned recovery and isolation validators pass. Swift Testing targets are retained for Xcode CI while this host's CommandLineTools-only SwiftPM discovery limitation is handled by executable validators.
- 2026-07-10 — Safe connector runner and official versioned contract slice:
  - All connector probes use the bounded process-group runner; Claude uninstall preserves unrelated hook entries and unknown settings.
  - Codex, Claude Code, Pi and OpenCode templates are fixture-tested against supported event shapes; unsupported capabilities are reported rather than inferred from help text.
  - Hook ingress sends only the state allowlist and deterministic-preview generation evidence is never labeled a real skill source.
  - Evidence: connector contracts 4/4, process runner 3/3, CLI 8/8, connector runtime and security validators pass.
- 2026-07-10 — Honest App Server source gate slice:
  - The bundled materializer is explicitly a multi-frame deterministic preview. Strict external completion rejects preview helpers, brief-only output, missing reference-use evidence and visually identical state sequences.
  - EOF now captures the real bounded exit diagnostics despite the stdout/waitpid scheduling race.
  - Evidence: App Server transport 2/2, generation-focused core regressions 15/15; real App Server remains an explicit opt-in acceptance gate.
- 2026-07-10 — Reproducible delivery and documentation slice:
  - Added pinned Rust toolchain, macOS CI, executable positive/negative schema fixtures, dependency updates, source syntax checks and bilingual contribution/design indexes.
  - Default build/test modes are host-safe; development bundles are labeled non-distributable. Universal Release signing, hardened runtime, notarization, stapling and Gatekeeper validation require explicit operator-supplied identity/profile values.
  - Product/technical/runtime contracts now agree on the four-field Studio form and canonical app-owned `.petpack` root layout.
  - Evidence: test isolation, schema fixture, source syntax, build-script safety and development bundle gates pass.
- 2026-07-10 — Strict event privacy, retention and numeric revision slice:
  - External payloads are reduced to a six-field persisted envelope; title/detail are UTF-8 byte bounded and source/session/external-id form the deduplication identity.
  - Legacy arbitrary payload rows are rebuilt, checkpointed and vacuumed; recent-event reads clamp at 200, default raw retention is 10,000 rows/30 days and daily source/type counts survive pruning.
  - A single numeric revision row advances through client-visible table triggers while RPC keeps its string compatibility boundary.
  - Evidence: event security 10/10, schema fixtures 2/2, HTTP security 4/4, core Agent 7/7, CLI 9/9 + routing 3/3, security boundary and strict Clippy pass.
- 2026-07-10 — Overlay geometry, playback and renderer pipeline slice:
  - Clamp uses the complete interactive bounds and current-pointer display; start/done stop at the final frame; resize supports keyboard and AX slider actions.
  - Frame discovery/decode/prefetch runs off-main with bounded LRU/ring handoff and no draw-path disk access; pointer tracking is event driven.
  - Hand-drawn missing-pet artwork was removed in favor of an honest empty state; an unpositioned pet starts at a calibrated 0.72 scale.
  - Evidence: UI validation 7/7, offline overlay, non-mouse AX and real drag/resize/bubble-close gates pass. Renderer telemetry recorded ultra 18.22 FPS and original 20.04 FPS; a newly found measurement-gap review is tightening CPU/RSS-delta assertions before final closure.
- 2026-07-10 — Accessible, adaptive and truthful main-window UI slice:
  - Semantic light/dark/high-contrast tokens and labeled/value/selected keyboard-accessible controls replace color-only or gesture-only interactions; connection grids top-align.
  - Library consumes daemon asset warnings and otherwise says the complete specification was not reported; no hard-coded completeness, state-count or FPS claims remain and inactive pets do not show global events.
  - App-owned `.petpack` import has an exported UTI/extension declaration. Stable English/Simplified-Chinese keys ship as a catalog plus SwiftPM runtime resources.
  - Evidence: Swift Testing 38/38, UI validation 7/7, core validation and development bundle validation pass.
- 2026-07-10 — Recoverable generation truth source and ownership slice:
  - Generation jobs carry daemon instance ownership and heartbeat; only stale jobs whose previous owner cannot be proven healthy are recovered.
  - SQLite is the ordered message truth source with stable ids and monotonic per-job sequence. JSONL is a bounded diagnostic/one-time compatibility mirror, and message plus status transitions are transactional.
  - `state.snapshot.active_generation` exposes the active form, messages, input request and message revision; `BEGIN IMMEDIATE` enforces at most one pending/running/waiting job.
  - Evidence: generation recovery 8/8, JSONL recovery 4/4, lifecycle 4/4, daemon lifecycle 25/25 and core validation 55/55 pass.
- 2026-07-10 — Resumable macOS generation session slice:
  - A typed eight-state reducer keeps input requests active, freezes a submitted form separately from the editable draft and uses stable daemon message ids.
  - Bootstrap reconciles `active_generation`, restores running/waiting sessions and starts one message subscription without repeatedly restarting it for the same job.
  - Evidence: generation session tests 10/10, core executable validation and Swift build pass; the earlier full Swift run was 48/48.
- 2026-07-10 — Renderer measurement hardening slice:
  - Runtime telemetry records tracked decoded cache bytes plus Metal device and drawable texture allocations.
  - The host gate now samples hidden/default-high/ultra/original states for 30 seconds each and hard-asserts CPU averages, hidden CPU, measured FPS and RSS peak delta against the documented Renderer budgets.
  - Final host evidence: hidden CPU 0.10%; high 2.50% / 12.00 FPS / 21.08 MiB RSS delta; ultra 3.27% / 19.99 FPS / 57.69 MiB; original 3.60% / 20.04 FPS / 247.58 MiB. All CPU, FPS and renderer-memory assertions pass.
- 2026-07-10 — Independent-review privacy/process/behavior hardening slice:
  - Strict event ingest now rejects unknown raw fields; external title/detail are discarded and lifecycle/tool/outcome metadata is normalized to closed vocabularies. Persisted and ingest schemas are separate and bidirectionally fixture-tested.
  - Legacy event rebuild derives safe copy and null detail. A persisted privacy-migration marker survives crashes; SQLite/WAL secure vacuum must finish before schema version advances, including upgrade retry from the previously vulnerable window.
  - Claude uninstall removes only exact canonical owned commands. The bounded runner uses a dedicated process group plus PID/start-identity registration for cooperative daemon descendants, rejects foreign PID injection and never relies on global process-name killing.
  - Behavior writes are field-level CAS patches with a behavior-only revision; generic settings RPC cannot bypass them. PetCore returns the canonical leased Agent state and overlay visibility, and macOS consumes that state without UI-side priority arbitration.
  - Evidence: event privacy 15/15, schema 3/3, agent-state 6/6, process-runner 6/6, Swift Behavior 4/4, strict Clippy, connector/security/isolation gates and full Swift 54/54 pass.

## Final closure

- 2026-07-10 — Complete isolated and host regression:
  - Rust format, strict clippy, locked serial workspace tests and `cargo audit --deny warnings` pass; RustSec scans 159 dependencies with zero vulnerabilities.
  - Swift Testing passes 57/57 across 8 suites, including the follow-up regression that keeps the scale percentage hidden while the resize control is merely focused.
  - Default `test_all.sh` passes M0–M6, schema fixtures, syntax/safety, simulated connectors, event storm, V1, security, offline overlay and development bundle packaging without host mutations.
  - Host gates pass for bundle launch, main-window AX navigation, overlay above/below/short bubble, mouse interaction, keyboard/AX scaling, scale persistence, daemon recovery and renderer budgets.
  - Fresh isolated screenshots are RGB PNGs; eight baseline/current pairs were combined and visually reviewed at the same viewport/state.
  - Final audit status: 48 `FIXED`, 6 externally bounded `MITIGATED`, 0 `OPEN`, 0 `DEFERRED`; all 12 optimization items are `DONE`.

## Verification rule

All entries have now passed their local acceptance criteria and cross-subsystem gates. Real connector/App Server acceptance was not run without explicit user authorization and is recorded as bounded `MITIGATED`, never as an unverified local `FIXED` claim.
