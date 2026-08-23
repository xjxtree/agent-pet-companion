//! Single source of truth for the RPC method inventory.
//!
//! Every known method is declared here exactly once with the submodule that
//! owns its handler and the closed set of accepted parameter keys. Method
//! discovery (`known_rpc_method`), parameter allowlisting
//! (`validate_method_params`), and handler dispatch all read this table, so a
//! new method cannot be reachable in one layer and rejected in another.

use super::*;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(super) enum RpcMethodOwner {
    Core,
    Pets,
    Generation,
    Connections,
    Agents,
    Settings,
}

pub(super) struct RpcMethodSpec {
    pub(super) method: &'static str,
    pub(super) owner: RpcMethodOwner,
    pub(super) allowed_params: &'static [&'static str],
}

pub(super) const RPC_METHODS: &[RpcMethodSpec] = &[
    // Core (petcore.* / state.*)
    RpcMethodSpec {
        method: "petcore.health",
        owner: RpcMethodOwner::Core,
        allowed_params: &[],
    },
    RpcMethodSpec {
        method: "petcore.shutdown",
        owner: RpcMethodOwner::Core,
        allowed_params: &["expected_instance_id"],
    },
    RpcMethodSpec {
        method: "state.snapshot",
        owner: RpcMethodOwner::Core,
        allowed_params: &[],
    },
    RpcMethodSpec {
        method: "state.wait",
        owner: RpcMethodOwner::Core,
        allowed_params: &["after_revision", "timeout_ms"],
    },
    // Settings-owned surface (behavior/onboarding/overlay/settings/renderer/…)
    RpcMethodSpec {
        method: "behavior.get",
        owner: RpcMethodOwner::Settings,
        allowed_params: &[],
    },
    RpcMethodSpec {
        method: "behavior.patch",
        owner: RpcMethodOwner::Settings,
        allowed_params: &["expected_revision", "changes"],
    },
    RpcMethodSpec {
        method: "onboarding.get",
        owner: RpcMethodOwner::Settings,
        allowed_params: &[],
    },
    RpcMethodSpec {
        method: "onboarding.update",
        owner: RpcMethodOwner::Settings,
        allowed_params: &["expected_revision", "progress"],
    },
    RpcMethodSpec {
        method: "overlay.placement.get",
        owner: RpcMethodOwner::Settings,
        allowed_params: &[],
    },
    RpcMethodSpec {
        method: "overlay.placement.update",
        owner: RpcMethodOwner::Settings,
        allowed_params: &["x", "y", "display_width_pt", "display_id", "expected_revision"],
    },
    RpcMethodSpec {
        method: "overlay.placement.reposition",
        owner: RpcMethodOwner::Settings,
        allowed_params: &["x", "y", "display_width_pt", "display_id"],
    },
    RpcMethodSpec {
        method: "overlay.placement.reset",
        owner: RpcMethodOwner::Settings,
        allowed_params: &[],
    },
    RpcMethodSpec {
        method: "settings.get",
        owner: RpcMethodOwner::Settings,
        allowed_params: &["key"],
    },
    RpcMethodSpec {
        method: "settings.update",
        owner: RpcMethodOwner::Settings,
        allowed_params: &["key", "value"],
    },
    RpcMethodSpec {
        method: "renderer.budget",
        owner: RpcMethodOwner::Settings,
        allowed_params: &["quality", "frame_count"],
    },
    RpcMethodSpec {
        method: "codex.app_server.probe",
        owner: RpcMethodOwner::Settings,
        allowed_params: &[],
    },
    RpcMethodSpec {
        method: "diagnostics.export",
        owner: RpcMethodOwner::Settings,
        allowed_params: &["app_environment"],
    },
    // Agents (agent.* / events.*)
    RpcMethodSpec {
        method: "agent.ingest",
        owner: RpcMethodOwner::Agents,
        allowed_params: AGENT_EVENT_ALLOWED_FIELDS,
    },
    RpcMethodSpec {
        method: "agent.parse_warnings",
        owner: RpcMethodOwner::Agents,
        allowed_params: &["source", "warnings"],
    },
    RpcMethodSpec {
        method: "agent.session.acknowledge",
        owner: RpcMethodOwner::Agents,
        allowed_params: &["acknowledgement_id"],
    },
    RpcMethodSpec {
        method: "events.recent",
        owner: RpcMethodOwner::Agents,
        allowed_params: &["limit"],
    },
    // Pets (pet.* / petpack.*)
    RpcMethodSpec {
        method: "pet.list",
        owner: RpcMethodOwner::Pets,
        allowed_params: &[],
    },
    RpcMethodSpec {
        method: "pet.history",
        owner: RpcMethodOwner::Pets,
        allowed_params: &["pet_id", "limit"],
    },
    RpcMethodSpec {
        method: "pet.activate",
        owner: RpcMethodOwner::Pets,
        allowed_params: &["id"],
    },
    RpcMethodSpec {
        method: "pet.delete",
        owner: RpcMethodOwner::Pets,
        allowed_params: &["id"],
    },
    RpcMethodSpec {
        method: "pet.assets.repair",
        owner: RpcMethodOwner::Pets,
        allowed_params: &["id"],
    },
    RpcMethodSpec {
        method: "petpack.validate",
        owner: RpcMethodOwner::Pets,
        allowed_params: &["path"],
    },
    RpcMethodSpec {
        method: "petpack.import",
        owner: RpcMethodOwner::Pets,
        allowed_params: &["path", "expect_absent"],
    },
    RpcMethodSpec {
        method: "petpack.seed_bundled",
        owner: RpcMethodOwner::Pets,
        allowed_params: &["inventory", "inventory_root"],
    },
    RpcMethodSpec {
        method: "petpack.export",
        owner: RpcMethodOwner::Pets,
        allowed_params: &["id", "path"],
    },
    // Generation
    RpcMethodSpec {
        method: "generation.start",
        owner: RpcMethodOwner::Generation,
        allowed_params: &["description", "style", "quality", "reference_images"],
    },
    RpcMethodSpec {
        method: "generation.retry",
        owner: RpcMethodOwner::Generation,
        allowed_params: &["job_id", "form"],
    },
    RpcMethodSpec {
        method: "generation.resume",
        owner: RpcMethodOwner::Generation,
        allowed_params: &["job_id", "instruction", "request_id"],
    },
    RpcMethodSpec {
        method: "generation.messages",
        owner: RpcMethodOwner::Generation,
        allowed_params: &["job_id"],
    },
    RpcMethodSpec {
        method: "generation.messages.list",
        owner: RpcMethodOwner::Generation,
        allowed_params: &["job_id", "before_sequence", "limit"],
    },
    RpcMethodSpec {
        method: "generation.for_pet",
        owner: RpcMethodOwner::Generation,
        allowed_params: &["pet_id"],
    },
    RpcMethodSpec {
        method: "generation.latest",
        owner: RpcMethodOwner::Generation,
        allowed_params: &[],
    },
    RpcMethodSpec {
        method: "generation.history.list",
        owner: RpcMethodOwner::Generation,
        allowed_params: &["limit"],
    },
    RpcMethodSpec {
        method: "generation.history.detail",
        owner: RpcMethodOwner::Generation,
        allowed_params: &["job_id"],
    },
    RpcMethodSpec {
        method: "generation.history.delete",
        owner: RpcMethodOwner::Generation,
        allowed_params: &["job_id"],
    },
    RpcMethodSpec {
        method: "generation.edit",
        owner: RpcMethodOwner::Generation,
        allowed_params: &["pet_id", "instruction", "baseline_revision_id"],
    },
    RpcMethodSpec {
        method: "generation.messages.wait",
        owner: RpcMethodOwner::Generation,
        allowed_params: &["job_id", "after_revision", "timeout_ms"],
    },
    RpcMethodSpec {
        method: "generation.reply",
        owner: RpcMethodOwner::Generation,
        allowed_params: &["job_id", "content", "request_id"],
    },
    RpcMethodSpec {
        method: "generation.cancel",
        owner: RpcMethodOwner::Generation,
        allowed_params: &["job_id"],
    },
    // Connections (connections.* / portable_skill.* / product.convergence.*)
    RpcMethodSpec {
        method: "connections.check",
        owner: RpcMethodOwner::Connections,
        allowed_params: &["source", "cwd"],
    },
    RpcMethodSpec {
        method: "connections.receipts",
        owner: RpcMethodOwner::Connections,
        allowed_params: &[],
    },
    RpcMethodSpec {
        method: "connections.repair",
        owner: RpcMethodOwner::Connections,
        allowed_params: &["source", "cwd"],
    },
    RpcMethodSpec {
        method: "connections.refresh_installed",
        owner: RpcMethodOwner::Connections,
        allowed_params: &[],
    },
    RpcMethodSpec {
        method: "connections.uninstall",
        owner: RpcMethodOwner::Connections,
        allowed_params: &["source"],
    },
    RpcMethodSpec {
        method: "connections.test",
        owner: RpcMethodOwner::Connections,
        allowed_params: &["source"],
    },
    RpcMethodSpec {
        method: "portable_skill.status",
        owner: RpcMethodOwner::Connections,
        allowed_params: &[],
    },
    RpcMethodSpec {
        method: "portable_skill.install",
        owner: RpcMethodOwner::Connections,
        allowed_params: &[],
    },
    RpcMethodSpec {
        method: "portable_skill.uninstall",
        owner: RpcMethodOwner::Connections,
        allowed_params: &[],
    },
    RpcMethodSpec {
        method: "product.convergence.get",
        owner: RpcMethodOwner::Connections,
        allowed_params: &[],
    },
    RpcMethodSpec {
        method: "product.convergence.update",
        owner: RpcMethodOwner::Connections,
        allowed_params: &["schema_version", "build_id", "app_version", "connector_report"],
    },
    RpcMethodSpec {
        method: "product.convergence.preflight",
        owner: RpcMethodOwner::Connections,
        allowed_params: &[],
    },
];

