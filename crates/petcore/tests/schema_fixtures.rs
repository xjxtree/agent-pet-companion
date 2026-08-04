use jsonschema::{
    paths::{LazyLocation, Location},
    Draft, Keyword, ValidationError, Validator,
};
use petcore::enum_from_name;
use petcore::event_envelope::NormalizedAgentEvent;
use petcore_types::AgentSource;
use serde_json::{json, Map, Value};
use std::fs;
use std::path::{Path, PathBuf};

fn workspace_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("workspace root")
}

fn read_json(path: &Path) -> Value {
    serde_json::from_slice(
        &fs::read(path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display())),
    )
    .unwrap_or_else(|error| panic!("invalid JSON in {}: {error}", path.display()))
}

#[derive(Debug)]
struct MaxUtf8BytesValidator {
    maximum: usize,
}

impl Keyword for MaxUtf8BytesValidator {
    fn validate<'i>(
        &self,
        instance: &'i Value,
        location: &LazyLocation,
    ) -> Result<(), ValidationError<'i>> {
        if self.is_valid(instance) {
            return Ok(());
        }
        Err(ValidationError::custom(
            Location::new(),
            location.into(),
            instance,
            format!("string exceeds {} UTF-8 bytes", self.maximum),
        ))
    }

    fn is_valid(&self, instance: &Value) -> bool {
        instance
            .as_str()
            .is_none_or(|value| value.len() <= self.maximum)
    }
}

#[allow(clippy::result_large_err)] // Signature is fixed by jsonschema's custom-keyword API.
fn max_utf8_bytes_validator_factory<'a>(
    _parent: &'a Map<String, Value>,
    value: &'a Value,
    path: Location,
) -> Result<Box<dyn Keyword>, ValidationError<'a>> {
    let maximum = value
        .as_u64()
        .and_then(|value| usize::try_from(value).ok())
        .ok_or_else(|| {
            ValidationError::custom(
                Location::new(),
                path,
                value,
                "x-maxUtf8Bytes must be a non-negative integer",
            )
        })?;
    Ok(Box::new(MaxUtf8BytesValidator { maximum }))
}

fn validate_fixture_group(schema_name: &str, fixture_dir: &str) {
    let root = workspace_root();
    let schema_path = root.join("schemas").join(schema_name);
    let schema = read_json(&schema_path);
    assert!(
        jsonschema::meta::is_valid(&schema),
        "{} is not a valid JSON Schema",
        schema_path.display()
    );
    let validator = Validator::options()
        .with_draft(Draft::Draft202012)
        .should_validate_formats(true)
        .with_keyword("x-maxUtf8Bytes", max_utf8_bytes_validator_factory)
        .build(&schema)
        .unwrap_or_else(|error| panic!("failed to compile {}: {error}", schema_path.display()));

    let fixtures_path = root.join("fixtures/schemas").join(fixture_dir);
    let mut fixtures = fs::read_dir(&fixtures_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", fixtures_path.display()))
        .map(|entry| entry.expect("fixture entry").path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "json")
        })
        .collect::<Vec<_>>();
    fixtures.sort();
    assert!(
        fixtures.iter().any(|path| {
            path.file_name()
                .is_some_and(|name| name.to_string_lossy().starts_with("valid-"))
        }),
        "{fixture_dir} needs at least one valid fixture"
    );
    assert!(
        fixtures.iter().any(|path| {
            path.file_name()
                .is_some_and(|name| name.to_string_lossy().starts_with("invalid-"))
        }),
        "{fixture_dir} needs at least one invalid fixture"
    );

    for path in fixtures {
        let name = path.file_name().unwrap().to_string_lossy();
        let instance = read_json(&path);
        let is_valid = validator.is_valid(&instance);
        if name.starts_with("valid-") {
            assert!(is_valid, "expected valid fixture: {}", path.display());
        } else if name.starts_with("invalid-") {
            assert!(!is_valid, "expected invalid fixture: {}", path.display());
        } else {
            panic!(
                "schema fixture must start with valid- or invalid-: {}",
                path.display()
            );
        }
    }
}

