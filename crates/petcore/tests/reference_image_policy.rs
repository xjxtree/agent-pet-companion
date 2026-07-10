use image::{ImageBuffer, ImageFormat, Rgba};
use petcore::reference_images::{validate_reference_inputs, MAX_REFERENCE_IMAGES};
use std::path::{Path, PathBuf};

fn write_image(path: &Path, format: ImageFormat) {
    let image = ImageBuffer::from_pixel(8, 8, Rgba([24u8, 48, 96, 255]));
    image.save_with_format(path, format).unwrap();
}

fn strings(paths: &[PathBuf]) -> Vec<String> {
    paths
        .iter()
        .map(|path| path.display().to_string())
        .collect()
}

#[test]
fn reference_policy_accepts_png_and_webp() {
    let temp = tempfile::tempdir().unwrap();
    let png = temp.path().join("one.png");
    let webp = temp.path().join("two.webp");
    write_image(&png, ImageFormat::Png);
    write_image(&webp, ImageFormat::WebP);

    let validated = validate_reference_inputs(&strings(&[png, webp])).unwrap();
    assert_eq!(validated.len(), 2);
    assert_eq!(validated[0].extension, "png");
    assert_eq!(validated[1].extension, "webp");
    assert!(validated
        .iter()
        .all(|item| item.width == 8 && item.height == 8));
    assert!(validated.iter().all(|item| item.sha256.len() == 64));
}

#[test]
fn reference_policy_rejects_extension_content_mismatch() {
    let temp = tempfile::tempdir().unwrap();
    let mismatch = temp.path().join("actually-png.webp");
    write_image(&mismatch, ImageFormat::Png);

    let error = validate_reference_inputs(&strings(&[mismatch]))
        .unwrap_err()
        .to_string();
    assert!(
        error.contains("extension") || error.contains("format") || error.contains("格式"),
        "{error}"
    );
}

#[test]
fn reference_policy_rejects_unsupported_jpeg() {
    let temp = tempfile::tempdir().unwrap();
    let jpeg = temp.path().join("reference.jpg");
    std::fs::write(&jpeg, b"not even decoded because JPEG is unsupported").unwrap();

    let error = validate_reference_inputs(&strings(&[jpeg]))
        .unwrap_err()
        .to_string();
    assert!(error.contains("PNG") && error.contains("WebP"), "{error}");
}

#[test]
fn reference_policy_rejects_more_than_the_maximum_count() {
    let temp = tempfile::tempdir().unwrap();
    let mut paths = Vec::new();
    for index in 0..=MAX_REFERENCE_IMAGES {
        let path = temp.path().join(format!("reference-{index}.png"));
        write_image(&path, ImageFormat::Png);
        paths.push(path);
    }

    let error = validate_reference_inputs(&strings(&paths))
        .unwrap_err()
        .to_string();
    assert!(error.contains(&MAX_REFERENCE_IMAGES.to_string()), "{error}");
}
