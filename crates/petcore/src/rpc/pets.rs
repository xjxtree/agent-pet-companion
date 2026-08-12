use super::*;

pub(super) fn owns(method: &str) -> bool {
    method.starts_with("pet.") || method.starts_with("petpack.")
}

pub(super) fn handle(state: &CoreState, request: RpcRequest) -> Result<Value> {
    match request.method.as_str() {
        "pet.list" => Ok(json!(list_pets_with_revision_metadata(state)?)),
        "pet.history" => {
            let pet_id = required_string(&request.params, "pet_id")?;
            let limit = bounded_u64_param(
                &request.params,
                "limit",
                generation_service::DEFAULT_PET_HISTORY_LIMIT as u64,
                1,
                generation_service::MAX_PET_HISTORY_LIMIT as u64,
            )? as usize;
            Ok(json!(generation_service::pet_history(
                &state.paths,
                &state.database,
                &pet_id,
                limit,
            )?))
        }
        "pet.activate" => {
            let id = required_string(&request.params, "id")?;
            state.database.activate_pet(&id)?;
            Ok(json!({ "ok": true }))
        }
        "pet.delete" => {
            let id = required_string(&request.params, "id")?;
            let pet = state
                .database
                .get_pet(&id)?
                .ok_or_else(|| PetCoreError::InvalidRequest(format!("pet not found: {id}")))?;
            if petpack::is_bundled_pet(&pet) {
                return Err(PetCoreError::Conflict(
                    "bundled pets are part of the App and cannot be deleted".to_string(),
                ));
            }
            let staged_assets = petpack::stage_imported_pet_assets_for_removal(&state.paths, &pet)?;
            let next_active_pet_id =
                match state.database.delete_pet_and_activate_next(&id, pet.active) {
                    Ok(next_active_pet_id) => next_active_pet_id,
                    Err(error) => {
                        staged_assets.rollback()?;
                        return Err(error);
                    }
                };
            let deleted_assets = staged_assets.commit();
            Ok(json!({
                "ok": true,
                "deleted_assets": deleted_assets,
                "next_active_pet_id": next_active_pet_id
            }))
        }
        "pet.assets.repair" => {
            let id = required_string(&request.params, "id")?;
            let pet = state
                .database
                .get_pet(&id)?
                .ok_or_else(|| PetCoreError::InvalidRequest(format!("pet not found: {id}")))?;
            Ok(json!(petpack::repair_runtime_assets(
                &state.paths,
                &state.database,
                &pet
            )?))
        }
        "petpack.validate" => {
            let path = required_string(&request.params, "path")?;
            Ok(json!(petpack::validate_petpack_path(&PathBuf::from(path))?))
        }
        "petpack.import" => {
            let path = required_string(&request.params, "path")?;
            let expect_absent = match request.params.get("expect_absent") {
                None => false,
                Some(Value::Bool(value)) => *value,
                Some(_) => return Err(invalid_params("expect_absent must be a boolean")),
            };
            let path = PathBuf::from(path);
            let pet = if expect_absent {
                petpack::import_petpack_expecting_absent(&state.paths, &state.database, &path)?
            } else {
                petpack::import_petpack(&state.paths, &state.database, &path)?
            };
            Ok(json!(pet))
        }
        "petpack.seed_bundled" => {
            let inventory = required_string(&request.params, "inventory")?;
            if inventory != petpack::BUNDLED_PET_INVENTORY_VERSION {
                return Err(invalid_params("unsupported bundled pet inventory"));
            }
            let inventory_root = required_string(&request.params, "inventory_root")?;
            Ok(json!({
                "inventory": petpack::BUNDLED_PET_INVENTORY_VERSION,
                "outcomes": petpack::seed_bundled_pet_inventory(
                    &state.paths,
                    &state.database,
                    &PathBuf::from(inventory_root),
                )?
            }))
        }
        "petpack.export" => {
            let id = required_string(&request.params, "id")?;
            let path = required_string(&request.params, "path")?;
            Ok(json!(petpack::export_petpack(
                &state.paths,
                &state.database,
                &id,
                &PathBuf::from(path)
            )?))
        }
        other => Err(PetCoreError::InvalidRequest(format!(
            "unknown method {other}"
        ))),
    }
}
