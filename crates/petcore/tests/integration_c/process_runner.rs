use petcore::process_runner::{run_bounded, ProcessSpec};
use rustix::process::{kill_process, test_kill_process, Pid, Signal};
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::thread;
use std::time::{Duration, Instant};

struct ProcessCleanup(Option<Pid>);

impl ProcessCleanup {
    fn disarm(&mut self) {
        self.0 = None;
    }
}

impl Drop for ProcessCleanup {
    fn drop(&mut self) {
        if let Some(pid) = self.0 {
            let _ = kill_process(pid, Signal::KILL);
        }
    }
}

struct ChildCleanup(Child);

impl Drop for ChildCleanup {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn compile_descendant_fixture(output_dir: &Path) -> PathBuf {
    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/process_runner_descendants.c");
    let binary = output_dir.join("process-runner-descendants");
    let output = Command::new("cc")
        .args(["-std=c11", "-Wall", "-Wextra", "-Werror"])
        .arg(&source)
        .arg("-o")
        .arg(&binary)
        .output()
        .expect("C compiler must be available for the real-process fixture");
    assert!(
        output.status.success(),
        "failed to compile process fixture\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    binary
}

fn read_pid(path: &Path) -> Pid {
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        if let Ok(value) = std::fs::read_to_string(path) {
            if let Ok(raw) = value.trim().parse::<i32>() {
                if let Some(pid) = Pid::from_raw(raw) {
                    return pid;
                }
            }
        }
        assert!(Instant::now() < deadline, "fixture did not publish its pid");
        thread::sleep(Duration::from_millis(5));
    }
}

fn wait_until_process_is_gone(pid: Pid) -> bool {
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        if test_kill_process(pid).is_err() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn hung_cli_is_terminated_at_deadline() {
    let started = Instant::now();
    let result = run_bounded(ProcessSpec::new(
        "/bin/sh",
        ["-c", "sleep 10"],
        Duration::from_millis(150),
    ))
    .expect("bounded process should start");

    assert!(result.timed_out, "hung child must be reported as timed out");
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "deadline must terminate the whole child process group promptly"
    );
}

#[test]
fn process_output_is_truncated() {
    let result = run_bounded(
        ProcessSpec::new(
            "/bin/sh",
            [
                "-c",
                "i=0; while [ $i -lt 4096 ]; do printf x; printf y >&2; i=$((i + 1)); done",
            ],
            Duration::from_secs(2),
        )
        .with_output_limits(128, 96),
    )
    .expect("bounded process should complete");

    assert!(result.status.success());
    assert_eq!(result.stdout.len(), 128);
    assert_eq!(result.stderr.len(), 96);
    assert!(result.stdout_truncated);
    assert!(result.stderr_truncated);
}

#[test]
fn descendant_holding_output_pipe_is_killed_with_process_group() {
    let started = Instant::now();
    let result = run_bounded(ProcessSpec::new(
        "/bin/sh",
        ["-c", "(trap '' TERM; sleep 10) & exit 0"],
        Duration::from_millis(150),
    ))
    .expect("bounded process should clean up descendants");

    assert!(result.status.success(), "group leader exits successfully");
    assert!(
        result.timed_out,
        "a descendant holding inherited pipes must consume the deadline"
    );
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[test]
fn descendant_that_closes_output_pipes_cannot_outlive_the_deadline() {
    let temp = tempfile::tempdir().unwrap();
    let fixture = compile_descendant_fixture(temp.path());
    let pid_file = temp.path().join("close-pipes.pid");
    let started = Instant::now();

    let result = run_bounded(ProcessSpec::new(
        &fixture,
        ["close-pipes", pid_file.to_str().unwrap()],
        // Compiling every workspace test can briefly saturate the host before
        // this freshly built fixture gets scheduled. Keep the deadline long
        // enough for it to fork and publish its PID while still proving that
        // the runner owns and terminates the pipe-closing descendant.
        Duration::from_secs(3),
    ))
    .expect("runner must enforce descendant ownership after both pipes close");
    let pid = read_pid(&pid_file);
    let mut cleanup = ProcessCleanup(Some(pid));

    assert!(result.status.success(), "fixture leader exits successfully");
    assert!(
        result.timed_out,
        "live owned descendant must consume deadline"
    );
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "runner exceeded its final cleanup deadline"
    );
    assert!(
        wait_until_process_is_gone(pid),
        "owned descendant remained alive after run_bounded returned"
    );
    cleanup.disarm();
}

#[test]
fn registered_double_fork_setsid_descendant_is_killed_by_exact_pid() {
    let temp = tempfile::tempdir().unwrap();
    let fixture = compile_descendant_fixture(temp.path());
    let pid_file = temp.path().join("double-fork.pid");
    let started = Instant::now();

    let result = run_bounded(ProcessSpec::new(
        &fixture,
        ["double-fork-setsid", pid_file.to_str().unwrap()],
        // The fixture compiles and forks alongside the rest of this test binary.
        // Leave enough time for the capability-file acknowledgement even on a
        // loaded CI host; the escaped descendant still keeps the command alive
        // until this explicit deadline.
        Duration::from_secs(3),
    ))
    .expect("runner must clean registered descendants that escape the process group");
    let pid = read_pid(&pid_file);
    let mut cleanup = ProcessCleanup(Some(pid));

    assert!(result.status.success(), "fixture leader exits successfully");
    assert!(
        result.timed_out,
        "registered daemon descendant must consume deadline"
    );
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "runner exceeded its final cleanup deadline"
    );
    assert!(
        wait_until_process_is_gone(pid),
        "registered escaped descendant remained alive after run_bounded returned"
    );
    cleanup.disarm();
}

#[test]
fn ownership_registry_rejects_pid_that_is_not_a_runner_descendant() {
    let victim = Command::new("/bin/sleep")
        .arg("10")
        .spawn()
        .expect("victim fixture must start");
    let victim_pid = victim.id().to_string();
    let mut victim = ChildCleanup(victim);

    let result = run_bounded(ProcessSpec::new(
        "/bin/sh",
        [
            "-c",
            "printf '%s\\n' \"$1\" >> \"$APC_PROCESS_RUNNER_OWNERSHIP_FILE_V1\"",
            "registry-writer",
            &victim_pid,
        ],
        Duration::from_millis(300),
    ))
    .expect("untrusted registry entry must not affect an unrelated process");

    assert!(result.status.success());
    assert!(
        !result.timed_out,
        "foreign PIDs must not extend the deadline"
    );
    assert!(
        victim.0.try_wait().unwrap().is_none(),
        "runner killed a process that was not descended from its command leader"
    );
}
