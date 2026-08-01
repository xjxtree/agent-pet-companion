#[cfg(target_os = "macos")]
mod macos {
    use petcore::petpack::write_sample_petpack_dir;
    use petcore_types::QualityLevel;
    use std::fs;
    use std::os::macos::fs::MetadataExt;
    use std::process::Command;
    use std::thread;
    use std::time::{Duration, Instant};

    const UF_HIDDEN: u32 = 0x0000_8000;

    #[test]
    fn petpack_build_publishes_a_finder_visible_output() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("petpack-source");
        let output = temp.path().join("Visible.petpack");
        write_sample_petpack_dir(&source, QualityLevel::Standard, "Visible Pet", "storybook")
            .unwrap();

        let build_parent = temp.path().to_path_buf();
        let metadata_writer = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(15);
            while Instant::now() < deadline {
                for entry in fs::read_dir(&build_parent).unwrap().flatten() {
                    let name = entry.file_name();
                    if !name.to_string_lossy().starts_with(".apc-petpack-build-") {
                        continue;
                    }
                    let staged_output = entry.path().join("package.petpack");
                    if !staged_output.is_file() {
                        continue;
                    }
                    let status = Command::new("/usr/bin/chflags")
                        .arg("hidden")
                        .arg(&staged_output)
                        .status();
                    if status.is_ok_and(|status| status.success()) {
                        return;
                    }
                }
                thread::sleep(Duration::from_millis(1));
            }
            panic!("did not observe PetCore's staged package");
        });

        let result = Command::new(env!("CARGO_BIN_EXE_petcore-cli"))
            .args([
                "petpack",
                "build",
                "--input",
                source.to_str().unwrap(),
                "--output",
                output.to_str().unwrap(),
            ])
            .output()
            .unwrap();
        metadata_writer.join().unwrap();

        assert!(
            result.status.success(),
            "petpack build failed: {}",
            String::from_utf8_lossy(&result.stderr)
        );
        let flags = fs::metadata(&output).unwrap().st_flags();
        assert_eq!(
            flags & UF_HIDDEN,
            0,
            "petpack build must clear the macOS UF_HIDDEN flag before publishing"
        );
    }
}
