use crate::{PetCoreError, Result};
use image::{DynamicImage, ImageFormat, ImageReader, RgbaImage};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{Cursor, Read, Write};
use std::os::fd::AsFd;
use std::os::unix::fs::MetadataExt;
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

#[derive(Debug)]
pub(crate) struct ValidatedReferenceSnapshot {
    metadata: ValidatedReference,
    contents: Vec<u8>,
}

impl ValidatedReferenceSnapshot {
    pub(crate) fn extension(&self) -> &'static str {
        self.metadata.extension
    }

    /// Writes the immutable descriptor snapshot, never the source path. The
    /// snapshot is fully rechecked immediately before it is materialized so
    /// copying cannot become detached from the bytes that passed validation.
    pub(crate) fn write_verified_copy(&self, index: usize, path: &Path) -> Result<()> {
        self.verify(index)?;
        write_reference_bytes(index, path, &self.contents, "物化失败，请重新选择该文件")
    }

    /// Decodes the same immutable descriptor snapshot used for the package
    /// copy. Digest, size, image dimensions and format are rechecked against
    /// the snapshot metadata before pixels are returned to the renderer.
    pub(crate) fn decode_verified_rgba(&self, index: usize) -> Result<RgbaImage> {
        let (width, height, format, decoded) = decode_reference_bytes(index, &self.contents)?;
        self.verify_metadata(index, width, height, format)?;
        Ok(decoded.to_rgba8())
    }

    fn verify(&self, index: usize) -> Result<()> {
        let (width, height, format) = inspect_reference_bytes(index, &self.contents)?;
        self.verify_metadata(index, width, height, format)
    }

    fn verify_metadata(
        &self,
        index: usize,
        width: u32,
        height: u32,
        format: ImageFormat,
    ) -> Result<()> {
        let bytes = u64::try_from(self.contents.len())
            .map_err(|_| reference_error(index, "快照大小无法表示"))?;
        let sha256 = hex::encode(Sha256::digest(&self.contents));
        if bytes != self.metadata.bytes
            || width != self.metadata.width
            || height != self.metadata.height
            || format != format_for_extension(self.metadata.extension)
            || sha256 != self.metadata.sha256
        {
            return Err(reference_error(index, "快照校验不一致，请重新选择该文件"));
        }
        Ok(())
    }
}

/// Validates user-selected reference images without reflecting their local
/// filesystem paths into errors. The leaf itself must be a regular file; a
/// symlink is rejected even when its target is an otherwise valid image.
pub fn validate_reference_inputs(paths: &[String]) -> Result<Vec<ValidatedReference>> {
    Ok(load_reference_snapshots(paths)?
        .into_iter()
        .map(|snapshot| snapshot.metadata)
        .collect())
}

/// Reads every selected reference exactly once through an `O_NOFOLLOW`
/// descriptor and retains the validated bytes for all later consumers. The
/// aggregate limits are enforced on those same snapshots.
pub(crate) fn load_reference_snapshots(
    paths: &[String],
) -> Result<Vec<ValidatedReferenceSnapshot>> {
    validate_reference_count(paths)?;

    let mut total_bytes = 0u64;
    let mut validated = Vec::with_capacity(paths.len());
    for (index, raw_path) in paths.iter().enumerate() {
        let reference = read_validated_reference(index, Path::new(raw_path))?;
        add_reference_bytes(index, &mut total_bytes, reference.metadata.bytes)?;
        validated.push(reference);
    }
    Ok(validated)
}

/// Copies reference inputs into a private generation workspace from the exact
/// byte snapshots that passed validation. Every staged file is then reopened
/// without following symlinks, fully decoded again, and compared with its
/// source snapshot before the directory is published. A failure removes the
/// candidate staging directory and leaves any previously published directory
/// intact.
pub(crate) fn stage_reference_inputs(
    paths: &[String],
    destination: &Path,
) -> Result<Vec<ValidatedReference>> {
    stage_reference_inputs_with_hooks(paths, destination, |_, _| Ok(()), |_, _| Ok(()))
}

