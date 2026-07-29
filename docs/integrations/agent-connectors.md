# Agent Connectors

Agent Pet Companion supports Codex, Claude Code, Pi Coding Agent, and OpenCode through host-native hooks, plugins, or extensions. These adapters emit a small local event contract; they do not turn third-party agents into in-app AI Pet Maker backends. This document owns the current connection and event boundary.

## Integration matrix

| Source | Managed integration | In-app role |
|---|---|---|
| Codex | User-level plugin and hooks using the stable `petcore-cli` adapter | Agent activity plus Codex App Server for AI Pet Maker |
| Claude Code | Managed hook settings fragment invoking `petcore-cli` | Agent activity only |
| Pi Coding Agent | Managed TypeScript extension and portable Skill support | Agent activity only |
| OpenCode | Managed JavaScript plugin and portable Skill support | Agent activity only |

Connector templates live under [plugins](../../plugins/). Installation, repair, verification, receipt freshness, and uninstall behavior live in [connections.rs](../../crates/petcore/src/connections.rs). The App surface is implemented by [AgentConnectionsView](../../apps/macos/Sources/AgentPetCompanion/Views/AgentConnectionsView.swift).

## Event path

```mermaid
flowchart LR
    Host["Agent host event"] --> Adapter["Host-specific adapter"]
    Adapter -->|"allowlisted stdin fields"| CLI["petcore-cli agent hook"]
    CLI -->|"normalized UDS request"| Core["PetCore ingest"]
    Core --> Filter["Bound · redact · deduplicate · suppress"]
    Filter --> DB["Persisted event envelope"]
    DB --> Sessions["Session/activity projection"]
    Sessions --> App["App bubble and pet state"]
```

The normal managed path invokes `runtime/current/petcore-cli`, so a PetCore runtime replacement does not leave connector files pointing to an obsolete version. A token-protected `127.0.0.1` event endpoint is available for adapters that cannot use UDS directly; it enters the same normalization path.

Connections and desktop bubbles are Agent-scoped, not project-scoped. The App does not select a project folder for an Agent connection. Supported events from every project enter the same source/session projection, and each concurrent session can appear in its Agent's message-bubble group. A bounded `project_path` may still be normalized internally as event correlation metadata, but it is not a connection setting, display filter, or user-facing identity.

## Contract layers

1. **Host input** — host-specific payloads are treated as untrusted data. Adapters extract a closed, size-bounded field set rather than forwarding arbitrary JSON.
2. **Normalized ingest** — source, external event identity, session identity, event type, contract version, activity outcome, and explicitly permitted display fields are validated by the CLI/PetCore implementation.
3. **Persisted envelope** — `apc.agent-event.v1` stores typed, size-bounded fields and a normalized session key. The database unique key makes retrying a host event idempotent.
4. **Derived display state** — PetCore applies leases, source/event enablement, session suppression, grouping, and priority. Swift consumes the projection; it does not reimplement connector semantics.

Relevant sources are [CLI adapters](../../crates/petcore-cli/src/main.rs), [adapter contracts](../../crates/petcore/src/adapter_contracts.rs), [event envelope](../../crates/petcore/src/event_envelope.rs), [Agent state projection](../../crates/petcore/src/agent_state.rs), [raw hook schema](../../schemas/agent-hook-input.schema.json), and [persisted event schema](../../schemas/agent-event.schema.json). If schema, runtime allowlist, and fixtures disagree, synchronize them in the same change; do not choose a convenient version in documentation.

## Connection operations

The App exposes Agent-scoped operations:

- **Check** inspects expected CLI availability and managed artifacts without reading credentials.
- **Repair** installs or updates the App-managed hook/plugin/extension files for that Agent.
- **Test** emits a diagnostic event through the current local runtime.
- **Uninstall** removes only App-managed integration artifacts.

The managed runtime lifecycle separately refreshes installed references after
the user replaces the App. It refreshes only integrations already attributable
to Agent Pet Companion; it does not silently connect a previously unmanaged
Agent. Refresh returns typed per-Agent results, so one failed host becomes
**Needs Update** without blocking healthy Agents or the core App.

The page presents the four Agents as a single-selection accordion. A collapsed
row shows only identity, a short connection summary, and local integration
health: **Not Checked**, **Checking**, **Connected**, **Needs Repair**, or
**Unavailable**. Selecting the whole row opens that Agent and closes the
previous one. The open row adds the independent real-task state—**Not
Verified**, **Waiting for a Real Task**, or **Verified with a Real Task**—plus
only actionable guidance and controls. A healthy local adapter never implies
that a provider task has run, and missing real-task evidence never makes the
local integration unhealthy.

