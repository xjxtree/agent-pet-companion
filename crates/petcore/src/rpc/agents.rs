use super::*;

pub(super) fn owns(method: &str) -> bool {
    method.starts_with("agent.") || method.starts_with("events.")
}

pub(super) fn handle(state: &CoreState, request: RpcRequest) -> Result<Value> {
    match request.method.as_str() {
        "agent.ingest" => {
            let event = match normalize_event(&request.params) {
                Ok(event) => event,
                Err(error) => {
                    if let Ok(source) = required_source(&request.params) {
                        state.diagnostics.agent_parse_warning(
                            source,
                            AgentParseWarning {
                                field: AgentParseField::NormalizedEvent,
                                failure: AgentParseFailure::NormalizationFailed,
                            },
                        );
                    }
                    return Err(error);
                }
            };
            ingest_event(state, event)
        }
        "agent.parse_warnings" => record_agent_parse_warnings(state, &request.params),
        "agent.session.acknowledge" => acknowledge_agent_session(state, &request.params),
        "events.recent" => {
            let limit = optional_u64_param(&request.params, "limit")?
                .unwrap_or(20)
                .min(MAX_RECENT_EVENTS as u64) as usize;
            Ok(json!(state.database.recent_events(limit)?))
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown method {other}"
        ))),
    }
}
