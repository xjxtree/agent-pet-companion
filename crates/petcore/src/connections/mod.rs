mod capabilities;
mod evidence;
mod manager;
mod ownership;

pub use manager::{
    check_all, check_all_at, check_all_light, check_source, check_source_at, probe_opencode_server,
    refresh_installed_source, refresh_installed_sources, repair_source, repair_source_at,
    uninstall_source, InstalledSourceRefreshResult, InstalledSourceRefreshStatus,
    InstalledSourcesRefreshReport,
};

pub(crate) use capabilities::contract_version_for_source;
pub(crate) use evidence::task_evidence_events;
pub(crate) use manager::{
    cached_connection_status_is_current_for_light_projection, compiled_codex_plugin_identity,
    connection_light_cache_revision, connector_receipt_is_current, project_connection_evidence,
};

#[cfg(test)]
pub(crate) use manager::{
    connector_receipt_freshness_load_count, reset_connector_receipt_freshness_load_count,
};