/// Performs the lightweight checks needed to disclose one job-local reference
/// path in the frequently refreshed recovery projection. Unlike the actual
/// generation/retry validator, this intentionally reads only the 12-byte
/// PNG/WebP header: full pixel decoding here would put up to 64 MP of work on
/// every `state.wait` snapshot. The consuming generation path still reopens
/// and fully validates the staged copies before using them.
///
/// The directory is already pinned by a descriptor. `statat` plus
/// `openat(O_NOFOLLOW)` binds the header to the entry that passed owner, link,
/// type, size, and identity checks and rejects leaf replacement races.
pub(crate) fn validate_private_recovery_reference_at<Fd: AsFd>(
    directory: Fd,
    index: usize,
    file_name: &Path,
) -> Result<u64> {
    if file_name.file_name() != Some(file_name.as_os_str()) {
        return Err(reference_error(index, "暂存文件名无效，请重新选择该文件"));
    }
    let extension = supported_extension(index, file_name)?;
    let observed = rustix::fs::statat(&directory, file_name, rustix::fs::AtFlags::SYMLINK_NOFOLLOW)
        .map_err(|_| reference_error(index, "暂存副本不可用，请重新选择该文件"))?;
    let current_uid = rustix::process::geteuid().as_raw();
    if !rustix::fs::FileType::from_raw_mode(observed.st_mode).is_file()
        || observed.st_uid != current_uid
        || observed.st_nlink != 1
        || observed.st_size < 0
        || u64::try_from(observed.st_size).unwrap_or(u64::MAX) > MAX_REFERENCE_FILE_BYTES
    {
        return Err(reference_error(
            index,
            "暂存副本不是安全的私有普通文件，请重新选择该文件",
        ));
    }
    let descriptor = rustix::fs::openat(
        &directory,
        file_name,
        rustix::fs::OFlags::RDONLY
            | rustix::fs::OFlags::NONBLOCK
            | rustix::fs::OFlags::NOFOLLOW
            | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    )
    .map_err(|_| reference_error(index, "暂存副本不可用，请重新选择该文件"))?;
    let opened = rustix::fs::fstat(&descriptor)
        .map_err(|_| reference_error(index, "无法读取暂存副本信息"))?;
    if !rustix::fs::FileType::from_raw_mode(observed.st_mode).is_file()
        || !rustix::fs::FileType::from_raw_mode(opened.st_mode).is_file()
        || observed.st_uid != current_uid
        || opened.st_uid != current_uid
        || observed.st_nlink != 1
        || opened.st_nlink != 1
        || observed.st_dev != opened.st_dev
        || observed.st_ino != opened.st_ino
        || observed.st_size != opened.st_size
        || opened.st_size < 0
        || u64::try_from(opened.st_size).unwrap_or(u64::MAX) > MAX_REFERENCE_FILE_BYTES
    {
        return Err(reference_error(
            index,
            "暂存副本不是安全的私有普通文件，请重新选择该文件",
        ));
    }

    let bytes =
        u64::try_from(opened.st_size).map_err(|_| reference_error(index, "大小无法表示"))?;
    let mut file = File::from(descriptor);
    let mut header = [0u8; 12];
    file.read_exact(&mut header)
        .map_err(|_| reference_error(index, "暂存副本头部损坏，请重新选择该文件"))?;
    let final_metadata =
        rustix::fs::fstat(&file).map_err(|_| reference_error(index, "无法复核暂存副本信息"))?;
    if final_metadata.st_dev != opened.st_dev
        || final_metadata.st_ino != opened.st_ino
        || final_metadata.st_size != opened.st_size
        || final_metadata.st_uid != current_uid
        || final_metadata.st_nlink != 1
    {
        return Err(reference_error(
            index,
            "暂存副本在读取时发生变化，请重新选择该文件",
        ));
    }
    let header_matches_extension = match extension {
        "png" => header.starts_with(&[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]),
        "webp" => &header[..4] == b"RIFF" && &header[8..12] == b"WEBP",
        _ => false,
    };
    if !header_matches_extension {
        return Err(reference_error(
            index,
            "暂存副本扩展名与文件头不一致，请重新选择该文件",
        ));
    }
    Ok(bytes)
}

