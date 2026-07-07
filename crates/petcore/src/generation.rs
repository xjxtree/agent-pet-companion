use crate::db::Database;
use crate::paths::AppPaths;
use crate::petpack::{build_petpack, import_petpack, write_sample_petpack_dir};
use crate::{new_id, now_rfc3339, Result};
use petcore_types::{GenerationForm, GenerationJobStatus};
use serde_json::json;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::thread;
use std::time::Duration;

pub fn start_generation(paths: &AppPaths, database: &Database, form: GenerationForm) -> Result<String> {
    let job_id = new_id("job");
    let job_dir = paths.jobs_dir.join(&job_id);
    fs::create_dir_all(&job_dir)?;
    fs::write(job_dir.join("form.json"), serde_json::to_vec_pretty(&form)?)?;
    database.create_generation_job(&job_id, &form, &job_dir)?;

    let paths = paths.clone();
    let database = database.clone();
    let job_id_for_thread = job_id.clone();
    thread::spawn(move || {
        if let Err(error) = run_mock_generation(&paths, &database, &job_id_for_thread, &form) {
            let _ = append_message(
                &paths,
                &job_id_for_thread,
                "assistant",
                &format!("生成失败：{error}"),
                1.0,
            );
            let _ = database.update_generation_job(
                &job_id_for_thread,
                GenerationJobStatus::Failed,
                None,
            );
        }
    });

    Ok(job_id)
}

pub fn read_messages(paths: &AppPaths, job_id: &str) -> Result<Vec<serde_json::Value>> {
    let path = paths.jobs_dir.join(job_id).join("messages.jsonl");
    if !path.exists() {
        return Ok(Vec::new());
    }
    let content = fs::read_to_string(path)?;
    Ok(content
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect())
}

fn run_mock_generation(
    paths: &AppPaths,
    database: &Database,
    job_id: &str,
    form: &GenerationForm,
) -> Result<()> {
    database.update_generation_job(job_id, GenerationJobStatus::Running, None)?;
    append_message(paths, job_id, "assistant", "已读取表单，开始生成宠物 brief。", 0.15)?;
    thread::sleep(Duration::from_millis(120));
    append_message(paths, job_id, "assistant", "主形象完成，正在生成 7 个状态动作。", 0.35)?;
    thread::sleep(Duration::from_millis(120));
    append_message(paths, job_id, "assistant", "正在渲染实机 PNG 帧并进行素材校验。", 0.62)?;

    let source_dir = paths.jobs_dir.join(job_id).join("petpack-source");
    let pet_name = if form.description.trim().is_empty() {
        "Cloud Maiden"
    } else {
        "Cloud Maiden"
    };
    let manifest =
        write_sample_petpack_dir(&source_dir, form.quality, pet_name, &form.style, 2)?;
    let output = paths.jobs_dir.join(job_id).join(format!("{}.petpack", manifest.id));
    build_petpack(&source_dir, &output)?;
    let pet = import_petpack(paths, database, &output)?;

    append_message(paths, job_id, "assistant", "校验通过，已保存 .petpack 并加入宠物库。", 0.9)?;
    database.update_generation_job(job_id, GenerationJobStatus::Completed, Some(&pet.id))?;
    append_message(paths, job_id, "assistant", "完成，可在宠物库启用。", 1.0)?;
    Ok(())
}

fn append_message(
    paths: &AppPaths,
    job_id: &str,
    role: &str,
    content: &str,
    progress: f64,
) -> Result<()> {
    let job_dir = paths.jobs_dir.join(job_id);
    fs::create_dir_all(&job_dir)?;
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(job_dir.join("messages.jsonl"))?;
    writeln!(
        file,
        "{}",
        serde_json::to_string(&json!({
            "role": role,
            "content": content,
            "progress": progress,
            "created_at": now_rfc3339(),
        }))?
    )?;
    Ok(())
}