The page keeps **Check All** prominent and keeps a typed **Set Up or Repair
All** entry whenever at least one managed connector can be safely installed or
reapplied, including after a successful repair. An expanded Agent shows at most
one action required by its current state—**Check Connection**, **Set Up or
Repair**, or **Retry**—plus one **More** menu. Routine rechecks for an already
connected Agent, **Send Test Message**, safe managed reconfiguration, and
removal live in that menu according to explicit capabilities; removal remains
destructive and confirmed. Each expanded Agent also lists only the plugin,
connector, extension, or bundled Skills owned by Agent Pet Companion, with the
component name, user-facing kind, current check status, and verified active
release version. Codex uses the independent version from its bundled plugin
manifest. The Claude Code fragment, Pi extension, and OpenCode plugin instead
carry the App/PetCore release version that rendered them; PetCore reads that
marker only from an owned regular file and still requires the complete artifact
set to match the current templates exactly. When an active release version
differs from the version shipped with the current App, the row names both the
installed and App-required versions. A legacy owned artifact without a release
marker names only the required version. Both states direct the user to the
existing setup/repair action. Typed support checks still decide status and
mutation authority, but CLI names, runtime terminology, internal contract
identities, exact-content evidence, and managed-location counts are not
rendered in the ordinary connection card.
An unavailable Agent receives a short user-facing install, update, settings,
restart, repair, or service-recovery instruction derived from those typed
checks. Project directories, App/PetCore runtime details, renderer state, and
diagnostics export do not belong on this page. Service state and archive export
live under **Service & Diagnostics**.

Check, test, repair, and uninstall share a typed App coordinator and a
serialized PetCore mutation gate. A running operation disables conflicting
actions but never disables opening or switching Agent rows; the active row
shows visible progress, and failures remain inline with an explicit retry path.
The lightweight connection test uses a dedicated three-second transport bound
and completes from its RPC result without waiting for an unrelated full state
refresh.

PetCore returns typed check items and explicit management capabilities: `repairable_connector_issue`, `can_repair_managed_connector`, `managed_path_conflict`, and `can_uninstall_managed_connector`. `repairable_connector_issue` authorizes issue-specific **Connect/Repair** presentation; `can_repair_managed_connector` independently keeps the safe managed install/reapply entry available after that issue clears. The App never infers repair or uninstall authority from display text. **Needs Repair** is projected only when an executable typed repair authority is present; a failed check without that authority is **Unavailable**. Missing capability data denies mutation. Current check items use stable presentation codes and only `confirm_managed_repair`, `test_channel`, or `recheck` recovery actions. `project_directory` and `choose_project_directory` are decode-only compatibility values: PetCore does not emit or reproject them, and the App never presents or executes them.

A current light snapshot may authorize only an explicitly typed managed
installation or repair. It cannot claim **Healthy** or **Verified**, and policy
restrictions, missing Agent/runtime dependencies, unknown checks, and managed
path conflicts still deny mutation. A full runtime check remains required for
healthy integration and real-task verification presentation.

PetCore distinguishes ordinary, diagnostic, and full-task receipts against the
current connector contract and install time. **Send Test Message** proves only
that the desktop pet can receive the App's local test message, while real Agent
verification requires a qualifying event from an actual provider task. A test
message does not prove provider authentication, model execution, or completion
of a real Agent task. Every single-Agent operation produces a persistent,
dismissible success or failure notice in that Agent section, so test messages
and managed writes have visible feedback.

The internal support projection remains bounded and typed. Agent-version
evidence contains only the detected semantic version and closed supported set;
Codex host verification may contain bounded disabled, modified, and untrusted
hook counts. The `managed_components` projection identifies only App-owned
connector and Skill components, their expected and active release version, and
an exact-content boolean. The component-version fields use only the independent
Codex bundle version or the App release embedded in the three static
connectors; compatibility contract identities remain in the separate internal
capability contract. The expanded Agent renders only each safe name, kind,
user-facing release version, and derived status. A mismatch additionally
renders the safe App-required release version; internal contract identities and
exact-content evidence stay internal. The projection never exposes a digest or
path. User-managed plugins, extensions, packages, and Skills are neither
scanned nor shown. Arbitrary diagnostic prose, paths, identifiers, and
credential-like values never cross into ordinary or accessibility presentation.

