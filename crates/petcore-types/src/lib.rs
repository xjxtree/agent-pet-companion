mod agent;
mod connections;
mod generation;
mod pet;
mod settings;

pub use agent::*;
pub use connections::*;
pub use generation::*;
pub use pet::*;
pub use settings::*;

#[cfg(test)]
use pet::burst_then_settle;

#[cfg(test)]
mod tests {
    use super::*;

    fn overlay_placement_fixture() -> serde_json::Value {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/overlay-placement-canonicalization-v1.json");
        serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
    }

    #[test]
    fn overlay_placement_shared_fixture_is_canonical_and_round_trips() {
        let fixture = overlay_placement_fixture();
        assert_eq!(
            fixture["schema_version"],
            "apc.overlay-placement-canonicalization.v1"
        );
        for case in fixture["cases"].as_array().unwrap() {
            let input: OverlayPlacement = serde_json::from_value(case["input"].clone()).unwrap();
            let expected: OverlayPlacement =
                serde_json::from_value(case["expected"].clone()).unwrap();
            let canonical = input.canonicalized().unwrap();
            assert_eq!(canonical, expected, "fixture case {}", case["id"]);
            assert_eq!(
                canonical.canonicalized().unwrap(),
                canonical,
                "fixture case {} must be idempotent",
                case["id"]
            );
            let decoded: OverlayPlacement =
                serde_json::from_str(&serde_json::to_string(&canonical).unwrap()).unwrap();
            assert_eq!(decoded.canonicalized().unwrap(), canonical);
            if canonical.x == 0.0 {
                assert!(!canonical.x.is_sign_negative());
            }
            if canonical.y == 0.0 {
                assert!(!canonical.y.is_sign_negative());
            }
        }
    }

    #[test]
    fn overlay_placement_coordinate_canonicalization_is_monotonic_and_idempotent() {
        let values = [
            -1_000_000.001953125,
            -10.001953125,
            -0.001953125,
            -0.0,
            0.001953125,
            10.001953125,
            1_000_000.001953125,
        ];
        let canonical: Vec<f64> = values
            .into_iter()
            .map(|value| canonical_overlay_coordinate(value).unwrap())
            .collect();
        assert!(canonical.windows(2).all(|pair| pair[0] <= pair[1]));
        for value in canonical {
            assert_eq!(canonical_overlay_coordinate(value).unwrap(), value);
            assert_eq!(
                value * OVERLAY_PLACEMENT_GRID_UNITS_PER_POINT,
                (value * OVERLAY_PLACEMENT_GRID_UNITS_PER_POINT).round()
            );
        }
        for invalid in [f64::NAN, f64::NEG_INFINITY, f64::INFINITY, f64::MAX] {
            assert!(canonical_overlay_coordinate(invalid).is_err());
        }
    }

    #[test]
    fn quality_levels_have_the_fixed_v3_render_sizes() {
        assert_eq!(
            QualityLevel::Low.render_size(),
            RenderSize {
                width: 192,
                height: 208
            }
        );
        assert_eq!(
            QualityLevel::Standard.render_size(),
            RenderSize {
                width: 384,
                height: 416
            }
        );
        assert_eq!(
            QualityLevel::High.render_size(),
            RenderSize {
                width: 576,
                height: 624
            }
        );
        assert!(QualityLevel::Low.is_studio_supported());
        assert!(QualityLevel::Standard.is_studio_supported());
        assert!(!QualityLevel::High.is_studio_supported());
    }

    #[test]
    fn behavior_settings_drop_removed_event_keys_and_fill_the_current_contract() {
        let behavior: BehaviorSettings = serde_json::from_value(serde_json::json!({
            "events": {
                "start": false,
                "tool": false,
                "waiting": true,
                "review": true,
                "done": true,
                "failed": true
            }
        }))
        .unwrap();

        assert_eq!(behavior.events.len(), 7);
        assert_eq!(behavior.events.get(&AgentEventType::Start), Some(&false));
        assert_eq!(behavior.events.get(&AgentEventType::Thinking), Some(&true));
        assert_eq!(behavior.events.get(&AgentEventType::Plan), Some(&true));
        assert_eq!(behavior.events.get(&AgentEventType::Tool), Some(&false));
        assert!(!serde_json::to_string(&behavior).unwrap().contains("review"));
    }

