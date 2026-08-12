use petcore::petpack::{build_petpack, validate_petpack_path, write_sample_petpack_dir};
use petcore_types::QualityLevel;
use serde_json::{json, Value};
use std::fs;
use std::io::{Read, Write};
use std::path::Path;
use zip::write::SimpleFileOptions;

fn sample_source(root: &Path) -> std::path::PathBuf {
    let source = root.join("source");
    write_sample_petpack_dir(&source, QualityLevel::Standard, "Limit Pet", "半写实").unwrap();
    source
}

fn manifest(source: &Path) -> Value {
    serde_json::from_slice(&fs::read(source.join("manifest.json")).unwrap()).unwrap()
}

fn write_manifest(source: &Path, value: &Value) {
    fs::write(
        source.join("manifest.json"),
        serde_json::to_vec_pretty(value).unwrap(),
    )
    .unwrap();
}

#[test]
fn manifest_rejects_blank_name_and_style() {
    let temp = tempfile::tempdir().unwrap();
    let source = sample_source(temp.path());

    let mut value = manifest(&source);
    value["name"] = json!(" \n\t ");
    value["style"] = json!("");
    write_manifest(&source, &value);

    let error = validate_petpack_path(&source).unwrap_err().to_string();
    assert!(
        error.contains("name") || error.contains("style"),
        "unexpected validation error: {error}"
    );
}

#[test]
fn manifest_rejects_unknown_fields() {
    let temp = tempfile::tempdir().unwrap();
    let source = sample_source(temp.path());

    let mut value = manifest(&source);
    value["unexpected"] = json!("must not be silently ignored");
    write_manifest(&source, &value);

    let error = validate_petpack_path(&source).unwrap_err().to_string();
    assert!(error.contains("unknown field"), "unexpected error: {error}");
}

#[test]
fn manifest_rejects_invalid_created_at() {
    let temp = tempfile::tempdir().unwrap();
    let source = sample_source(temp.path());

    let mut value = manifest(&source);
    value["created_at"] = json!("not-rfc3339");
    write_manifest(&source, &value);

    let error = validate_petpack_path(&source).unwrap_err().to_string();
    assert!(error.contains("created_at"), "unexpected error: {error}");
}

#[test]
fn nested_frame_path_is_rejected() {
    let temp = tempfile::tempdir().unwrap();
    let source = sample_source(temp.path());
    let idle = source.join("assets/frames/idle");
    let nested = idle.join("nested");
    fs::create_dir_all(&nested).unwrap();
    fs::copy(idle.join("0000.png"), nested.join("0000.png")).unwrap();

    let error = validate_petpack_path(&source).unwrap_err().to_string();
    assert!(
        error.contains("nested") || error.contains("direct"),
        "unexpected error: {error}"
    );
}

#[test]
fn more_than_forty_frames_in_one_state_is_rejected() {
    let temp = tempfile::tempdir().unwrap();
    let source = sample_source(temp.path());
    let idle = source.join("assets/frames/idle");
    let seed = idle.join("0000.png");
    for index in 2..=40 {
        fs::copy(&seed, idle.join(format!("{index:04}.png"))).unwrap();
    }

    let error = validate_petpack_path(&source).unwrap_err().to_string();
    assert!(
        error.contains("40") || error.contains("too many"),
        "unexpected error: {error}"
    );
}

#[test]
fn build_rejects_output_inside_input() {
    let temp = tempfile::tempdir().unwrap();
    let source = sample_source(temp.path());
    let output = source.join("build/output.petpack");

    let error = build_petpack(&source, &output).unwrap_err().to_string();
    assert!(
        error.contains("inside") || error.contains("output"),
        "unexpected error: {error}"
    );
    assert!(!output.exists());
}

#[test]
fn duplicate_logical_zip_frame_path_is_rejected() {
    let temp = tempfile::tempdir().unwrap();
    let source = sample_source(temp.path());
    let normal = temp.path().join("normal.petpack");
    build_petpack(&source, &normal).unwrap();

    let duplicate = temp.path().join("duplicate.petpack");
    let mut input = zip::ZipArchive::new(fs::File::open(&normal).unwrap()).unwrap();
    let output = fs::File::create(&duplicate).unwrap();
    let mut writer = zip::ZipWriter::new(output);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    for index in 0..input.len() {
        let mut entry = input.by_index(index).unwrap();
        let name = entry.name().to_string();
        if entry.is_dir() {
            writer.add_directory(name, options).unwrap();
            continue;
        }
        let mut bytes = Vec::new();
        entry.read_to_end(&mut bytes).unwrap();
        writer.start_file(&name, options).unwrap();
        writer.write_all(&bytes).unwrap();
        if name == "assets/frames/idle/0000.png" {
            writer
                .start_file("assets/frames/idle/0000.PNG", options)
                .unwrap();
            writer.write_all(&bytes).unwrap();
        }
    }
    writer.finish().unwrap();

    let error = validate_petpack_path(&duplicate).unwrap_err().to_string();
    assert!(error.contains("duplicate logical path"), "{error}");
}

#[test]
fn decoded_pixel_budget_is_enforced_before_image_decode() {
    let temp = tempfile::tempdir().unwrap();
    let source = sample_source(temp.path());
    fs::write(
        source.join("assets/frames/idle/0000.png"),
        png_header(4097, 4097),
    )
    .unwrap();

    let error = validate_petpack_path(&source).unwrap_err().to_string();
    assert!(error.contains("pixel limit"), "{error}");
}

#[test]
fn oversized_archive_is_rejected_before_zip_parsing() {
    let temp = tempfile::tempdir().unwrap();
    let archive = temp.path().join("oversized.petpack");
    let file = fs::File::create(&archive).unwrap();
    file.set_len(1024 * 1024 * 1024 + 1).unwrap();

    let error = validate_petpack_path(&archive).unwrap_err().to_string();
    assert!(
        error.contains("archive") && error.contains("1024"),
        "{error}"
    );
}

#[test]
fn expanded_source_tree_budget_is_enforced_for_sparse_files() {
    let temp = tempfile::tempdir().unwrap();
    let source = sample_source(temp.path());
    for index in 0..17 {
        let file = fs::File::create(source.join(format!("sparse-{index}.bin"))).unwrap();
        file.set_len(256 * 1024 * 1024).unwrap();
    }

    let error = validate_petpack_path(&source).unwrap_err().to_string();
    assert!(error.contains("expanded size"), "{error}");
}

fn png_header(width: u32, height: u32) -> Vec<u8> {
    let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(b"IHDR");
    ihdr.extend_from_slice(&width.to_be_bytes());
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.extend_from_slice(&[8, 6, 0, 0, 0]);
    bytes.extend_from_slice(&13u32.to_be_bytes());
    bytes.extend_from_slice(&ihdr);
    bytes.extend_from_slice(&crc32(&ihdr).to_be_bytes());
    let mut idat = b"IDAT".to_vec();
    idat.extend_from_slice(&[0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]);
    bytes.extend_from_slice(&8u32.to_be_bytes());
    bytes.extend_from_slice(&idat);
    bytes.extend_from_slice(&crc32(&idat).to_be_bytes());
    bytes.extend_from_slice(&0u32.to_be_bytes());
    bytes.extend_from_slice(b"IEND");
    bytes.extend_from_slice(&crc32(b"IEND").to_be_bytes());
    bytes
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            let mask = 0u32.wrapping_sub(crc & 1);
            crc = (crc >> 1) ^ (0xedb8_8320 & mask);
        }
    }
    !crc
}
