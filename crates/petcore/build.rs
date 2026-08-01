use sha2::{Digest, Sha256};
use std::env;
use std::fs;
use std::path::{Component, Path, PathBuf};

const CONTRACT_FILE_LIST: &str = "script/interaction-contract-files.txt";

fn main() {
    let manifest_dir = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let repository_root = manifest_dir
        .parent()
        .and_then(Path::parent)
        .expect("petcore must remain under crates/petcore");
    let list_path = repository_root.join(CONTRACT_FILE_LIST);
    let list = fs::read_to_string(&list_path).expect("interaction contract file list must be read");
    let files = list
        .lines()
        .filter(|line| !line.is_empty())
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();
    assert!(!files.is_empty(), "interaction contract file list is empty");
    assert!(
        files.windows(2).all(|pair| pair[0] < pair[1]),
        "interaction contract file list must be sorted and unique"
    );

    println!("cargo:rerun-if-changed={}", list_path.display());
    let mut digest = Sha256::new();
    for relative in files {
        let relative_path = Path::new(&relative);
        assert!(
            !relative_path.is_absolute()
                && relative_path
                    .components()
                    .all(|component| matches!(component, Component::Normal(_))),
            "interaction contract path must be a safe repository-relative path: {relative}"
        );
        let path = repository_root.join(relative_path);
        let metadata = fs::symlink_metadata(&path).unwrap_or_else(|error| {
            panic!("interaction contract file {relative} is invalid: {error}")
        });
        assert!(
            metadata.file_type().is_file() && !metadata.file_type().is_symlink(),
            "interaction contract entry must be a regular file: {relative}"
        );
        let bytes = fs::read(&path).unwrap_or_else(|error| {
            panic!("interaction contract file {relative} cannot be read: {error}")
        });
        digest.update(relative.as_bytes());
        digest.update(b"\0");
        digest.update(bytes);
        digest.update(b"\0");
        println!("cargo:rerun-if-changed={}", path.display());
    }
    println!(
        "cargo:rustc-env=APC_INTERACTION_CONTRACT_DIGEST={}",
        hex::encode(digest.finalize())
    );
}
