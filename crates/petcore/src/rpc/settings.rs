use super::*;

pub(super) fn owns(method: &str) -> bool {
    method.starts_with("behavior.")
        || method.starts_with("onboarding.")
        || method.starts_with("overlay.")
        || method.starts_with("settings.")
        || method.starts_with("renderer.")
        || method.starts_with("codex.app_server.")
        || method.starts_with("diagnostics.")
}

pub(super) fn handle(state: &CoreState, request: RpcRequest) -> Result<Value> {
    match request.method.as_str() {
        "behavior.get" => Ok(json!(state.database.behavior_with_revision()?)),
        "behavior.patch" => {
            let expected_revision = required_string(&request.params, "expected_revision")?
                .parse::<u64>()
                .map_err(|_| invalid_params("expected_revision must be a decimal string"))?;
            let changes = request
                .params
                .get("changes")
                .cloned()
                .ok_or_else(|| invalid_params("missing behavior changes"))?;
            let changes: BehaviorSettingsPatch = serde_json::from_value(changes)
                .map_err(|error| invalid_params(format!("invalid behavior changes: {error}")))?;
            Ok(json!(state
                .database
                .patch_behavior(expected_revision, &changes)?))
        }
        "onboarding.get" => Ok(json!(state.database.onboarding_with_revision()?)),
        "onboarding.update" => {
            let expected_revision = required_string(&request.params, "expected_revision")?
                .parse::<u64>()
                .map_err(|_| invalid_params("expected_revision must be a decimal string"))?;
            let progress = request
                .params
                .get("progress")
                .cloned()
                .ok_or_else(|| invalid_params("missing onboarding progress"))?;
            let progress: OnboardingProgress = serde_json::from_value(progress)
                .map_err(|error| invalid_params(format!("invalid onboarding progress: {error}")))?;
            Ok(json!(state
                .database
                .update_onboarding(expected_revision, &progress)?))
        }
        "overlay.placement.get" => {
            let projection = state.database.overlay_placement_projection()?;
            Ok(json!({
                "overlay_placement": projection.placement,
                "overlay_placement_revision": projection.revision.to_string(),
                "overlay_placement_intent": projection.intent,
            }))
        }
        "overlay.placement.update" => {
            let expected_revision =
                required_canonical_decimal_u64(&request.params, "expected_revision")?;
            let mut placement_params = request.params;
            placement_params
                .as_object_mut()
                .expect("validated RPC params are an object")
                .remove("expected_revision");
            let placement: OverlayPlacement = serde_json::from_value(placement_params)?;
            persist_overlay_placement(state, placement, None, Some(expected_revision))
        }
        "overlay.placement.reposition" => {
            let placement: OverlayPlacement = serde_json::from_value(request.params)?;
            persist_overlay_placement(
                state,
                placement,
                Some(OverlayPlacementIntent::ExternalReposition),
                None,
            )
        }
        "overlay.placement.reset" => persist_overlay_placement(
            state,
            OverlayPlacement::default(),
            Some(OverlayPlacementIntent::Reset),
            None,
        ),
        "settings.get" => {
            let key = required_string(&request.params, "key")?;
            validate_client_setting_key(&key)?;
            let value = state.database.get_raw_setting(&key)?;
            Ok(json!({ "key": key, "value_json": value }))
        }
        "settings.update" => {
            let key = required_string(&request.params, "key")?;
            validate_client_setting_key(&key)?;
            let value = request
                .params
                .get("value")
                .cloned()
                .ok_or_else(|| PetCoreError::InvalidRequest("missing value".to_string()))?;
            state.database.set_setting(&key, &value)?;
            Ok(json!({ "ok": true }))
        }
        "renderer.budget" => {
            let quality = required_quality(&request.params)?;
            let frame_count = optional_u64_param(&request.params, "frame_count")?.unwrap_or(8);
            if !(petcore_types::MIN_FRAMES_PER_STATE as u64
                ..=petcore_types::MAX_FRAMES_PER_STATE as u64)
                .contains(&frame_count)
            {
                return Err(invalid_params(format!(
                    "frame_count must be between {} and {}",
                    petcore_types::MIN_FRAMES_PER_STATE,
                    petcore_types::MAX_FRAMES_PER_STATE
                )));
            }
            Ok(json!(metrics::renderer_budget(quality, frame_count as u32)))
        }
        "codex.app_server.probe" => {
            let _host_guard = state.agent_host_process_guard();
            Ok(json!(app_server::probe_codex_app_server()))
        }
        "diagnostics.export" => {
            let app_environment = request
                .params
                .get("app_environment")
                .ok_or_else(|| invalid_params("missing app_environment"))?;
            Ok(json!(diagnostics::export_diagnostics(
                &state.paths,
                &state.diagnostics,
                app_environment,
            )?))
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown method {other}"
        ))),
    }
}
