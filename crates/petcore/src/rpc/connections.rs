use super::*;

pub(super) fn handle(state: &CoreState, request: RpcRequest) -> Result<Value> {
    match request.method.as_str() {
        "connections.check" => {
            let probe_cwd = optional_probe_cwd(&request.params)?;
            let source = optional_source(&request.params)?;
            let _operation = state.begin_connection_operation()?;
            let _host_guard = state.agent_host_process_guard();
            if let Some(source) = source {
                let status = match probe_cwd.as_deref() {
                    Some(cwd) => connections::check_source_at(&state.paths, source, cwd),
                    None => connections::check_source(&state.paths, source),
                };
                state.invalidate_connection_light_status_cache();
                state.invalidate_connection_evidence_projection(source);
                let persisted = state.database.upsert_connection_status(&status);
                state.invalidate_connection_light_status_cache();
                state.invalidate_connection_evidence_projection(source);
                persisted?;
                Ok(json!(status))
            } else {
                let statuses = match probe_cwd.as_deref() {
                    Some(cwd) => connections::check_all_at(&state.paths, cwd),
                    None => connections::check_all(&state.paths),
                };
                state.invalidate_connection_light_status_cache();
                state.invalidate_all_connection_evidence_projections();
                let persisted = state.database.upsert_connection_statuses(&statuses);
                state.invalidate_connection_light_status_cache();
                state.invalidate_all_connection_evidence_projections();
                persisted?;
                Ok(json!(statuses))
            }
        }
        "connections.receipts" => {
            let receipts = [
                AgentSource::Codex,
                AgentSource::ClaudeCode,
                AgentSource::Pi,
                AgentSource::Opencode,
                AgentSource::Dsh,
            ]
            .into_iter()
            .map(|source| {
                let contract_version = connections::contract_version_for_source(source);
                let ordinary = state
                    .database
                    .latest_connector_ordinary_receipt_for_contract(source, contract_version)?
                    .map(|receipt| connector_receipt_status(&state.paths, source, receipt));
                let diagnostic = state
                    .database
                    .latest_connector_event_receipt_for_contract(source, true, contract_version)?
                    .map(|receipt| connector_receipt_status(&state.paths, source, receipt));
                let (task_starts, task_activities, task_completions) =
                    connections::task_evidence_events(source);
                let task = state
                    .database
                    .latest_connector_task_receipt_for_contract(
                        source,
                        contract_version,
                        task_starts,
                        task_activities,
                        task_completions,
                    )?
                    .map(|receipt| connector_task_receipt_status(&state.paths, source, receipt));
                let latest_observed_ordinary = state
                    .database
                    .latest_connector_event_receipt(source, false)?;
                let latest_observed_diagnostic = state
                    .database
                    .latest_connector_event_receipt(source, true)?;
                Ok(json!({
                    "source": source,
                    "ordinary": ordinary,
                    "diagnostic": diagnostic,
                    "task": task,
                    "latest_observed": {
                        "ordinary": latest_observed_ordinary,
                        "diagnostic": latest_observed_diagnostic,
                    },
                }))
            })
            .collect::<Result<Vec<_>>>()?;
            Ok(json!(receipts))
        }
        "connections.repair" => {
            let source = required_source(&request.params)?;
            let probe_cwd = optional_probe_cwd(&request.params)?;
            let _operation = state.begin_connection_operation()?;
            let _host_guard = state.agent_host_process_guard();
            state.invalidate_connection_light_status_cache();
            state.invalidate_connection_evidence_projection(source);
            let status = match probe_cwd.as_deref() {
                Some(cwd) => connections::repair_source_at(&state.paths, source, cwd),
                None => connections::repair_source(&state.paths, source),
            };
            state.invalidate_connection_light_status_cache();
            state.invalidate_connection_evidence_projection(source);
            let status = status?;
            let persisted = state.database.upsert_connection_status(&status);
            state.invalidate_connection_light_status_cache();
            state.invalidate_connection_evidence_projection(source);
            persisted?;
            Ok(json!(status))
        }
        "connections.refresh_installed" => {
            let _operation = state.begin_connection_operation()?;
            let _host_guard = state.agent_host_process_guard();
            if state.database.active_generation_job()?.is_some() {
                return Err(PetCoreError::Conflict(
                    "generation work is active; wait before updating Agent capabilities"
                        .to_string(),
                ));
            }
            state.invalidate_connection_light_status_cache();
            state.invalidate_all_connection_evidence_projections();
            let refreshed = connections::refresh_installed_sources(&state.paths);
            state.invalidate_connection_light_status_cache();
            state.invalidate_all_connection_evidence_projections();
            Ok(json!(refreshed))
        }
        "product.convergence.get" => Ok(json!(state.database.product_convergence_receipt()?)),
        "product.convergence.update" => {
            let params: ProductConvergenceUpdateParams = serde_json::from_value(request.params)
                .map_err(|error| {
                    invalid_params(format!("invalid product convergence receipt: {error}"))
                })?;
            let receipt = validated_product_convergence_receipt(state, params)?;
            state
                .database
                .upsert_product_convergence_receipt(&receipt)?;
            Ok(json!(receipt))
        }
        "product.convergence.preflight" => {
            let active_generation = state.database.active_generation_job()?;
            let active_generation_status =
                active_generation.as_ref().map(|job| enum_name(job.status));
            let connection_operation_active =
                state.connection_operation_active.load(Ordering::Acquire);
            let runtime_replacement_safe = active_generation.as_ref().is_none_or(|job| {
                matches!(
                    job.status,
                    GenerationJobStatus::WaitingForUser | GenerationJobStatus::Failed
                )
            }) && !connection_operation_active;
            Ok(json!({
                "safe": active_generation.is_none() && !connection_operation_active,
                "active_generation": active_generation.is_some(),
                "active_generation_status": active_generation_status,
                "connection_operation_active": connection_operation_active,
                "runtime_replacement_safe": runtime_replacement_safe,
            }))
        }
        "connections.uninstall" => {
            let source = required_source(&request.params)?;
            let _operation = state.begin_connection_operation()?;
            let _host_guard = state.agent_host_process_guard();
            state.invalidate_connection_light_status_cache();
            state.invalidate_connection_evidence_projection(source);
            let status = connections::uninstall_source(&state.paths, source);
            state.invalidate_connection_light_status_cache();
            state.invalidate_connection_evidence_projection(source);
            let status = status?;
            let persisted = state.database.upsert_connection_status(&status);
            state.invalidate_connection_light_status_cache();
            state.invalidate_connection_evidence_projection(source);
            persisted?;
            Ok(json!(status))
        }
        "portable_skill.status" => Ok(json!(portable_skill::status(&state.paths)?)),
        "portable_skill.install" => {
            let _operation = state.begin_connection_operation()?;
            let _host_guard = state.agent_host_process_guard();
            Ok(json!(portable_skill::install(&state.paths)?))
        }
        "portable_skill.uninstall" => {
            let _operation = state.begin_connection_operation()?;
            let _host_guard = state.agent_host_process_guard();
            Ok(json!(portable_skill::uninstall(&state.paths)?))
        }
        "connections.test" => {
            let source = required_source(&request.params)?;
            let _operation = state.begin_connection_operation()?;
            let event = AgentEvent {
                id: new_id("evt_connection_test"),
                source,
                project_path: None,
                session_id: Some("agent-pet-connection-test".to_string()),
                event_type: AgentEventType::Start,
                title: AgentEventType::Start.zh_label().to_string(),
                detail: None,
                payload_json: json!({
                    "schema_version": "apc.agent-event.v1",
                    "external_event_id": null,
                    "source_event": "connection.test",
                    "tool_name": null,
                    "outcome": "started",
                    "diagnostic": true
                }),
                created_at: now_rfc3339(),
            };
            ingest_event(state, event)
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown method {other}"
        ))),
    }
}