fn compiled_schema(schema_name: &str) -> Validator {
    let schema_path = workspace_root().join("schemas").join(schema_name);
    let schema = read_json(&schema_path);
    Validator::options()
        .with_draft(Draft::Draft202012)
        .should_validate_formats(true)
        .with_keyword("x-maxUtf8Bytes", max_utf8_bytes_validator_factory)
        .build(&schema)
        .unwrap_or_else(|error| panic!("failed to compile {}: {error}", schema_path.display()))
}

#[test]
fn petpack_schema_accepts_and_rejects_executable_fixtures() {
    validate_fixture_group("petpack.schema.json", "petpack");

    let root = workspace_root();
    let schema = compiled_schema("petpack.schema.json");
    let mut high = read_json(&root.join("fixtures/schemas/petpack/valid-standard.json"));
    high["quality"] = json!("high");
    high["render_size"] = json!({ "width": 576, "height": 624 });
    assert!(
        schema.is_valid(&high),
        "petpack schema rejected the high 576x624 tier"
    );
}

#[test]
fn producer_metadata_schemas_accept_and_reject_executable_fixtures() {
    validate_fixture_group("pet-brief.schema.json", "pet-brief");
    validate_fixture_group("pet-source.schema.json", "pet-source");
    validate_fixture_group("pet-source-event.schema.json", "pet-source-event");
    validate_fixture_group("pet-validation.schema.json", "pet-validation");
}

#[test]
fn producer_playback_modes_are_closed_by_mode() {
    let root = workspace_root();
    let producers = [
        (
            "pet-brief.schema.json",
            "pet-brief/valid-standard.json",
            "/states/0/playback",
        ),
        (
            "pet-source.schema.json",
            "pet-source/valid-external-agent.json",
            "/states/0/playback",
        ),
        (
            "pet-source-event.schema.json",
            "pet-source-event/valid-rendered.json",
            "/state_timings/0/playback",
        ),
        (
            "pet-validation.schema.json",
            "pet-validation/valid-runtime.json",
            "/states/0/playback",
        ),
    ];
    let valid_playback = [
        ("loop", json!({ "mode": "loop" })),
        (
            "periodic",
            json!({ "mode": "periodic", "cooldown_ms": [4000, 8000] }),
        ),
        (
            "burst_then_settle",
            json!({
                "mode": "burst_then_settle",
                "entry_repeat_count": 1,
                "settle_frame_index": 1
            }),
        ),
        (
            "burst_then_idle",
            json!({
                "mode": "burst_then_idle",
                "entry_repeat_count": 3
            }),
        ),
        ("once_then_return", json!({ "mode": "once_then_return" })),
    ];
    let invalid_playback = [
        (
            "loop with entry_repeat_count",
            json!({ "mode": "loop", "entry_repeat_count": 1 }),
        ),
        (
            "loop with settle_frame_index",
            json!({ "mode": "loop", "settle_frame_index": 1 }),
        ),
        (
            "loop with cooldown_ms",
            json!({ "mode": "loop", "cooldown_ms": [4000, 8000] }),
        ),
        (
            "retired once_hold",
            json!({ "mode": "once_hold", "settle_frame_index": 1 }),
        ),
        ("periodic without cooldown", json!({ "mode": "periodic" })),
        (
            "periodic with entry_repeat_count",
            json!({
                "mode": "periodic",
                "cooldown_ms": [4000, 8000],
                "entry_repeat_count": 1
            }),
        ),
        (
            "periodic with settle_frame_index",
            json!({
                "mode": "periodic",
                "cooldown_ms": [4000, 8000],
                "settle_frame_index": 1
            }),
        ),
        (
            "burst_then_settle without repeat",
            json!({ "mode": "burst_then_settle", "settle_frame_index": 1 }),
        ),
        (
            "burst_then_settle without settle",
            json!({ "mode": "burst_then_settle", "entry_repeat_count": 1 }),
        ),
        (
            "burst_then_settle with cooldown_ms",
            json!({
                "mode": "burst_then_settle",
                "entry_repeat_count": 1,
                "settle_frame_index": 1,
                "cooldown_ms": [4000, 8000]
            }),
        ),
        (
            "burst_then_idle without repeat",
            json!({ "mode": "burst_then_idle" }),
        ),
        (
            "burst_then_idle with settle",
            json!({
                "mode": "burst_then_idle",
                "entry_repeat_count": 3,
                "settle_frame_index": 1
            }),
        ),
        (
            "once_then_return with repeat",
            json!({ "mode": "once_then_return", "entry_repeat_count": 1 }),
        ),
    ];

    for (schema_name, fixture_name, playback_pointer) in producers {
        let validator = compiled_schema(schema_name);
        let fixture = read_json(&root.join("fixtures/schemas").join(fixture_name));
        for (case, playback) in &valid_playback {
            let mut instance = fixture.clone();
            *instance.pointer_mut(playback_pointer).unwrap() = playback.clone();
            assert!(
                validator.is_valid(&instance),
                "{schema_name} rejected valid {case} playback"
            );
        }
        for (case, playback) in &invalid_playback {
            let mut instance = fixture.clone();
            *instance.pointer_mut(playback_pointer).unwrap() = playback.clone();
            assert!(
                !validator.is_valid(&instance),
                "{schema_name} accepted {case} playback"
            );
        }
    }
}