fn stage_reference_inputs_with_hooks<AfterSourceRead, AfterStageWrite>(
    paths: &[String],
    destination: &Path,
    mut after_source_read: AfterSourceRead,
    mut after_stage_write: AfterStageWrite,
) -> Result<Vec<ValidatedReference>>
where
    AfterSourceRead: FnMut(usize, &Path) -> Result<()>,
    AfterStageWrite: FnMut(usize, &Path) -> Result<()>,
{
    validate_reference_count(paths)?;
    let parent = destination.parent().ok_or_else(staging_failed)?;
    fs::create_dir_all(parent).map_err(|_| staging_failed())?;
    let staging = tempfile::Builder::new()
        .prefix(".apc-reference-staging-")
        .tempdir_in(parent)
        .map_err(|_| staging_failed())?;

    let mut total_bytes = 0u64;
    let mut staged = Vec::with_capacity(paths.len());
    for (index, raw_path) in paths.iter().enumerate() {
        let source_path = Path::new(raw_path);
        let source = read_validated_reference(index, source_path)?;
        add_reference_bytes(index, &mut total_bytes, source.metadata.bytes)?;
        after_source_read(index, source_path)?;

        let staged_path = staging.path().join(format!(
            "reference-{index:02}.{}",
            source.metadata.extension
        ));
        write_staged_reference(index, &staged_path, &source.contents)?;
        after_stage_write(index, &staged_path)?;

        let staged_reference = read_validated_reference(index, &staged_path)?;
        if !same_reference_content(&source.metadata, &staged_reference.metadata) {
            return Err(reference_error(index, "暂存后校验不一致，请重新选择该文件"));
        }
        let mut metadata = staged_reference.metadata;
        metadata.source = destination.join(staged_path.file_name().ok_or_else(staging_failed)?);
        staged.push(metadata);
    }

    publish_staged_directory(&staging, destination)?;
    Ok(staged)
}

fn validate_reference_count(paths: &[String]) -> Result<()> {
    if paths.len() > MAX_REFERENCE_IMAGES {
        return Err(PetCoreError::InvalidRequest(format!(
            "参考图最多允许 {MAX_REFERENCE_IMAGES} 张"
        )));
    }
    Ok(())
}

fn add_reference_bytes(index: usize, total: &mut u64, bytes: u64) -> Result<()> {
    *total = total
        .checked_add(bytes)
        .ok_or_else(|| reference_error(index, "总大小计算溢出"))?;
    if *total > MAX_REFERENCE_TOTAL_BYTES {
        return Err(PetCoreError::InvalidRequest(format!(
            "参考图总大小超过 {} MiB 限制",
            MAX_REFERENCE_TOTAL_BYTES / (1024 * 1024)
        )));
    }
    Ok(())
}

fn read_validated_reference(index: usize, path: &Path) -> Result<ValidatedReferenceSnapshot> {
    let extension = supported_extension(index, path)?;
    let path_metadata = fs::symlink_metadata(path)
        .map_err(|_| reference_error(index, "不可用、文件不存在或不可读取"))?;
    if path_metadata.file_type().is_symlink() || !path_metadata.file_type().is_file() {
        return Err(reference_error(index, "必须是普通文件，不能使用符号链接"));
    }

    let descriptor = rustix::fs::open(
        path,
        rustix::fs::OFlags::RDONLY | rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    )
    .map_err(|_| reference_error(index, "不可用、文件不存在或不可读取"))?;
    let file = File::from(descriptor);
    let opened = file
        .metadata()
        .map_err(|_| reference_error(index, "无法读取文件信息"))?;
    if !opened.is_file()
        || opened.dev() != path_metadata.dev()
        || opened.ino() != path_metadata.ino()
    {
        return Err(reference_error(index, "在打开时发生变化，请重新选择"));
    }
    let contents = read_reference_contents(index, file, i64::try_from(opened.len()).unwrap_or(-1))?;
    validated_reference_snapshot(index, path, extension, contents)
}

