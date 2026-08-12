use super::*;

pub(super) fn owns(method: &str) -> bool {
    method.starts_with("generation.")
}

pub(super) fn handle(state: &CoreState, request: RpcRequest) -> Result<Value> {
    match request.method.as_str() {
        "generation.start" => {
            let form: GenerationForm = serde_json::from_value(request.params)?;
            let _admission_guard = state.agent_host_process_guard();
            state.ensure_generation_admission_open()?;
            let job_id = generation_service::start_generation_for_instance(
                &state.paths,
                &state.database,
                form,
                state.instance_id(),
            )?;
            Ok(json!({ "ok": true, "job_id": job_id }))
        }
        "generation.retry" => {
            let retry_of_job_id = required_string(&request.params, "job_id")?;
            let form = request
                .params
                .get("form")
                .cloned()
                .map(serde_json::from_value::<GenerationForm>)
                .transpose()?;
            let _admission_guard = state.agent_host_process_guard();
            state.ensure_generation_admission_open()?;
            let job_id = generation_service::retry_generation_for_instance(
                &state.paths,
                &state.database,
                &retry_of_job_id,
                form,
                state.instance_id(),
            )?;
            let retry_job = state.database.generation_job(&job_id)?;
            let operation = retry_job
                .as_ref()
                .map(generation_service::generation_job_operation)
                .unwrap_or(generation_service::GENERATION_OPERATION_CREATE);
            let baseline_revision_id = retry_job
                .as_ref()
                .map(|job| {
                    generation_service::generation_job_baseline_revision_id(&state.paths, job)
                })
                .transpose()?
                .flatten();
            Ok(json!({
                "ok": true,
                "job_id": job_id,
                "retry_of_job_id": retry_of_job_id,
                "operation": operation,
                "baseline_revision_id": baseline_revision_id
            }))
        }
        "generation.resume" => {
            let job_id = required_string(&request.params, "job_id")?;
            let instruction = optional_string_param(&request.params, "instruction")?;
            let request_id = optional_string_param(&request.params, "request_id")?;
            let _admission_guard = state.agent_host_process_guard();
            state.ensure_generation_admission_open()?;
            let resumed_job_id =
                generation_service::resume_generation_with_instruction_for_instance(
                    &state.paths,
                    &state.database,
                    &job_id,
                    instruction,
                    request_id,
                    state.instance_id(),
                )?;
            let resumed_job = state.database.generation_job(&resumed_job_id)?;
            let operation = resumed_job
                .as_ref()
                .map(generation_service::generation_job_operation)
                .unwrap_or(generation_service::GENERATION_OPERATION_CREATE);
            let baseline_revision_id = resumed_job
                .as_ref()
                .map(|job| {
                    generation_service::generation_job_baseline_revision_id(&state.paths, job)
                })
                .transpose()?
                .flatten();
            Ok(json!({
                "ok": true,
                "job_id": resumed_job_id,
                "resumed": true,
                "operation": operation,
                "baseline_revision_id": baseline_revision_id
            }))
        }
        "generation.messages" => {
            let job_id = required_string(&request.params, "job_id")?;
            Ok(json!(generation_service::read_messages_with_database(
                &state.paths,
                &state.database,
                &job_id
            )?))
        }
        "generation.messages.list" => {
            let job_id = required_string(&request.params, "job_id")?;
            let before_sequence = optional_u64_param(&request.params, "before_sequence")?;
            let limit = bounded_u64_param(&request.params, "limit", 50, 1, 200)? as usize;
            Ok(json!(generation_service::studio_messages_page(
                &state.paths,
                &state.database,
                &job_id,
                before_sequence,
                limit,
            )?))
        }
        "generation.for_pet" => {
            let pet_id = required_string(&request.params, "pet_id")?;
            let Some(job) = state.database.generation_job_for_pet(&pet_id)? else {
                return Ok(json!({
                    "ok": true,
                    "found": false,
                    "pet_id": pet_id,
                    "messages": []
                }));
            };
            generation_session_recovery_snapshot(state, &job, Some(&pet_id))
        }
        "generation.latest" => {
            let Some(job) = state.database.latest_generation_job()? else {
                return Ok(json!({
                    "ok": true,
                    "found": false,
                    "messages": []
                }));
            };
            generation_session_recovery_snapshot(state, &job, None)
        }
        "generation.history.list" => {
            let limit = bounded_u64_param(
                &request.params,
                "limit",
                generation_service::DEFAULT_STUDIO_HISTORY_LIMIT as u64,
                1,
                generation_service::MAX_STUDIO_HISTORY_LIMIT as u64,
            )? as usize;
            Ok(json!(generation_service::studio_history(
                &state.database,
                limit
            )?))
        }
        "generation.history.detail" => {
            let job_id = required_string(&request.params, "job_id")?;
            Ok(json!(generation_service::studio_history_detail(
                &state.paths,
                &state.database,
                &job_id,
            )?))
        }
        "generation.history.delete" => {
            let job_id = required_string(&request.params, "job_id")?;
            Ok(json!(generation_service::delete_studio_history(
                &state.paths,
                &state.database,
                &job_id,
            )?))
        }
        "generation.edit" => {
            let pet_id = required_string(&request.params, "pet_id")?;
            let instruction = required_string(&request.params, "instruction")?;
            let baseline_revision_id =
                optional_string_param(&request.params, "baseline_revision_id")?;
            let _admission_guard = state.agent_host_process_guard();
            state.ensure_generation_admission_open()?;
            let job_id = generation_service::start_pet_edit_from_revision_for_instance(
                &state.paths,
                &state.database,
                &pet_id,
                &instruction,
                baseline_revision_id,
                state.instance_id(),
            )?;
            let created_job = state.database.generation_job(&job_id)?.ok_or_else(|| {
                PetCoreError::Validation(
                    "created pet edit job could not be loaded for its receipt".to_string(),
                )
            })?;
            let baseline_revision_id = generation_service::generation_job_baseline_revision_id(
                &state.paths,
                &created_job,
            )?;
            Ok(json!({
                "ok": true,
                "job_id": job_id,
                "pet_id": pet_id,
                "baseline_revision_id": baseline_revision_id,
                "operation": generation_service::GENERATION_OPERATION_MODIFY
            }))
        }
        "generation.messages.wait" => {
            let job_id = required_string(&request.params, "job_id")?;
            let after_revision = required_string(&request.params, "after_revision")?;
            let timeout_ms = bounded_u64_param(&request.params, "timeout_ms", 30_000, 250, 30_000)?;
            generation_service::wait_messages_with_database(
                &state.paths,
                &state.database,
                &job_id,
                &after_revision,
                timeout_ms,
            )
        }
        "generation.reply" => {
            let job_id = required_string(&request.params, "job_id")?;
            let content = required_string(&request.params, "content")?;
            let request_id = optional_string_param(&request.params, "request_id")?;
            Ok(json!(
                generation_service::append_user_reply_with_request_for_instance(
                    &state.paths,
                    &state.database,
                    &job_id,
                    &content,
                    request_id,
                    state.instance_id(),
                )?
            ))
        }
        "generation.cancel" => {
            let job_id = required_string(&request.params, "job_id")?;
            Ok(json!(generation_service::cancel_generation(
                &state.paths,
                &state.database,
                &job_id
            )?))
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown method {other}"
        ))),
    }
}
