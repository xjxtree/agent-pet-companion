use crate::runtime_manifest::PETCORE_BUILD_ID;
use crate::{PetCoreError, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

pub const INTERACTION_ATTESTATION_SCHEMA_VERSION: &str = "apc.overlay-interaction-attestation.v1";
pub const INTERACTION_CONTRACT_DIGEST: &str = env!("APC_INTERACTION_CONTRACT_DIGEST");
pub const INTERACTION_ATTESTATION_FILENAME: &str = "interaction-attestation.json";
pub const REQUIRED_INTERACTION_SUITES: [&str; 4] = [
    "OverlayPlacementAuthorityTests",
    "AppStoreOverlaySnapshotTests",
    "OverlayGeometryTests",
    "OverlayDisplayWidthTests",
];
const MAX_INTERACTION_ATTESTATION_BYTES: u64 = 16 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InteractionAttestation {
    pub schema_version: String,
    pub build_id: String,
    pub interaction_contract_digest: String,
    pub passed_suites: Vec<String>,
    pub ok: bool,
}

pub fn validate_current_interaction_attestation() -> Result<Vec<String>> {
    let path = current_interaction_attestation_path()?.ok_or_else(|| {
        PetCoreError::Validation(
            "interaction attestation is required for visual production verification".to_string(),
        )
    })?;
    Ok(
        validate_interaction_attestation(&path, PETCORE_BUILD_ID, INTERACTION_CONTRACT_DIGEST)?
            .passed_suites,
    )
}

pub fn validate_interaction_attestation(
    path: &Path,
    expected_build_id: &str,
    expected_digest: &str,
) -> Result<InteractionAttestation> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        PetCoreError::Validation(format!("interaction attestation cannot be read: {error}"))
    })?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        return Err(PetCoreError::Validation(
            "interaction attestation must be a regular non-symlink file".to_string(),
        ));
    }
    if metadata.len() == 0 || metadata.len() > MAX_INTERACTION_ATTESTATION_BYTES {
        return Err(PetCoreError::Validation(format!(
            "interaction attestation must contain 1..={MAX_INTERACTION_ATTESTATION_BYTES} bytes"
        )));
    }
    let attestation: InteractionAttestation = serde_json::from_slice(&fs::read(path)?)?;
    if attestation.schema_version != INTERACTION_ATTESTATION_SCHEMA_VERSION {
        return Err(PetCoreError::Validation(format!(
            "interaction attestation schema must be {INTERACTION_ATTESTATION_SCHEMA_VERSION}"
        )));
    }
    if !attestation.ok {
        return Err(PetCoreError::Validation(
            "interaction attestation is not successful".to_string(),
        ));
    }
    if attestation.build_id != expected_build_id {
        return Err(PetCoreError::Validation(format!(
            "interaction attestation build_id does not match PetCore build {expected_build_id}"
        )));
    }
    if attestation.interaction_contract_digest != expected_digest {
        return Err(PetCoreError::Validation(
            "interaction attestation contract digest is stale".to_string(),
        ));
    }
    if attestation.passed_suites
        != REQUIRED_INTERACTION_SUITES
            .iter()
            .map(|suite| (*suite).to_string())
            .collect::<Vec<_>>()
    {
        return Err(PetCoreError::Validation(
            "interaction attestation passed_suites is incomplete or not canonical".to_string(),
        ));
    }
    Ok(attestation)
}

fn current_interaction_attestation_path() -> Result<Option<PathBuf>> {
    if let Some(path) = std::env::var_os("APC_INTERACTION_ATTESTATION_PATH") {
        let path = PathBuf::from(path);
        if !path.is_absolute() {
            return Err(PetCoreError::Validation(
                "APC_INTERACTION_ATTESTATION_PATH must be absolute".to_string(),
            ));
        }
        return Ok(Some(path));
    }

    if let Some(manifest_path) = std::env::var_os("APC_EXPECTED_RUNTIME_MANIFEST") {
        let manifest_path = PathBuf::from(manifest_path);
        if let Some(resources) = manifest_path.parent() {
            return Ok(Some(resources.join(INTERACTION_ATTESTATION_FILENAME)));
        }
    }

    let executable = std::env::current_exe()?;
    let Some(bin_dir) = executable.parent() else {
        return Ok(None);
    };
    if bin_dir.file_name().and_then(|name| name.to_str()) != Some("bin") {
        return Ok(None);
    }
    Ok(bin_dir
        .parent()
        .map(|resources| resources.join(INTERACTION_ATTESTATION_FILENAME)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn current_attestation() -> InteractionAttestation {
        InteractionAttestation {
            schema_version: INTERACTION_ATTESTATION_SCHEMA_VERSION.to_string(),
            build_id: PETCORE_BUILD_ID.to_string(),
            interaction_contract_digest: INTERACTION_CONTRACT_DIGEST.to_string(),
            passed_suites: REQUIRED_INTERACTION_SUITES
                .iter()
                .map(|suite| (*suite).to_string())
                .collect(),
            ok: true,
        }
    }

    fn write_attestation(path: &Path, attestation: &InteractionAttestation) {
        fs::write(path, serde_json::to_vec(attestation).unwrap()).unwrap();
    }

    #[test]
    fn current_closed_attestation_is_accepted() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("attestation.json");
        write_attestation(&path, &current_attestation());
        assert_eq!(
            validate_interaction_attestation(&path, PETCORE_BUILD_ID, INTERACTION_CONTRACT_DIGEST)
                .unwrap()
                .passed_suites,
            REQUIRED_INTERACTION_SUITES
        );
    }

    #[test]
    fn unknown_stale_and_incomplete_attestations_fail_closed() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("attestation.json");

        let mut value = serde_json::to_value(current_attestation()).unwrap();
        value["unknown"] = serde_json::json!(true);
        fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(validate_interaction_attestation(
            &path,
            PETCORE_BUILD_ID,
            INTERACTION_CONTRACT_DIGEST
        )
        .is_err());

        for mutation in 0..3 {
            let mut attestation = current_attestation();
            match mutation {
                0 => attestation.build_id = "stale-build".to_string(),
                1 => attestation.interaction_contract_digest = "0".repeat(64),
                2 => {
                    attestation.passed_suites.pop();
                }
                _ => unreachable!(),
            }
            write_attestation(&path, &attestation);
            assert!(validate_interaction_attestation(
                &path,
                PETCORE_BUILD_ID,
                INTERACTION_CONTRACT_DIGEST
            )
            .is_err());
        }
    }
}