fn read_reference_contents(index: usize, mut file: File, advertised_len: i64) -> Result<Vec<u8>> {
    let advertised_len =
        u64::try_from(advertised_len).map_err(|_| reference_error(index, "大小无法表示"))?;
    if advertised_len > MAX_REFERENCE_FILE_BYTES {
        return Err(reference_error(
            index,
            &format!(
                "超过单文件 {} MiB 限制",
                MAX_REFERENCE_FILE_BYTES / (1024 * 1024)
            ),
        ));
    }
    let mut contents = Vec::with_capacity(usize::try_from(advertised_len).unwrap_or(0));
    Read::by_ref(&mut file)
        .take(MAX_REFERENCE_FILE_BYTES + 1)
        .read_to_end(&mut contents)
        .map_err(|_| reference_error(index, "读取失败"))?;
    let bytes =
        u64::try_from(contents.len()).map_err(|_| reference_error(index, "大小无法表示"))?;
    if bytes > MAX_REFERENCE_FILE_BYTES {
        return Err(reference_error(
            index,
            &format!(
                "超过单文件 {} MiB 限制",
                MAX_REFERENCE_FILE_BYTES / (1024 * 1024)
            ),
        ));
    }
    Ok(contents)
}

fn validated_reference_snapshot(
    index: usize,
    path: &Path,
    extension: &'static str,
    contents: Vec<u8>,
) -> Result<ValidatedReferenceSnapshot> {
    let bytes =
        u64::try_from(contents.len()).map_err(|_| reference_error(index, "大小无法表示"))?;
    let (width, height, actual_format) = inspect_reference_bytes(index, &contents)?;
    let expected_format = format_for_extension(extension);
    if actual_format != expected_format {
        return Err(reference_error(index, "扩展名与实际格式不一致"));
    }
    let sha256 = hex::encode(Sha256::digest(&contents));
    Ok(ValidatedReferenceSnapshot {
        metadata: ValidatedReference {
            source: path.to_path_buf(),
            extension,
            width,
            height,
            bytes,
            sha256,
        },
        contents,
    })
}

fn inspect_reference_bytes(index: usize, contents: &[u8]) -> Result<(u32, u32, ImageFormat)> {
    let (width, height, format, _) = decode_reference_bytes(index, contents)?;
    Ok((width, height, format))
}

fn decode_reference_bytes(
    index: usize,
    contents: &[u8],
) -> Result<(u32, u32, ImageFormat, DynamicImage)> {
    let reader = ImageReader::new(Cursor::new(contents))
        .with_guessed_format()
        .map_err(|_| reference_error(index, "无法识别格式；仅支持 PNG 和 WebP"))?;
    let actual_format = reader
        .format()
        .ok_or_else(|| reference_error(index, "无法识别格式；仅支持 PNG 和 WebP"))?;
    if !matches!(actual_format, ImageFormat::Png | ImageFormat::WebP) {
        return Err(reference_error(index, "仅支持 PNG 和 WebP"));
    }
    let (width, height) = reader
        .into_dimensions()
        .map_err(|_| reference_error(index, "尺寸信息无效"))?;
    let pixels = u64::from(width)
        .checked_mul(u64::from(height))
        .ok_or_else(|| reference_error(index, "像素数溢出"))?;
    if pixels > MAX_REFERENCE_PIXELS {
        return Err(reference_error(
            index,
            &format!("超过 {MAX_REFERENCE_PIXELS} 像素限制"),
        ));
    }

    // Decode after the cheap format, byte and pixel checks so malformed data
    // and decompression bombs cannot enter the generation workspace.
    let decoded = ImageReader::new(Cursor::new(contents))
        .with_guessed_format()
        .map_err(|_| reference_error(index, "无法读取格式"))?
        .decode()
        .map_err(|_| reference_error(index, "图片内容损坏或无法解码"))?;
    Ok((width, height, actual_format, decoded))
}

fn write_staged_reference(index: usize, path: &Path, contents: &[u8]) -> Result<()> {
    write_reference_bytes(index, path, contents, "暂存失败")
}

fn write_reference_bytes(
    index: usize,
    path: &Path,
    contents: &[u8],
    failure_detail: &str,
) -> Result<()> {
    let descriptor = rustix::fs::open(
        path,
        rustix::fs::OFlags::WRONLY
            | rustix::fs::OFlags::CREATE
            | rustix::fs::OFlags::EXCL
            | rustix::fs::OFlags::NOFOLLOW
            | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::from_bits_truncate(0o600),
    )
    .map_err(|_| reference_error(index, failure_detail))?;
    let mut file = File::from(descriptor);
    file.write_all(contents)
        .and_then(|_| file.sync_all())
        .map_err(|_| reference_error(index, failure_detail))
}

