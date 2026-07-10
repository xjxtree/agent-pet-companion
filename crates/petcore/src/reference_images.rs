use crate::{PetCoreError, Result};
use image::{ImageFormat, ImageReader};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};

pub const MAX_REFERENCE_IMAGES: usize = 4;
pub const MAX_REFERENCE_FILE_BYTES: u64 = 20 * 1024 * 1024;
pub const MAX_REFERENCE_TOTAL_BYTES: u64 = 40 * 1024 * 1024;
pub const MAX_REFERENCE_PIXELS: u64 = 16_000_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidatedReference {
    pub source: PathBuf,
    pub extension: &'static str,
    pub width: u32,
    pub height: u32,
    pub bytes: u64,
    pub sha256: String,
}

pub fn validate_reference_inputs(paths: &[String]) -> Result<Vec<ValidatedReference>> {
    if paths.len() > MAX_REFERENCE_IMAGES {
        return Err(PetCoreError::InvalidRequest(format!(
            "参考图最多允许 {MAX_REFERENCE_IMAGES} 张"
        )));
    }

    let mut total_bytes = 0u64;
    let mut validated = Vec::with_capacity(paths.len());
    for raw_path in paths {
        let source = Path::new(raw_path);
        if !source.is_file() {
            return Err(PetCoreError::InvalidRequest(format!(
                "参考图不可用：文件不存在或不可读取：{}",
                source.display()
            )));
        }

        let extension = supported_extension(source)?;
        let mut file = fs::File::open(source)?;
        if file.metadata()?.len() > MAX_REFERENCE_FILE_BYTES {
            return Err(PetCoreError::InvalidRequest(format!(
                "参考图 {} 超过单文件 {} MiB 限制",
                source.display(),
                MAX_REFERENCE_FILE_BYTES / (1024 * 1024)
            )));
        }
        let mut contents = Vec::new();
        file.by_ref()
            .take(MAX_REFERENCE_FILE_BYTES + 1)
            .read_to_end(&mut contents)?;
        let bytes = contents.len() as u64;
        if bytes > MAX_REFERENCE_FILE_BYTES {
            return Err(PetCoreError::InvalidRequest(format!(
                "参考图 {} 超过单文件 {} MiB 限制",
                source.display(),
                MAX_REFERENCE_FILE_BYTES / (1024 * 1024)
            )));
        }
        total_bytes = total_bytes
            .checked_add(bytes)
            .ok_or_else(|| PetCoreError::InvalidRequest("参考图总大小溢出".to_string()))?;
        if total_bytes > MAX_REFERENCE_TOTAL_BYTES {
            return Err(PetCoreError::InvalidRequest(format!(
                "参考图总大小超过 {} MiB 限制",
                MAX_REFERENCE_TOTAL_BYTES / (1024 * 1024)
            )));
        }

        let reader = ImageReader::new(Cursor::new(contents.as_slice())).with_guessed_format()?;
        let actual_format = reader.format().ok_or_else(|| {
            PetCoreError::InvalidRequest(format!(
                "无法识别参考图格式：{}；仅支持 PNG 和 WebP",
                source.display()
            ))
        })?;
        let expected_format = match extension {
            "png" => ImageFormat::Png,
            "webp" => ImageFormat::WebP,
            _ => unreachable!("supported_extension returns only known formats"),
        };
        if actual_format != expected_format {
            return Err(PetCoreError::InvalidRequest(format!(
                "参考图扩展名与实际格式不一致：{}",
                source.display()
            )));
        }
        let (width, height) = reader.into_dimensions()?;
        let pixels = u64::from(width)
            .checked_mul(u64::from(height))
            .ok_or_else(|| PetCoreError::InvalidRequest("参考图像素数溢出".to_string()))?;
        if pixels > MAX_REFERENCE_PIXELS {
            return Err(PetCoreError::InvalidRequest(format!(
                "参考图 {} 超过 {} 像素限制",
                source.display(),
                MAX_REFERENCE_PIXELS
            )));
        }

        // Decode after the cheap format, byte and pixel checks so malformed data
        // and decompression bombs cannot enter the generation workspace.
        ImageReader::new(Cursor::new(contents.as_slice()))
            .with_guessed_format()?
            .decode()?;
        let digest = Sha256::digest(&contents);
        validated.push(ValidatedReference {
            source: source.to_path_buf(),
            extension,
            width,
            height,
            bytes,
            sha256: hex::encode(digest),
        });
    }

    Ok(validated)
}

fn supported_extension(path: &Path) -> Result<&'static str> {
    match path
        .extension()
        .and_then(|value| value.to_str())
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("png") => Ok("png"),
        Some("webp") => Ok("webp"),
        _ => Err(PetCoreError::InvalidRequest(format!(
            "参考图仅支持 PNG 和 WebP：{}",
            path.display()
        ))),
    }
}