    #[test]
    fn overlay_placement_intent_is_a_closed_wire_enum() {
        assert_eq!(
            serde_json::to_value(OverlayPlacementIntent::ExternalReposition).unwrap(),
            serde_json::json!("external_reposition")
        );
        assert_eq!(
            serde_json::to_value(OverlayPlacementIntent::Reset).unwrap(),
            serde_json::json!("reset")
        );
        assert!(
            serde_json::from_value::<OverlayPlacementIntent>(serde_json::json!("move")).is_err()
        );
    }

    #[test]
    fn default_v3_action_timings_satisfy_the_hard_contract() {
        let states = default_pet_states();
        assert_eq!(states.len(), REQUIRED_STATES.len());
        assert_eq!(
            states
                .iter()
                .map(|state| state.frame_durations_ms.len())
                .sum::<usize>(),
            50
        );
        for state in &states {
            let warnings = state.validate().unwrap_or_else(|error| {
                panic!(
                    "{} action contract must be valid: {error}",
                    state.name.as_str()
                )
            });
            assert!(
                warnings.is_empty(),
                "{} default action must not warn: {warnings:?}",
                state.name.as_str()
            );
        }
    }

    #[test]
    fn prior_default_v3_action_timings_remain_valid() {
        let mut states = default_pet_states();
        let idle = states
            .iter_mut()
            .find(|state| state.name == PetStateName::Idle)
            .unwrap();
        idle.frame_durations_ms = vec![300, 260, 300, 640];

        let waiting = states
            .iter_mut()
            .find(|state| state.name == PetStateName::Waiting)
            .unwrap();
        waiting.frame_durations_ms = vec![150, 150, 150, 150, 170, 230];
        waiting.playback = burst_then_settle(2, 5);

        let failed = states
            .iter_mut()
            .find(|state| state.name == PetStateName::Failed)
            .unwrap();
        failed.frame_durations_ms = vec![150, 170, 190, 290];
        failed.playback = burst_then_settle(3, 3);

        assert_eq!(
            states
                .iter()
                .map(|state| state.frame_durations_ms.len())
                .sum::<usize>(),
            42
        );
        for state in &states {
            state.validate().unwrap_or_else(|error| {
                panic!(
                    "prior V3 action {} must remain valid: {error}",
                    state.name.as_str()
                )
            });
        }
    }

