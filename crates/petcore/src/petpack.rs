use crate::db::Database;
use crate::paths::AppPaths;
use crate::{new_id, now_rfc3339, PetCoreError, Result};
use image::{ImageBuffer, Rgba};
use petcore_types::{
    PetManifest, PetStateName, PetSummary, QualityLevel, RenderSize, PETPACK_SCHEMA_VERSION,
    REQUIRED_STATES,
};
use std::fs::{self, File};
use std::io::{Read, Seek, Write};
use std::path::{Component, Path};
use zip::write::SimpleFileOptions;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PetpackValidation {
    pub ok: bool,
    pub manifest: PetManifest,
    pub frame_count: usize,
    pub warnings: Vec<String>,
}

pub fn validate_petpack_path(path: &Path) -> Result<PetpackValidation> {
    if path.is_dir() {
        return validate_petpack_dir(path);
    }

    let temp = tempfile::tempdir()?;
    unzip_petpack(path, temp.path())?;
    validate_petpack_dir(temp.path())
}

pub fn validate_petpack_dir(dir: &Path) -> Result<PetpackValidation> {
    let manifest_path = dir.join("manifest.json");
    if !manifest_path.exists() {
        return Err(PetCoreError::Validation(
            "missing manifest.json in petpack root".to_string(),
        ));
    }

    let manifest: PetManifest = serde_json::from_slice(&fs::read(&manifest_path)?)?;
    validate_manifest(&manifest)?;

    let mut frame_count = 0usize;
    let mut warnings = Vec::new();
    for state in REQUIRED_STATES {
        let state_entry = manifest
            .states
            .iter()
            .find(|entry| entry.name == state)
            .ok_or_else(|| {
                PetCoreError::Validation(format!("manifest missing state {}", state.as_str()))
            })?;
        validate_relative_asset_path(&state_entry.frames_dir)?;
        let state_dir = dir.join(&state_entry.frames_dir);
        if !state_dir.is_dir() {
            return Err(PetCoreError::Validation(format!(
                "missing frames directory for state {}",
                state.as_str()
            )));
        }

        let mut state_frames = 0usize;
        for entry in fs::read_dir(&state_dir)? {
            let path = entry?.path();
            if is_png(&path) {
                let (width, height) = image::image_dimensions(&path)?;
                if width != manifest.render_size.width || height != manifest.render_size.height {
                    return Err(PetCoreError::Validation(format!(
                        "frame {} is {}x{}, expected {}x{}",
                        path.display(),
                        width,
                        height,
                        manifest.render_size.width,
                        manifest.render_size.height
                    )));
                }
                frame_count += 1;
                state_frames += 1;
            }
        }

        if state_frames == 0 {
            return Err(PetCoreError::Validation(format!(
                "state {} has no PNG frames",
                state.as_str()
            )));
        }
        if state_frames < 2 {
            warnings.push(format!(
                "state {} has only one frame; animation will be static",
                state.as_str()
            ));
        }
    }

    Ok(PetpackValidation {
        ok: true,
        manifest,
        frame_count,
        warnings,
    })
}

pub fn validate_manifest(manifest: &PetManifest) -> Result<()> {
    if manifest.schema_version != PETPACK_SCHEMA_VERSION {
        return Err(PetCoreError::Validation(format!(
            "unsupported petpack schema {}",
            manifest.schema_version
        )));
    }

    let expected_size = manifest.quality.render_size();
    if manifest.render_size != expected_size {
        return Err(PetCoreError::Validation(format!(
            "render_size does not match quality {}; expected {}x{}",
            manifest.quality.zh_label(),
            expected_size.width,
            expected_size.height
        )));
    }

    for required in REQUIRED_STATES {
        if !manifest.states.iter().any(|state| state.name == required) {
            return Err(PetCoreError::Validation(format!(
                "missing required state {}",
                required.as_str()
            )));
        }
    }

    for state in &manifest.states {
        validate_relative_asset_path(&state.frames_dir)?;
    }

    let standard = manifest
        .fps_profiles
        .get(&petcore_types::FpsProfileName::Standard)
        .copied();
    let smooth = manifest
        .fps_profiles
        .get(&petcore_types::FpsProfileName::Smooth)
        .copied();
    if standard != Some(12) || smooth != Some(20) {
        return Err(PetCoreError::Validation(
            "fps_profiles must contain standard=12 and smooth=20".to_string(),
        ));
    }

    Ok(())
}

fn validate_relative_asset_path(path: &str) -> Result<()> {
    let path = Path::new(path);
    if path.is_absolute()
        || path
            .components()
            .any(|component| matches!(component, Component::ParentDir | Component::Prefix(_)))
    {
        return Err(PetCoreError::Validation(
            "petpack asset paths must stay inside the package".to_string(),
        ));
    }
    Ok(())
}

