use petcore::paths::AppPaths;
use petcore::rpc::{handle_request, CoreState, RpcRequest};
use petcore_types::MAX_GENERATION_DESCRIPTION_CHARS;
use serde_json::json;

fn request(description: &str) -> RpcRequest {
    RpcRequest {
        jsonrpc: Some("2.0".to_string()),
        id: Some(json!("generation-form-contract")),
        method: "generation.start".to_string(),
        params: json!({
            "description": description,
            "style": "半写实",
            "quality": "standard",
            "reference_images": []
        }),
    }
}

#[test]
fn generation_description_is_nonempty_and_bounded_before_job_creation() {
    let temp = tempfile::tempdir().unwrap();
    let state = CoreState::new(AppPaths::new(temp.path().to_path_buf()));
    state.ensure_ready().unwrap();

    let empty_error = handle_request(&state, request("  \n ")).unwrap_err();
    assert!(empty_error.to_string().contains("must not be empty"));
    assert!(state.database.active_generation_job().unwrap().is_none());

    let oversized = "宠".repeat(MAX_GENERATION_DESCRIPTION_CHARS + 1);
    let oversized_error = handle_request(&state, request(&oversized)).unwrap_err();
    assert!(oversized_error.to_string().contains("must not exceed"));
    assert!(state.database.active_generation_job().unwrap().is_none());
}