    #[test]
    fn timing_contract_separates_hard_failures_from_authoring_warnings() {
        let soft_warning = PetTimingContract {
            frame_durations_ms: vec![500; 3],
            playback: PlaybackContract {
                mode: PlaybackMode::Loop,
                entry_repeat_count: None,
                settle_frame_index: None,
                cooldown_ms: None,
            },
            reduced_motion_frame_index: 1,
        };
        let warnings = soft_warning.validate().unwrap();
        assert!(warnings.iter().any(|warning| warning.contains("4–8")));

        let invalid = PetTimingContract {
            frame_durations_ms: vec![49, 100],
            ..soft_warning
        };
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn all_five_v3_playback_modes_have_valid_typed_contracts() {
        let cases = [
            PlaybackContract {
                mode: PlaybackMode::Loop,
                entry_repeat_count: None,
                settle_frame_index: None,
                cooldown_ms: None,
            },
            PlaybackContract {
                mode: PlaybackMode::Periodic,
                entry_repeat_count: None,
                settle_frame_index: None,
                cooldown_ms: Some([2_000, 4_000]),
            },
            PlaybackContract {
                mode: PlaybackMode::BurstThenSettle,
                entry_repeat_count: Some(2),
                settle_frame_index: Some(1),
                cooldown_ms: None,
            },
            PlaybackContract {
                mode: PlaybackMode::BurstThenIdle,
                entry_repeat_count: Some(3),
                settle_frame_index: None,
                cooldown_ms: None,
            },
            PlaybackContract {
                mode: PlaybackMode::OnceThenReturn,
                entry_repeat_count: None,
                settle_frame_index: None,
                cooldown_ms: None,
            },
        ];

        for playback in cases {
            let contract = PetTimingContract {
                frame_durations_ms: vec![120, 180],
                playback,
                reduced_motion_frame_index: 1,
            };
            assert!(
                contract.validate().is_ok(),
                "{:?} must satisfy its mode-specific contract",
                playback.mode
            );
        }
    }

    #[test]
    fn periodic_cooldown_enforces_the_published_single_value_bounds() {
        let contract = |cooldown_ms| PetTimingContract {
            frame_durations_ms: vec![120, 180],
            playback: PlaybackContract {
                mode: PlaybackMode::Periodic,
                entry_repeat_count: None,
                settle_frame_index: None,
                cooldown_ms: Some(cooldown_ms),
            },
            reduced_motion_frame_index: 1,
        };

        for cooldown_ms in [
            [0, 0],
            [0, MAX_PERIODIC_COOLDOWN_MS],
            [MAX_PERIODIC_COOLDOWN_MS, MAX_PERIODIC_COOLDOWN_MS],
        ] {
            assert!(
                contract(cooldown_ms).validate().is_ok(),
                "published boundary {cooldown_ms:?} must be accepted"
            );
        }

        let error = contract([MAX_PERIODIC_COOLDOWN_MS + 1, MAX_PERIODIC_COOLDOWN_MS + 1])
            .validate()
            .unwrap_err();
        assert!(error.contains("must not exceed 86400000"), "{error}");
    }

    #[test]
    fn atomic_agent_events_have_a_sparse_pet_reaction_mapping() {
        assert_eq!(AgentEventType::Start.pet_reaction(), None);
        assert_eq!(AgentEventType::Start.pet_state(), PetStateName::Idle);
        assert_eq!(
            AgentEventType::Thinking.pet_reaction(),
            Some(PetStateName::Thinking)
        );
        assert_eq!(
            AgentEventType::Plan.pet_reaction(),
            Some(PetStateName::Thinking)
        );
        assert_ne!(
            AgentEventType::Thinking.zh_label(),
            AgentEventType::Plan.zh_label()
        );
    }

    #[test]
    fn onboarding_progress_is_versioned_and_has_only_forward_terminal_transitions() {
        let progress = OnboardingProgress::default();
        assert_eq!(progress.schema_version, ONBOARDING_PROGRESS_SCHEMA_VERSION);
        assert_eq!(progress.stage, OnboardingStage::ChoosePet);
        assert!(OnboardingStage::ChoosePet.can_advance_to(OnboardingStage::ConnectAgents));
        assert!(OnboardingStage::ConnectAgents.can_advance_to(OnboardingStage::Demo));
        assert!(OnboardingStage::Demo.can_advance_to(OnboardingStage::Completed));
        assert!(OnboardingStage::Demo.can_advance_to(OnboardingStage::Skipped));
        assert!(!OnboardingStage::Demo.can_advance_to(OnboardingStage::ChoosePet));
        assert!(!OnboardingStage::Completed.can_advance_to(OnboardingStage::Demo));
        assert!(OnboardingStage::Completed.is_terminal());
        assert!(OnboardingStage::Skipped.is_terminal());
    }

    #[test]
    fn pet_summary_defaults_revision_metadata() {
        let pet: PetSummary = serde_json::from_value(serde_json::json!({
            "id": "pet_external",
            "name": "External",
            "style": "pixel",
            "quality": "standard",
            "render_size": { "width": 384, "height": 416 },
            "states": default_pet_states(),
            "petpack_path": "/external.petpack",
            "cover_path": "",
            "active": false,
            "created_at": "2026-07-21T00:00:00Z"
        }))
        .unwrap();

        assert_eq!(pet.revision_id, None);
        assert_eq!(pet.revision_count, 0);
    }

    #[test]
    fn active_generation_snapshot_round_trips_operation_and_baseline_revision() {
        let current = serde_json::json!({
            "job_id": "job_modify",
            "status": "running",
            "form": {
                "description": "Refine the ears",
                "style": "pixel",
                "quality": "standard",
                "reference_images": []
            },
            "reference_reselection_count": 0,
            "session_id": "session_1",
            "result_pet_id": "pet_1",
            "operation": "modify",
            "baseline_revision_id": "revision_1",
            "owner_instance_id": "instance_1",
            "heartbeat_at": "2026-07-21T00:00:00Z",
            "started_at": "2026-07-21T00:00:00Z",
            "recoverable": false,
            "cancellation_pending": false,
            "capabilities": {
                "can_reply": false,
                "can_resume": false,
                "can_cancel": true,
                "can_open_result": false,
                "can_open_session": true,
                "can_delete": false
            },
            "message_revision": "4",
            "messages": [],
            "input_request": null
        });

        let snapshot: GenerationSessionSnapshot = serde_json::from_value(current.clone()).unwrap();
        assert_eq!(snapshot.operation, Some(GenerationOperation::Modify));
        assert_eq!(snapshot.baseline_revision_id.as_deref(), Some("revision_1"));
        assert_eq!(snapshot.reference_reselection_count, 0);
        assert_eq!(serde_json::to_value(snapshot).unwrap(), current);
    }

    #[test]
    fn legacy_active_generation_snapshot_defaults_edit_identity() {
        let snapshot: GenerationSessionSnapshot = serde_json::from_value(serde_json::json!({
            "job_id": "job_legacy",
            "status": "pending",
            "form": {
                "description": "Create a companion",
                "style": "pixel",
                "quality": "standard",
                "reference_images": []
            },
            "session_id": null,
            "result_pet_id": null,
            "owner_instance_id": null,
            "heartbeat_at": "2026-07-21T00:00:00Z",
            "message_revision": "0",
            "messages": [],
            "input_request": null
        }))
        .unwrap();

        assert_eq!(snapshot.operation, None);
        assert_eq!(snapshot.baseline_revision_id, None);
        assert_eq!(snapshot.reference_reselection_count, 0);
        let encoded = serde_json::to_value(snapshot).unwrap();
        assert!(encoded.get("operation").is_none());
        assert!(encoded.get("baseline_revision_id").is_none());
    }

    #[test]
    fn connector_management_capabilities_decode_legacy_and_current_payloads() {
        let legacy: AgentConnectorCapabilities = serde_json::from_value(serde_json::json!({
            "contract_version": "legacy-v1"
        }))
        .unwrap();
        assert_eq!(legacy.repairable_connector_issue, None);
        assert_eq!(legacy.managed_path_conflict, None);
        assert_eq!(legacy.can_uninstall_managed_connector, None);

        let current: AgentConnectorCapabilities = serde_json::from_value(serde_json::json!({
            "repairable_connector_issue": true,
            "managed_path_conflict": false,
            "can_uninstall_managed_connector": true
        }))
        .unwrap();
        assert_eq!(current.repairable_connector_issue, Some(true));
        assert_eq!(current.managed_path_conflict, Some(false));
        assert_eq!(current.can_uninstall_managed_connector, Some(true));
    }

    #[test]
    fn connection_check_serialization_emits_typed_code_and_row_recovery() {
        let item = ConnectionCheckItem::new(
            ConnectionCheckCode::ProjectDirectory,
            "检查目录访问",
            CheckStatus::NeedsFix,
            "任意中文技术信息",
            Some(ConnectionCheckRecoveryAction::ChooseProjectDirectory),
        );
        let value = serde_json::to_value(&item).unwrap();
        assert_eq!(value["code"], "project_directory");
        assert_eq!(value["recovery_action"], "choose_project_directory");

        let renamed = ConnectionCheckItem::new(
            ConnectionCheckCode::ProjectDirectory,
            "Project workspace access v3",
            CheckStatus::NeedsFix,
            "renamed backend detail",
            Some(ConnectionCheckRecoveryAction::ChooseProjectDirectory),
        );
        let renamed_value = serde_json::to_value(&renamed).unwrap();
        assert_eq!(renamed_value["code"], value["code"]);
        assert_eq!(renamed_value["recovery_action"], value["recovery_action"]);

        let claude_policy = ConnectionCheckItem::new(
            ConnectionCheckCode::ClaudeHooksPolicy,
            "renamed backend policy row",
            CheckStatus::NeedsFix,
            "backend-only policy detail",
            Some(ConnectionCheckRecoveryAction::Recheck),
        );
        let claude_policy_value = serde_json::to_value(&claude_policy).unwrap();
        assert_eq!(claude_policy_value["code"], "claude_hooks_policy");
        assert_eq!(claude_policy_value["recovery_action"], "recheck");

        let legacy: ConnectionCheckItem = serde_json::from_value(serde_json::json!({
            "name": "旧检查项",
            "status": "unverified",
            "detail": "legacy"
        }))
        .unwrap();
        assert_eq!(legacy.code, ConnectionCheckCode::Unknown);
        assert_eq!(legacy.recovery_action, None);

        let unknown: ConnectionCheckItem = serde_json::from_value(serde_json::json!({
            "code": "future_policy_probe",
            "name": "Future policy probe",
            "status": "needs_fix",
            "detail": "future",
            "recovery_action": "future_privileged_mutation"
        }))
        .unwrap();
        assert_eq!(unknown.code, ConnectionCheckCode::Unknown);
        assert_eq!(
            unknown.recovery_action,
            Some(ConnectionCheckRecoveryAction::Recheck)
        );
    }
}
