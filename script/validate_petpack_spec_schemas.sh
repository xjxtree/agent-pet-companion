#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apc-petpack-schema-validator.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/src"

cat >"$WORK_DIR/Cargo.toml" <<'TOML'
[package]
name = "apc-petpack-schema-validator"
version = "0.0.0"
edition = "2021"
publish = false

[dependencies]
jsonschema = { version = "=0.33.0", default-features = false }
serde_json = "=1.0.150"
TOML

cat >"$WORK_DIR/src/main.rs" <<'RUST'
use jsonschema::Draft;
use serde_json::Value;
use std::env;
use std::error::Error;
use std::fs;
use std::path::{Path, PathBuf};

fn read_json(path: &Path) -> Result<Value, Box<dyn Error>> {
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}

fn validate_fixture_set(schema_path: &Path, fixture_dir: &Path) -> Result<(), Box<dyn Error>> {
    let schema = read_json(schema_path)?;
    if !jsonschema::meta::is_valid(&schema) {
        return Err(format!("invalid JSON Schema: {}", schema_path.display()).into());
    }

    let validator = jsonschema::options()
        .with_draft(Draft::Draft202012)
        .should_validate_formats(true)
        .build(&schema)?;

    let mut fixtures = fs::read_dir(fixture_dir)?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<Result<Vec<PathBuf>, _>>()?;
    fixtures.sort();

    let mut valid_count = 0usize;
    let mut invalid_count = 0usize;
    for fixture_path in fixtures {
        if fixture_path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        let file_name = fixture_path
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or("fixture filename is not UTF-8")?;
        let expected_valid = if file_name.starts_with("valid-") {
            valid_count += 1;
            true
        } else if file_name.starts_with("invalid-") {
            invalid_count += 1;
            false
        } else {
            continue;
        };

        let instance = read_json(&fixture_path)?;
        let actual_valid = validator.is_valid(&instance);
        if actual_valid != expected_valid {
            let diagnostics = validator
                .iter_errors(&instance)
                .map(|error| error.to_string())
                .collect::<Vec<_>>()
                .join("\n  - ");
            return Err(format!(
                "fixture expectation failed: {} (expected valid={expected_valid}, actual valid={actual_valid}){}",
                fixture_path.display(),
                if diagnostics.is_empty() {
                    String::new()
                } else {
                    format!("\n  - {diagnostics}")
                }
            )
            .into());
        }
    }

    if valid_count == 0 || invalid_count == 0 {
        return Err(format!(
            "{} must contain at least one valid-*.json and one invalid-*.json fixture",
            fixture_dir.display()
        )
        .into());
    }

    println!(
        "ok: {} ({} valid, {} invalid fixtures)",
        schema_path.display(),
        valid_count,
        invalid_count
    );
    Ok(())
}

fn main() -> Result<(), Box<dyn Error>> {
    let args = env::args().skip(1).collect::<Vec<_>>();
    if args.is_empty() || args.len() % 2 != 0 {
        return Err("usage: validator <schema> <fixture-dir> [<schema> <fixture-dir> ...]".into());
    }

    for pair in args.chunks_exact(2) {
        validate_fixture_set(Path::new(&pair[0]), Path::new(&pair[1]))?;
    }
    Ok(())
}
RUST

export CARGO_TARGET_DIR="$ROOT_DIR/target/petpack-spec-schema-validator"

cargo run \
  --manifest-path "$WORK_DIR/Cargo.toml" \
  --offline \
  --quiet \
  -- \
  "$ROOT_DIR/schemas/petpack.schema.json" "$ROOT_DIR/fixtures/schemas/petpack" \
  "$ROOT_DIR/schemas/pet-source.schema.json" "$ROOT_DIR/fixtures/schemas/pet-source" \
  "$ROOT_DIR/schemas/pet-brief.schema.json" "$ROOT_DIR/fixtures/schemas/pet-brief" \
  "$ROOT_DIR/schemas/pet-source-event.schema.json" "$ROOT_DIR/fixtures/schemas/pet-source-event" \
  "$ROOT_DIR/schemas/pet-validation.schema.json" "$ROOT_DIR/fixtures/schemas/pet-validation"

echo "Petpack specification schema validation ok"
