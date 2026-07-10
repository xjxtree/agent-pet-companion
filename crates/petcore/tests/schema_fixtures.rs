use jsonschema::{Draft, Validator};
use petcore::enum_from_name;
use petcore::event_envelope::NormalizedAgentEvent;
use petcore_types::AgentSource;
use serde_json::Value;
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
        .build(&schema)
        .unwrap_or_else(|error| panic!("failed to compile {}: {error}", schema_path.display()))
}

#[test]
fn petpack_schema_accepts_and_rejects_executable_fixtures() {
    validate_fixture_group("petpack.schema.json", "petpack");
}

#[test]
fn agent_event_schema_accepts_and_rejects_executable_fixtures() {
    validate_fixture_group("agent-hook-input.schema.json", "agent-hook-input");
    validate_fixture_group("agent-event-ingest.schema.json", "agent-event-ingest");
    validate_fixture_group("agent-event.schema.json", "agent-event-persisted");
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