Runtime version checks fail closed outside the protocol surfaces audited by the
current connector: Codex accepts only `0.144.5`, `0.145.0-alpha.18`, and the
ChatGPT-bundled `0.146.0-alpha.3.1`; Claude Code accepts
`2.1.212`–`2.1.215`; Pi requires exactly `0.80.10`; and OpenCode accepts
`1.18.0`–`1.18.4`. The Codex `0.146.0-alpha.3.1` App Server notification schema
is an exact 70-method match to the recorded inventory, and the OpenCode
`1.18.4` plugin hook plus v1/v2 event inventories are exact matches to the
managed adapter. Pi `0.79.x` is intentionally not treated as compatible:
although it has the older task lifecycle events, its ExtensionAPI does not
expose the required `session_info_changed` and `agent_settled` boundaries.

Agent rows and the other shared disclosure cards use a full-width header button
with expanded/collapsed accessibility state. The complete rounded header area
toggles the section; controls inside expanded content remain independently
interactive.

The desktop bubble keeps the same Agent → session boundary but exposes only the
bounded daily return path: one attention-prioritized/latest row while
collapsed, and every concrete session already present in the bounded PetCore
snapshot while expanded. The whole session row is the navigation target; a
chevron is visual hover/focus affordance rather than repeated action copy. The
row status names the exact fixed lifecycle action presented by the pet, and its
detail keeps the closed safe activity summary visible alongside a distinct
current-turn Agent message.

## Security and privacy boundary

- Never read or export Agent auth, token, cookie, API key, or secret files.
- Do not forward arbitrary command/tool payloads, hidden reasoning, complete transcript archives, arbitrary environment variables, or unbounded host payloads as event structure.
- Explicit, bounded session titles plus first/latest user and latest assistant display messages are product data and remain available to the desktop bubble. Each Agent connector forwards later generated-title metadata without inventing activity; PetCore uses the first user message only until that explicit title arrives.
- Project paths and session IDs are normalized for local correlation and removed or redacted from diagnostics.
- Internal Codex suggestion/Pet Studio sessions are suppressed from ordinary desktop activity.
- Connector files must be attributable to Agent Pet Companion, updated atomically, and removed without changing unrelated user configuration or projects.
- UDS and loopback ingress are local-only. Loopback access requires the App-managed capability token.

The provider-neutral [agent-pet-maker Skill](../../skills/agent-pet-maker/) can create or modify a `.petpack` in another image-capable Agent host. That workflow remains outside the in-app AI Pet Maker. Import and activation require explicit user actions, and the package still crosses the standard PetCore validator.

### Codex plugin and Skill convergence

Codex receives one App-managed plugin bundle containing its hook plus the
internal `agent-pet-studio` and portable `agent-pet-maker` Skills. There is no
separate standalone Codex Skill installation. The repository plugin manifest
owns a strict `X.Y.Z` version; CI and release validation require that version
to increase whenever any of the plugin, Studio Skill, or Maker Skill content
changes.

Repair and post-App-update refresh atomically publish the complete owned source,
invoke Codex's plugin installation path, and verify the expected manifest
version and content against the active Codex plugin state. A marketplace source
write and installed/enabled flags do not prove convergence when Codex still
loads an older versioned cache. A stale or unverifiable active cache remains a
typed repairable condition and cannot project `connected`.

In-app Maker work uses the internal Studio Skill; portable user-invoked work
uses the Maker Skill. They ship together but remain separate behavioral
contracts. A running generation retains the version with which it started, and
new work begins only with the newly verified capability.

## Adding or changing a connector

1. Add a typed host adapter and a versioned connector contract.
2. Restrict raw input to an explicit allowlist with size limits and negative security fixtures.
3. Normalize into the shared source/event/session model; do not add host-specific UI parsing.
4. Implement Agent-scoped check, repair, refresh, test, receipt, and uninstall behavior for App-managed artifacts.
5. Point managed commands at `runtime/current/petcore-cli` and preserve local-only transport.
6. Add simulated contract tests and keep real-host validation behind the explicit gate in [Validation profiles](../development/validation.md).
7. When the Codex plugin or either bundled Skill changes, increase
   `plugins/codex/.codex-plugin/plugin.json` and run
   `validate_codex_plugin_version.py` against the intended base.
8. Update the runtime manifest, this document, public feature list, and root changelog if the supported user surface changes.