pub(super) fn method_spec(method: &str) -> Option<&'static RpcMethodSpec> {
    RPC_METHODS.iter().find(|spec| spec.method == method)
}

pub(super) fn known_rpc_method(method: &str) -> bool {
    method_spec(method).is_some()
}

pub(super) fn allowed_params(method: &str) -> &'static [&'static str] {
    method_spec(method)
        .map(|spec| spec.allowed_params)
        .unwrap_or(&[])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn method_names_are_unique() {
        let mut names: Vec<&str> = RPC_METHODS.iter().map(|spec| spec.method).collect();
        let total = names.len();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), total, "duplicate method in registry");
        assert_eq!(total, 56, "method inventory changed; update this test deliberately");
    }

    #[test]
    fn every_method_name_matches_its_owner_prefix() {
        for spec in RPC_METHODS {
            let expected = match spec.owner {
                RpcMethodOwner::Core => {
                    spec.method.starts_with("petcore.") || spec.method.starts_with("state.")
                }
                RpcMethodOwner::Pets => {
                    spec.method.starts_with("pet.") || spec.method.starts_with("petpack.")
                }
                RpcMethodOwner::Generation => spec.method.starts_with("generation."),
                RpcMethodOwner::Connections => {
                    spec.method.starts_with("connections.")
                        || spec.method.starts_with("portable_skill.")
                        || spec.method.starts_with("product.convergence.")
                }
                RpcMethodOwner::Agents => {
                    spec.method.starts_with("agent.") || spec.method.starts_with("events.")
                }
                RpcMethodOwner::Settings => {
                    spec.method.starts_with("behavior.")
                        || spec.method.starts_with("onboarding.")
                        || spec.method.starts_with("overlay.")
                        || spec.method.starts_with("settings.")
                        || spec.method.starts_with("renderer.")
                        || spec.method.starts_with("codex.app_server.")
                        || spec.method.starts_with("diagnostics.")
                }
            };
            assert!(expected, "owner mismatch for {}", spec.method);
        }
    }
}