#[test]
fn producer_render_sizes_are_exact_quality_pairs() {
    let root = workspace_root();
    let brief_schema = compiled_schema("pet-brief.schema.json");
    let brief = read_json(&root.join("fixtures/schemas/pet-brief/valid-standard.json"));
    for (quality, width, height) in [
        ("low", 192, 208),
        ("standard", 384, 416),
        ("high", 576, 624),
    ] {
        let mut instance = brief.clone();
        instance["quality"] = json!(quality);
        instance["runtime"]["render_size"] = json!({ "width": width, "height": height });
        assert!(
            brief_schema.is_valid(&instance),
            "pet brief rejected {quality} {width}x{height}"
        );
    }
    for (quality, width, height) in [
        ("low", 192, 624),
        ("standard", 384, 208),
        ("high", 384, 416),
    ] {
        let mut instance = brief.clone();
        instance["quality"] = json!(quality);
        instance["runtime"]["render_size"] = json!({ "width": width, "height": height });
        assert!(
            !brief_schema.is_valid(&instance),
            "pet brief accepted invalid {quality} {width}x{height}"
        );
    }

    let source_schema = compiled_schema("pet-source.schema.json");
    let source = read_json(&root.join("fixtures/schemas/pet-source/valid-external-agent.json"));
    for quality_pointer in ["/quality", "/form/quality"] {
        let mut low = source.clone();
        *low.pointer_mut(quality_pointer).unwrap() = json!("low");
        assert!(
            source_schema.is_valid(&low),
            "pet source rejected low at {quality_pointer}"
        );

        let mut high = source.clone();
        *high.pointer_mut(quality_pointer).unwrap() = json!("high");
        assert!(
            source_schema.is_valid(&high),
            "pet source rejected high at {quality_pointer}"
        );
    }

    let event_schema = compiled_schema("pet-source-event.schema.json");
    let event = read_json(&root.join("fixtures/schemas/pet-source-event/valid-rendered.json"));
    for (quality, width, height) in [
        ("low", 192, 208),
        ("standard", 384, 416),
        ("high", 576, 624),
    ] {
        let mut instance = event.clone();
        instance["quality"] = json!(quality);
        instance["render_size"] = json!({ "width": width, "height": height });
        assert!(
            event_schema.is_valid(&instance),
            "pet source event rejected {quality} {width}x{height}"
        );
    }
    for (quality, width, height) in [
        ("low", 192, 624),
        ("standard", 192, 208),
        ("high", 384, 416),
    ] {
        let mut instance = event.clone();
        instance["quality"] = json!(quality);
        instance["render_size"] = json!({ "width": width, "height": height });
        assert!(
            !event_schema.is_valid(&instance),
            "pet source event accepted invalid {quality} {width}x{height}"
        );
    }
}

#[test]
fn agent_event_schema_accepts_and_rejects_executable_fixtures() {
    validate_fixture_group("agent-hook-input.schema.json", "agent-hook-input");
    validate_fixture_group("agent-event-ingest.schema.json", "agent-event-ingest");
    validate_fixture_group("agent-event.schema.json", "agent-event-persisted");
}

