use crate::adapter_contracts::{
    CLAUDE_HOOKS_CONTRACT_VERSION, CODEX_HOOKS_CONTRACT_VERSION, OPENCODE_CONTRACT_VERSION,
    PI_EXTENSION_CONTRACT_VERSION,
};
use crate::db::DATABASE_SCHEMA_VERSION;
use crate::event_envelope::EVENT_ENVELOPE_SCHEMA_VERSION;
use crate::{PetCoreError, Result};
use petcore_types::PETPACK_SCHEMA_VERSION;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;

pub const RUNTIME_MANIFEST_SCHEMA_VERSION: &str = "apc.runtime-manifest.v1";
pub const PETCORE_RPC_PROTOCOL_VERSION: &str = "apc.petcore-rpc.v2";
pub const PETCORE_BUILD_ID: &str = match option_env!("APC_BUILD_ID") {
    Some(value) => value,
    None => env!("CARGO_PKG_VERSION"),
};
const APP_VERSION: &str = match option_env!("APC_APP_VERSION") {
    Some(value) => value,
    None => env!("CARGO_PKG_VERSION"),
};
const APP_BUILD: &str = match option_env!("APC_APP_BUILD") {
    Some(value) => value,
    None => "0",
};
const RELEASE_CHANNEL: &str = match option_env!("APC_RELEASE_CHANNEL") {
    Some(value) => value,
    None => "develop",
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConnectorContracts {
    pub codex: String,
    pub claude_code: String,
    pub pi: String,
    pub opencode: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RuntimeReleaseManifest {
    pub schema_version: String,
    pub release_channel: String,
    pub app_version: String,
    pub app_build: String,
    pub build_id: String,
    pub petcore_rpc_protocol: String,
    pub petcore_build_id: String,
    pub petcore_cli_build_id: String,
    pub minimum_database_schema_version: u32,
    pub maximum_database_schema_version: u32,
    pub agent_event_schema_version: String,
    pub petpack_schema_version: String,
    pub connector_contracts: ConnectorContracts,
}

impl RuntimeReleaseManifest {
    pub fn compiled() -> Self {
        Self {
            schema_version: RUNTIME_MANIFEST_SCHEMA_VERSION.to_string(),
            release_channel: RELEASE_CHANNEL.to_string(),
            app_version: APP_VERSION.to_string(),
            app_build: APP_BUILD.to_string(),
            build_id: PETCORE_BUILD_ID.to_string(),
            petcore_rpc_protocol: PETCORE_RPC_PROTOCOL_VERSION.to_string(),
            petcore_build_id: PETCORE_BUILD_ID.to_string(),
            petcore_cli_build_id: PETCORE_BUILD_ID.to_string(),
            minimum_database_schema_version: 0,
            maximum_database_schema_version: DATABASE_SCHEMA_VERSION,
            agent_event_schema_version: EVENT_ENVELOPE_SCHEMA_VERSION.to_string(),
            petpack_schema_version: PETPACK_SCHEMA_VERSION.to_string(),
            connector_contracts: ConnectorContracts {
                codex: CODEX_HOOKS_CONTRACT_VERSION.to_string(),
                claude_code: CLAUDE_HOOKS_CONTRACT_VERSION.to_string(),
                pi: PI_EXTENSION_CONTRACT_VERSION.to_string(),
                opencode: OPENCODE_CONTRACT_VERSION.to_string(),
            },
        }
    }

    pub fn read(path: &Path) -> Result<Self> {
        let bytes = fs::read(path).map_err(|error| {
            PetCoreError::Validation(format!("runtime manifest cannot be read: {error}"))
        })?;
        serde_json::from_slice(&bytes).map_err(|error| {
            PetCoreError::Validation(format!("runtime manifest is invalid: {error}"))
        })
    }

    pub fn validate_compiled(&self) -> Result<()> {
        let compiled = Self::compiled();
        if self != &compiled {
            return Err(PetCoreError::Validation(format!(
                "runtime manifest does not match this PetCore build {}",
                PETCORE_BUILD_ID
            )));
        }
        if !matches!(self.release_channel.as_str(), "develop" | "release") {
            return Err(PetCoreError::Validation(
                "runtime manifest release_channel must be develop or release".to_string(),
            ));
        }
        if self.minimum_database_schema_version > self.maximum_database_schema_version {
            return Err(PetCoreError::Validation(
                "runtime manifest database compatibility range is invalid".to_string(),
            ));
        }
        Ok(())
    }
}

pub fn validate_expected_manifest(path: &Path) -> Result<RuntimeReleaseManifest> {
    let manifest = RuntimeReleaseManifest::read(path)?;
    manifest.validate_compiled()?;
    Ok(manifest)
}

pub fn validate_expected_manifest_from_env() -> Result<Option<RuntimeReleaseManifest>> {
    let Some(path) = std::env::var_os("APC_EXPECTED_RUNTIME_MANIFEST") else {
        return Ok(None);
    };
    Ok(Some(validate_expected_manifest(Path::new(&path))?))
}