pub fn write_sample_petpack_dir(
    dir: &Path,
    quality: QualityLevel,
    name: &str,
    style: &str,
    frames_per_state: usize,
) -> Result<PetManifest> {
    fs::create_dir_all(dir)?;
    let manifest = PetManifest::new(
        new_id("pet"),
        name.to_string(),
        style.to_string(),
        quality,
        now_rfc3339(),
    );
    let manifest_json = serde_json::to_vec_pretty(&manifest)?;
    fs::write(dir.join("manifest.json"), manifest_json)?;
    fs::write(
        dir.join("brief.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "name": name,
            "style": style,
            "quality": quality,
            "states": REQUIRED_STATES.iter().map(|state| state.as_str()).collect::<Vec<_>>(),
        }))?,
    )?;

    for state in REQUIRED_STATES {
        let state_dir = dir.join("assets").join("frames").join(state.as_str());
        fs::create_dir_all(&state_dir)?;
        for index in 0..frames_per_state.max(1) {
            let frame = draw_sample_frame(manifest.render_size, state, index);
            frame.save(state_dir.join(format!("{index:04}.png")))?;
        }
    }

    let preview_dir = dir.join("assets").join("preview");
    fs::create_dir_all(&preview_dir)?;
    draw_sample_frame(
        RenderSize {
            width: 384,
            height: 416,
        },
        PetStateName::Idle,
        0,
    )
    .save(preview_dir.join("cover.png"))?;

    let source_dir = dir.join("source");
    fs::create_dir_all(&source_dir)?;
    fs::write(source_dir.join("prompt.md"), "Sample pet generated for validation.\n")?;

    let build_dir = dir.join("build");
    fs::create_dir_all(&build_dir)?;
    fs::write(
        build_dir.join("validation.json"),
        serde_json::to_vec_pretty(&serde_json::json!({ "ok": true }))?,
    )?;

    Ok(manifest)
}

pub fn build_petpack(input_dir: &Path, output_path: &Path) -> Result<PetpackValidation> {
    let validation = validate_petpack_dir(input_dir)?;
    if let Some(parent) = output_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let file = File::create(output_path)?;
    let mut zip = zip::ZipWriter::new(file);
    zip_dir(input_dir, input_dir, &mut zip)?;
    zip.finish()?;
    Ok(validation)
}

pub fn import_petpack(paths: &AppPaths, database: &Database, source_path: &Path) -> Result<PetSummary> {
    let validation = validate_petpack_path(source_path)?;
    fs::create_dir_all(&paths.pets_dir)?;
    let target_path = paths
        .pets_dir
        .join(format!("{}.petpack", validation.manifest.id));
    if source_path.is_dir() {
        build_petpack(source_path, &target_path)?;
    } else {
        fs::copy(source_path, &target_path)?;
    }

    let is_first_pet = database.list_pets()?.is_empty();
    let pet = PetSummary {
        id: validation.manifest.id.clone(),
        name: validation.manifest.name.clone(),
        style: validation.manifest.style.clone(),
        quality: validation.manifest.quality,
        render_size: validation.manifest.render_size,
        petpack_path: target_path.display().to_string(),
        cover_path: "assets/preview/cover.png".to_string(),
        active: is_first_pet,
        created_at: validation.manifest.created_at.clone(),
    };
    database.upsert_pet(&pet)?;
    if is_first_pet {
        database.activate_pet(&pet.id)?;
    }
    Ok(pet)
}

fn is_png(path: &Path) -> bool {
    path.extension()
        .and_then(|value| value.to_str())
        .map(|value| value.eq_ignore_ascii_case("png"))
        .unwrap_or(false)
}