#[test]
fn strict_ingest_schema_accepts_the_complete_cli_envelope() {
    let ingest_schema = compiled_schema("agent-event-ingest.schema.json");
    let persisted_schema = compiled_schema("agent-event.schema.json");
    let cli_request = json!({
        "id": "evt_cli_contract",
        "source": "claude_code",
        "project_path": null,
        "session_id": "cli-contract-session",
        "event_type": "start",
        "title": "开始处理",
        "detail": null,
        "payload_json": {
            "schema_version": "apc.agent-event.v1",
            "external_event_id": "evt_cli_contract",
            "source_event": "UserPromptSubmit",
            "contract_version": "claude-hooks-current",
            "tool_name": null,
            "outcome": "started",
            "diagnostic": false,
            "affects_activity": true,
            "turn_id": null,
            "session_active": true,
            "message_role": "user",
            "message_content": "真实 CLI 归一化消息",
            "activity_kind": "thinking",
            "activity_content": null,
            "interaction_kind": null,
            "project_label": "agent-pet-companion",
            "session_title": "CLI session",
            "session_open": true,
            "session_surface": null,
            "terminal_app": null,
            "session_open_url": null
        },
        "created_at": "2026-07-10T00:00:00Z"
    });

    assert!(
        ingest_schema.is_valid(&cli_request),
        "the strict ingest schema must accept every field emitted by normalized_contract_request"
    );
    let normalized = NormalizedAgentEvent::from_external(
        AgentSource::ClaudeCode,
        cli_request,
        "2026-07-10T00:00:00Z",
    )
    .expect("the runtime must accept the same complete CLI envelope");
    let persisted = serde_json::to_value(normalized).unwrap();
    assert!(
        persisted_schema.is_valid(&persisted),
        "the persisted schema must accept the normalized CLI envelope: {persisted}"
    );
}

#[test]
fn event_schemas_and_runtime_enforce_the_same_utf8_byte_limits() {
    let ingest_schema = compiled_schema("agent-event-ingest.schema.json");
    let persisted_schema = compiled_schema("agent-event.schema.json");

    for (index, key, maximum, exact, oversized) in [
        (
            0,
            "project_label",
            128,
            format!("{}ab", "界".repeat(42)),
            format!("{}abc", "界".repeat(42)),
        ),
        (
            1,
            "session_title",
            160,
            format!("{}a", "界".repeat(53)),
            format!("{}ab", "界".repeat(53)),
        ),
        (
            2,
            "message_content",
            4_096,
            format!("{}a", "界".repeat(1_365)),
            format!("{}ab", "界".repeat(1_365)),
        ),
        (
            3,
            "contract_version",
            128,
            format!("{}ab", "界".repeat(42)),
            format!("{}abc", "界".repeat(42)),
        ),
    ] {
        assert_eq!(exact.len(), maximum);
        assert_eq!(oversized.len(), maximum + 1);
        assert!(
            oversized.chars().count() < maximum,
            "the custom keyword, not maxLength, must reject {key}"
        );

        let request = |value: String| {
            let mut payload = json!({
                "schema_version": "apc.agent-event.v1",
                "external_event_id": format!("utf8-boundary-{index}"),
                "source_event": "UserPromptSubmit",
                "contract_version": "codex-hooks-current",
                "diagnostic": false,
                "affects_activity": true,
                "session_active": true
            });
            payload[key] = Value::String(value);
            json!({
                "id": format!("utf8-boundary-{index}"),
                "source": "codex",
                "project_path": null,
                "session_id": "utf8-boundary-session",
                "event_type": "start",
                "title": "compatibility-only",
                "detail": null,
                "payload": payload,
                "created_at": "2026-07-10T00:00:00Z"
            })
        };

        let exact_request = request(exact);
        assert!(
            ingest_schema.is_valid(&exact_request),
            "ingest schema rejected exact {maximum}-byte {key}"
        );
        let normalized = NormalizedAgentEvent::from_external(
            AgentSource::Codex,
            exact_request,
            "2026-07-10T00:00:00Z",
        )
        .unwrap_or_else(|error| panic!("runtime rejected exact {maximum}-byte {key}: {error}"));
        let persisted = serde_json::to_value(normalized).unwrap();
        assert!(
            persisted_schema.is_valid(&persisted),
            "persisted schema rejected exact {maximum}-byte {key}: {persisted}"
        );

        let oversized_request = request(oversized);
        assert!(
            !ingest_schema.is_valid(&oversized_request),
            "ingest schema accepted {key} above {maximum} UTF-8 bytes"
        );
        let error = NormalizedAgentEvent::from_external(
            AgentSource::Codex,
            oversized_request,
            "2026-07-10T00:00:00Z",
        )
        .expect_err("runtime must reject the same oversized value")
        .to_string();
        assert!(
            error.contains(&format!(
                "agent event payload {key} exceeds {maximum} UTF-8 bytes"
            )),
            "{error}"
        );
    }

    let exact_created_at = format!("{}ab", "界".repeat(42));
    let oversized_created_at = format!("{exact_created_at}c");
    assert_eq!(exact_created_at.len(), 128);
    assert_eq!(oversized_created_at.len(), 129);
    assert!(oversized_created_at.chars().count() < 128);
    let request = |created_at: &str| {
        json!({
            "id": "utf8-created-at-boundary",
            "source": "codex",
            "event_type": "start",
            "created_at": created_at
        })
    };
    let exact_request = request(&exact_created_at);
    assert!(
        ingest_schema.is_valid(&exact_request),
        "ingest schema rejected an exact 128-byte created_at"
    );
    NormalizedAgentEvent::from_external(AgentSource::Codex, exact_request, "2026-07-10T00:00:00Z")
        .expect("runtime rejected an exact 128-byte created_at");
    let oversized_request = request(&oversized_created_at);
    assert!(
        !ingest_schema.is_valid(&oversized_request),
        "custom byte validation must reject a 129-byte created_at"
    );
    assert!(NormalizedAgentEvent::from_external(
        AgentSource::Codex,
        oversized_request,
        "2026-07-10T00:00:00Z",
    )
    .expect_err("runtime must reject a 129-byte created_at")
    .to_string()
    .contains("agent event created_at exceeds 128 UTF-8 bytes"));
}