fn same_reference_content(left: &ValidatedReference, right: &ValidatedReference) -> bool {
    left.extension == right.extension
        && left.width == right.width
        && left.height == right.height
        && left.bytes == right.bytes
        && left.sha256 == right.sha256
}

fn publish_staged_directory(staging: &tempfile::TempDir, destination: &Path) -> Result<()> {
    let parent = destination.parent().ok_or_else(staging_failed)?;
    let existing = match fs::symlink_metadata(destination) {
        Ok(metadata) => Some(metadata),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(_) => return Err(staging_failed()),
    };
    if existing
        .as_ref()
        .is_some_and(|metadata| !metadata.file_type().is_dir())
    {
        return Err(staging_failed());
    }

    let backup = tempfile::Builder::new()
        .prefix(".apc-reference-backup-")
        .tempdir_in(parent)
        .map_err(|_| staging_failed())?;
    let backup_path = backup.path().join("previous");
    if existing.is_some() {
        fs::rename(destination, &backup_path).map_err(|_| staging_failed())?;
    }

    if fs::rename(staging.path(), destination).is_err() {
        if existing.is_some() {
            let _ = fs::rename(&backup_path, destination);
        }
        return Err(staging_failed());
    }
    Ok(())
}

fn supported_extension(index: usize, path: &Path) -> Result<&'static str> {
    match path
        .extension()
        .and_then(|value| value.to_str())
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("png") => Ok("png"),
        Some("webp") => Ok("webp"),
        _ => Err(reference_error(index, "仅支持 PNG 和 WebP")),
    }
}

fn format_for_extension(extension: &str) -> ImageFormat {
    match extension {
        "png" => ImageFormat::Png,
        "webp" => ImageFormat::WebP,
        _ => unreachable!("supported_extension returns only known formats"),
    }
}

fn reference_error(index: usize, detail: &str) -> PetCoreError {
    PetCoreError::InvalidRequest(format!("参考图 #{} {detail}", index + 1))
}

fn staging_failed() -> PetCoreError {
    PetCoreError::InvalidRequest("参考图暂存失败，请重新选择后重试".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageBuffer, Rgba};

    fn png(path: &Path, color: [u8; 4]) {
        ImageBuffer::from_pixel(8, 8, Rgba(color))
            .save_with_format(path, ImageFormat::Png)
            .unwrap();
    }

    #[test]
    fn staging_uses_the_validated_descriptor_snapshot_after_source_path_swap() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source.png");
        let replacement = temp.path().join("replacement.png");
        let destination = temp.path().join("job/input/references");
        png(&source, [10, 20, 30, 255]);
        png(&replacement, [220, 210, 200, 255]);
        let original_bytes = fs::read(&source).unwrap();
        let replacement_bytes = fs::read(&replacement).unwrap();
        let source_for_hook = source.clone();

        let staged = stage_reference_inputs_with_hooks(
            &[source.display().to_string()],
            &destination,
            move |_, _| {
                fs::write(&source_for_hook, &replacement_bytes)?;
                Ok(())
            },
            |_, _| Ok(()),
        )
        .unwrap();

        let staged_bytes = fs::read(&staged[0].source).unwrap();
        assert_eq!(staged_bytes, original_bytes);
        assert_ne!(staged_bytes, fs::read(&source).unwrap());
        assert_eq!(staged[0].sha256, hex::encode(Sha256::digest(&staged_bytes)));
    }

    #[test]
    fn staged_mismatch_is_rejected_and_candidate_directory_is_cleaned() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source.png");
        let replacement = temp.path().join("replacement.png");
        let destination = temp.path().join("job/input/references");
        png(&source, [10, 20, 30, 255]);
        png(&replacement, [220, 210, 200, 255]);
        let replacement_bytes = fs::read(replacement).unwrap();

        let error = stage_reference_inputs_with_hooks(
            &[source.display().to_string()],
            &destination,
            |_, _| Ok(()),
            move |_, staged_path| {
                fs::write(staged_path, &replacement_bytes)?;
                Ok(())
            },
        )
        .unwrap_err()
        .to_string();

        assert!(error.contains("暂存后校验不一致"), "{error}");
        assert!(!destination.exists());
        let parent = destination.parent().unwrap();
        assert!(fs::read_dir(parent).unwrap().all(|entry| !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .contains("staging")));
    }
}