fn draw_sample_frame(
    size: RenderSize,
    state: PetStateName,
    frame_index: usize,
) -> ImageBuffer<Rgba<u8>, Vec<u8>> {
    let mut image = ImageBuffer::from_pixel(size.width, size.height, Rgba([0, 0, 0, 0]));
    let center_x = size.width as i32 / 2;
    let center_y = size.height as i32 / 2;
    let body_w = (size.width as f32 * 0.34) as i32;
    let body_h = (size.height as f32 * 0.52) as i32;
    let bob = if frame_index % 2 == 0 { 0 } else { -(size.height as i32 / 80).max(1) };
    let accent = state_color(state);

    fill_ellipse(
        &mut image,
        center_x,
        center_y + body_h / 2 + bob,
        body_w,
        body_h / 7,
        Rgba([126, 132, 160, 55]),
    );
    fill_ellipse(
        &mut image,
        center_x,
        center_y + bob,
        body_w,
        body_h,
        Rgba([246, 240, 255, 255]),
    );
    fill_ellipse(
        &mut image,
        center_x,
        center_y - body_h / 3 + bob,
        body_w / 2,
        body_w / 2,
        Rgba([255, 219, 188, 255]),
    );
    fill_ellipse(
        &mut image,
        center_x,
        center_y - body_h / 3 + bob,
        body_w / 2 + body_w / 5,
        body_w / 2 + body_w / 3,
        Rgba([54, 50, 151, 245]),
    );
    fill_ellipse(
        &mut image,
        center_x,
        center_y - body_h / 3 + body_w / 9 + bob,
        body_w / 2,
        body_w / 3,
        Rgba([255, 219, 188, 255]),
    );
    fill_ellipse(
        &mut image,
        center_x - body_w / 9,
        center_y - body_h / 3 + bob,
        body_w / 26,
        body_w / 26,
        Rgba([24, 32, 48, 255]),
    );
    fill_ellipse(
        &mut image,
        center_x + body_w / 9,
        center_y - body_h / 3 + bob,
        body_w / 26,
        body_w / 26,
        Rgba([24, 32, 48, 255]),
    );
    fill_rect(
        &mut image,
        center_x - body_w / 3,
        center_y + body_h / 12 + bob,
        body_w * 2 / 3,
        body_h / 5,
        accent,
    );
    image
}

fn state_color(state: PetStateName) -> Rgba<u8> {
    match state {
        PetStateName::Idle => Rgba([96, 169, 232, 255]),
        PetStateName::Start => Rgba([129, 81, 247, 255]),
        PetStateName::Tool => Rgba([60, 189, 214, 255]),
        PetStateName::Waiting => Rgba([240, 176, 64, 255]),
        PetStateName::Review => Rgba([116, 113, 255, 255]),
        PetStateName::Done => Rgba([64, 196, 129, 255]),
        PetStateName::Failed => Rgba([232, 90, 110, 255]),
    }
}

fn fill_rect(
    image: &mut ImageBuffer<Rgba<u8>, Vec<u8>>,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    color: Rgba<u8>,
) {
    for px in x.max(0)..(x + width).min(image.width() as i32) {
        for py in y.max(0)..(y + height).min(image.height() as i32) {
            image.put_pixel(px as u32, py as u32, color);
        }
    }
}

fn fill_ellipse(
    image: &mut ImageBuffer<Rgba<u8>, Vec<u8>>,
    center_x: i32,
    center_y: i32,
    radius_x: i32,
    radius_y: i32,
    color: Rgba<u8>,
) {
    if radius_x <= 0 || radius_y <= 0 {
        return;
    }
    let min_x = (center_x - radius_x).max(0);
    let max_x = (center_x + radius_x).min(image.width() as i32 - 1);
    let min_y = (center_y - radius_y).max(0);
    let max_y = (center_y + radius_y).min(image.height() as i32 - 1);

    let rx2 = (radius_x * radius_x) as i64;
    let ry2 = (radius_y * radius_y) as i64;
    for x in min_x..=max_x {
        for y in min_y..=max_y {
            let dx = (x - center_x) as i64;
            let dy = (y - center_y) as i64;
            if dx * dx * ry2 + dy * dy * rx2 <= rx2 * ry2 {
                image.put_pixel(x as u32, y as u32, color);
            }
        }
    }
}

fn zip_dir<W: Write + Seek>(base: &Path, dir: &Path, zip: &mut zip::ZipWriter<W>) -> Result<()> {
    let options =
        SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        let relative = path.strip_prefix(base).map_err(|error| {
            PetCoreError::Validation(format!("could not build zip relative path: {error}"))
        })?;
        let name = relative.to_string_lossy().replace('\\', "/");
        if path.is_dir() {
            if !name.is_empty() {
                zip.add_directory(format!("{name}/"), options)?;
            }
            zip_dir(base, &path, zip)?;
        } else {
            zip.start_file(name, options)?;
            let mut file = File::open(&path)?;
            std::io::copy(&mut file, zip)?;
        }
    }
    Ok(())
}

fn unzip_petpack(source_path: &Path, output_dir: &Path) -> Result<()> {
    let file = File::open(source_path)?;
    let mut archive = zip::ZipArchive::new(file)?;
    for index in 0..archive.len() {
        let mut file = archive.by_index(index)?;
        let enclosed = file.enclosed_name().ok_or_else(|| {
            PetCoreError::Validation("petpack contains unsafe path".to_string())
        })?;
        let output_path = output_dir.join(enclosed);
        if file.is_dir() {
            fs::create_dir_all(&output_path)?;
        } else {
            if let Some(parent) = output_path.parent() {
                fs::create_dir_all(parent)?;
            }
            let mut output = File::create(&output_path)?;
            let mut buffer = Vec::new();
            file.read_to_end(&mut buffer)?;
            output.write_all(&buffer)?;
        }
    }
    Ok(())
}