#[test]
fn event_id_aliases_are_independently_nonblank_and_byte_bounded() {
    let ingest_schema = compiled_schema("agent-event-ingest.schema.json");
    let exact_payload_id = format!("{}a", "界".repeat(85));
    let oversized_payload_id = format!("{exact_payload_id}b");
    assert_eq!(exact_payload_id.len(), 256);
    assert_eq!(oversized_payload_id.len(), 257);
    assert!(oversized_payload_id.chars().count() < 256);

    let request = |top_level_id: &str, payload_id: &str| {
        json!({
            "id": top_level_id,
            "source": "codex",
            "event_type": "tool",
            "payload": {
                "external_event_id": payload_id,
                "source_event": "PreToolUse",
                "diagnostic": false
            }
        })
    };

    let exact = request("top-level-id", &exact_payload_id);
    assert!(ingest_schema.is_valid(&exact));
    NormalizedAgentEvent::from_external(AgentSource::Codex, exact, "2026-07-10T00:00:00Z")
        .expect("both independently valid aliases must be accepted");

    for (name, invalid) in [
        (
            "oversized payload alias",
            request("top-level-id", &oversized_payload_id),
        ),
        ("blank payload alias", request("top-level-id", " \t ")),
        ("blank top-level alias", request(" \t ", "payload-id")),
    ] {
        assert!(!ingest_schema.is_valid(&invalid), "schema accepted {name}");
        assert!(
            NormalizedAgentEvent::from_external(
                AgentSource::Codex,
                invalid,
                "2026-07-10T00:00:00Z",
            )
            .is_err(),
            "runtime accepted {name}"
        );
    }
}

