use image::{ImageBuffer, Rgba};
use petcore::petpack::{validate_petpack_path, write_sample_petpack_dir};
use petcore_types::QualityLevel;
use serde_json::{json, Value};
use std::fs;

fn rewrite_manifest(
    root: &std::path::Path,
    mutate: impl FnOnce(&mut serde_json::Map<String, Value>),
) {
    let path = root.join("manifest.json");
    let mut manifest: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    mutate(manifest.as_object_mut().unwrap());
    fs::write(path, serde_json::to_vec_pretty(&manifest).unwrap()).unwrap();
}

#[test]
fn v1_and_v2_packages_are_rejected_instead_of_silently_migrated() {
    for version in ["apc.petpack.v1", "apc.petpack.v2"] {
        let temp = tempfile::tempdir().unwrap();
        write_sample_petpack_dir(
            temp.path(),
            QualityLevel::Standard,
            "Legacy rejection",
            "contract test",
        )
        .unwrap();
        rewrite_manifest(temp.path(), |manifest| {
            manifest.insert("schema_version".to_string(), json!(version));
        });

        let error = validate_petpack_path(temp.path()).unwrap_err().to_string();
        assert!(error.contains("V1/V2 is no longer supported"), "{error}");
        assert!(error.contains("V3 maker"), "{error}");
    }
}

#[test]
fn unsupported_quality_tiers_are_rejected() {
    for removed_quality in ["original", "ultra"] {
        let temp = tempfile::tempdir().unwrap();
        write_sample_petpack_dir(
            temp.path(),
            QualityLevel::Standard,
            "Removed quality",
            "contract test",
        )
        .unwrap();
        rewrite_manifest(temp.path(), |manifest| {
            manifest.insert("quality".to_string(), json!(removed_quality));
        });

        let error = validate_petpack_path(temp.path()).unwrap_err().to_string();
        assert!(error.contains(removed_quality), "{error}");
    }
}

#[test]
fn high_quality_uses_native_576_by_624_frames() {
    let temp = tempfile::tempdir().unwrap();
    let manifest = write_sample_petpack_dir(
        temp.path(),
        QualityLevel::High,
        "High resolution",
        "contract test",
    )
    .unwrap();

    assert_eq!(manifest.render_size.width, 576);
    assert_eq!(manifest.render_size.height, 624);
    let validation = validate_petpack_path(temp.path()).unwrap();
    assert_eq!(validation.manifest.quality, QualityLevel::High);
    assert_eq!(validation.manifest.render_size, manifest.render_size);
}

#[test]
fn one_package_cannot_mix_render_tier_dimensions() {
    let temp = tempfile::tempdir().unwrap();
    write_sample_petpack_dir(
        temp.path(),
        QualityLevel::Low,
        "Mixed dimensions",
        "contract test",
    )
    .unwrap();
    let wrong_size = ImageBuffer::from_pixel(384, 416, Rgba([40_u8, 80, 120, 255]));
    wrong_size
        .save(temp.path().join("assets/frames/idle/0000.png"))
        .unwrap();

    let error = validate_petpack_path(temp.path()).unwrap_err().to_string();
    assert!(error.contains("is 384x416, expected 192x208"), "{error}");
}