#[test]
fn session_open_url_is_canonical_in_both_schema_and_runtime() {
    let ingest_schema = compiled_schema("agent-event-ingest.schema.json");
    let canonical = "warppreview://session/A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4";
    let request = |url: &str| {
        json!({
            "id": "canonical-session-url",
            "source": "codex",
            "event_type": "start",
            "payload": {
                "source_event": "UserPromptSubmit",
                "session_open_url": url
            }
        })
    };

    let canonical_request = request(canonical);
    assert!(ingest_schema.is_valid(&canonical_request));
    NormalizedAgentEvent::from_external(
        AgentSource::Codex,
        canonical_request,
        "2026-07-10T00:00:00Z",
    )
    .expect("canonical Warp URLs must remain accepted");

    for noncanonical in [format!(" {canonical}"), format!("{canonical} ")] {
        let request = request(&noncanonical);
        assert!(
            !ingest_schema.is_valid(&request),
            "schema accepted a whitespace-padded session URL"
        );
        assert!(
            NormalizedAgentEvent::from_external(
                AgentSource::Codex,
                request,
                "2026-07-10T00:00:00Z",
            )
            .is_err(),
            "runtime accepted a whitespace-padded session URL"
        );
    }
}

#[test]
fn agent_app_and_cli_session_surfaces_are_closed_in_schema_and_runtime() {
    let ingest_schema = compiled_schema("agent-event-ingest.schema.json");
    let persisted_schema = compiled_schema("agent-event.schema.json");

    for (index, surface) in [
        "chatgpt_app",
        "claude_app",
        "opencode_app",
        "cli_terminal",
        "unknown",
    ]
    .into_iter()
    .enumerate()
    {
        let request = json!({
            "id": format!("session-surface-{index}"),
            "source": "codex",
            "event_type": "start",
            "payload": {
                "source_event": "UserPromptSubmit",
                "session_surface": surface
            }
        });
        assert!(
            ingest_schema.is_valid(&request),
            "ingest schema rejected {surface}"
        );
        let event = NormalizedAgentEvent::from_external(
            AgentSource::Codex,
            request,
            "2026-07-10T00:00:00Z",
        )
        .unwrap_or_else(|error| panic!("runtime rejected {surface}: {error}"));
        assert_eq!(event.payload_json["session_surface"], surface);
        assert!(
            persisted_schema.is_valid(&serde_json::to_value(event).unwrap()),
            "persisted schema rejected {surface}"
        );
    }

    let unsupported = json!({
        "id": "session-surface-unsupported",
        "source": "codex",
        "event_type": "start",
        "payload": {
            "source_event": "UserPromptSubmit",
            "session_surface": "desktop_app"
        }
    });
    assert!(!ingest_schema.is_valid(&unsupported));
    assert!(NormalizedAgentEvent::from_external(
        AgentSource::Codex,
        unsupported,
        "2026-07-10T00:00:00Z",
    )
    .is_err());
}

#[test]
fn strict_ingest_schema_and_runtime_normalizer_agree_bidirectionally() {
    let root = workspace_root();
    let ingest_schema = compiled_schema("agent-event-ingest.schema.json");
    let persisted_schema = compiled_schema("agent-event.schema.json");
    let fixture_dir = root.join("fixtures/schemas/agent-event-ingest");
    let mut fixtures = fs::read_dir(&fixture_dir)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "json")
        })
        .collect::<Vec<_>>();
    fixtures.sort();

    for path in fixtures {
        let instance = read_json(&path);
        let schema_accepts = ingest_schema.is_valid(&instance);
        let runtime_result = instance
            .get("source")
            .and_then(Value::as_str)
            .and_then(|source| enum_from_name::<AgentSource>(source).ok())
            .map(|source| {
                NormalizedAgentEvent::from_external(
                    source,
                    instance.clone(),
                    "2026-07-10T00:00:00Z",
                )
            });
        let runtime_accepts = runtime_result.as_ref().is_some_and(|result| result.is_ok());
        let runtime_error = runtime_result
            .as_ref()
            .and_then(|result| result.as_ref().err())
            .map(ToString::to_string);

        assert_eq!(
            schema_accepts,
            runtime_accepts,
            "schema/runtime disagreement for {}: {:?}",
            path.display(),
            runtime_error
        );

        if let Some(Ok(normalized)) = runtime_result {
            let normalized = serde_json::to_value(normalized).unwrap();
            assert!(
                persisted_schema.is_valid(&normalized),
                "normalizer emitted a record rejected by persisted schema for {}: {normalized}",
                path.display()
            );
        }
    }
}
