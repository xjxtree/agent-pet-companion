#!/usr/bin/env python3
"""Emit bounded, content-free engineering feedback and CI timing metrics."""

from __future__ import annotations

import argparse
from datetime import datetime
import json
import pathlib
import subprocess
import sys
from typing import Any, NoReturn

from development_domains import load_manifest, path_matches


SCHEMA_VERSION = "apc.engineering-metrics.v1"
MAX_INPUT_BYTES = 4 * 1024 * 1024
MAX_CHANGED_PATHS = 4096
MAX_JOBS = 256
MAX_STEPS_PER_JOB = 128
MAX_CACHES = 256
FALLBACK_CATEGORIES = {
    "none",
    "not-applicable",
    "control-plane-change",
    "expired",
    "ambiguous",
    "tree-mismatch",
    "missing-artifact",
    "unavailable",
}
HOTSPOTS = {
    "app-store": ("apps/macos/Sources/AgentPetCompanion/App/AppStore.swift",),
    "connections": ("crates/petcore/src/connections.rs", "crates/petcore/src/connections/**"),
    "rpc": ("crates/petcore/src/rpc.rs", "crates/petcore/src/rpc/**"),
    "storage": ("crates/petcore/src/db.rs", "crates/petcore/src/storage/**"),
    "global-localization": (
        "apps/macos/Sources/AgentPetCompanion/App/Localization.swift",
        "apps/macos/Sources/AgentPetCompanion/Resources/Localizable.xcstrings",
        "apps/macos/Sources/AgentPetCompanion/Resources/en.lproj/Localizable.strings",
        "apps/macos/Sources/AgentPetCompanion/Resources/zh-Hans.lproj/Localizable.strings",
    ),
    "root-changelog": ("CHANGELOG.md",),
}


def fail(message: str) -> NoReturn:
    raise ValueError(message)


def read_json(path: pathlib.Path) -> Any:
    metadata = path.lstat()
    if not path.is_file() or path.is_symlink() or metadata.st_size > MAX_INPUT_BYTES:
        fail(f"metrics input must be a bounded regular file: {path.name}")
    return json.loads(path.read_text(encoding="utf-8"))


def changed_paths(root: pathlib.Path, base_ref: str) -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", "--no-renames", f"{base_ref}...HEAD", "--"],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    paths = sorted({line for line in result.stdout.splitlines() if line})
    if len(paths) > MAX_CHANGED_PATHS:
        fail("changed-path inventory exceeds its bound")
    if any(path.startswith("/") or ".." in pathlib.PurePosixPath(path).parts for path in paths):
        fail("changed-path inventory contains an unsafe path")
    return paths


def parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def job_metrics(payload: Any, run_created_at: datetime | None = None) -> dict[str, Any]:
    jobs = payload.get("jobs") if isinstance(payload, dict) else payload
    if not isinstance(jobs, list) or len(jobs) > MAX_JOBS:
        fail("jobs input must contain a bounded jobs array")
    rows: list[dict[str, Any]] = []
    macos_seconds = 0
    linux_seconds = 0
    starts: list[datetime] = []
    ends: list[datetime] = []
    cache_restore_seconds = 0
    cache_save_seconds = 0
    for job in jobs:
        if not isinstance(job, dict):
            fail("jobs input contains a non-object")
        name = job.get("name")
        started = parse_timestamp(job.get("startedAt") or job.get("started_at"))
        completed = parse_timestamp(job.get("completedAt") or job.get("completed_at"))
        labels = job.get("labels", [])
        runner = str(job.get("runnerName") or job.get("runner_name") or "")
        if not isinstance(name, str) or len(name) > 160:
            fail("job name is invalid")
        duration = 0
        if started is not None and completed is not None:
            duration = max(0, int((completed - started).total_seconds()))
            starts.append(started)
            ends.append(completed)
        identity = " ".join(str(label) for label in labels) + " " + runner
        platform = "macos" if "macos" in identity.lower() else "linux" if "ubuntu" in identity.lower() or "linux" in identity.lower() else "unknown"
        if platform == "macos":
            macos_seconds += duration
        elif platform == "linux":
            linux_seconds += duration
        steps = job.get("steps", [])
        if not isinstance(steps, list) or len(steps) > MAX_STEPS_PER_JOB:
            fail("job steps must be a bounded array")
        for step in steps:
            if not isinstance(step, dict):
                fail("job steps contain a non-object")
            step_name = step.get("name")
            if not isinstance(step_name, str) or len(step_name) > 160:
                fail("job step name is invalid")
            normalized_name = step_name.lower()
            if "cache" not in normalized_name:
                continue
            step_started = parse_timestamp(step.get("startedAt") or step.get("started_at"))
            step_completed = parse_timestamp(
                step.get("completedAt") or step.get("completed_at")
            )
            step_seconds = (
                max(0, int((step_completed - step_started).total_seconds()))
                if step_started is not None and step_completed is not None
                else 0
            )
            if normalized_name.startswith("post ") or "save cache" in normalized_name:
                cache_save_seconds += step_seconds
            else:
                cache_restore_seconds += step_seconds
        rows.append({"name": name, "platform": platform, "duration_seconds": duration, "conclusion": job.get("conclusion")})
    rows.sort(key=lambda row: row["name"])
    wall = int((max(ends) - min(starts)).total_seconds()) if starts and ends else 0
    queue = (
        max(0, int((min(starts) - run_created_at).total_seconds()))
        if starts and run_created_at is not None
        else None
    )
    return {
        "jobs": rows,
        "queue_seconds": queue,
        "execution_seconds": max(0, wall),
        # The observed workflow wall is the stable DAG critical-path measure:
        # parallel job-minutes remain a separate resource-consumption metric.
        "critical_path_seconds": max(0, wall),
        "workflow_wall_seconds": max(0, wall),
        "macos_job_seconds": macos_seconds,
        "linux_job_seconds": linux_seconds,
        "cache_restore_seconds": cache_restore_seconds,
        "cache_save_seconds": cache_save_seconds,
    }


def cache_metrics(payload: Any, observed_at: datetime) -> dict[str, Any]:
    caches = payload.get("actions_caches") if isinstance(payload, dict) else None
    if not isinstance(caches, list) or len(caches) > MAX_CACHES:
        fail("cache input must contain a bounded actions_caches array")
    total_size = 0
    churn_size = 0
    for cache in caches:
        if not isinstance(cache, dict):
            fail("cache input contains a non-object")
        size = cache.get("size_in_bytes")
        created = parse_timestamp(cache.get("created_at"))
        if not isinstance(size, int) or size < 0:
            fail("cache size is invalid")
        total_size += size
        if created is not None and 0 <= (observed_at - created).total_seconds() <= 86_400:
            churn_size += size
    return {
        "listed_cache_count": len(caches),
        "listed_size_bytes": total_size,
        "created_last_24h_bytes": churn_size,
    }


def lifecycle_metrics(values: list[str | None]) -> dict[str, int | None]:
    created, ready, merged = (parse_timestamp(value) for value in values)
    return {
        "task_to_ready_seconds": (
            max(0, int((ready - created).total_seconds()))
            if created is not None and ready is not None
            else None
        ),
        "ready_to_merged_seconds": (
            max(0, int((merged - ready).total_seconds()))
            if ready is not None and merged is not None
            else None
        ),
    }


def change_metrics(root: pathlib.Path, paths: list[str]) -> dict[str, Any]:
    manifest = load_manifest(root)
    domains: dict[str, int] = {}
    amber: set[str] = set()
    red: set[str] = set()
    for path in paths:
        for domain in manifest.domains:
            if any(path_matches(path, pattern) for pattern in domain.owned_paths):
                domains[domain.id] = domains.get(domain.id, 0) + 1
            for shared in domain.shared_paths:
                if path_matches(path, shared.path):
                    (red if shared.risk == "red" else amber).add(path)
    hotspots = {
        name: sum(any(path_matches(path, pattern) for pattern in patterns) for path in paths)
        for name, patterns in HOTSPOTS.items()
    }
    return {
        "changed_path_count": len(paths),
        "domain_path_counts": dict(sorted(domains.items())),
        "amber_path_count": len(amber),
        "red_path_count": len(red),
        "hotspot_path_counts": hotspots,
    }


def render_summary(payload: dict[str, Any]) -> str:
    change = payload["change"]
    timing = payload.get("timing")
    proof = payload["proof"]
    coordination = payload["coordination"]
    lifecycle = payload["lifecycle"]
    lines = [
        "### Engineering feedback metrics",
        "",
        "| metric | value |",
        "|---|---:|",
        f"| changed paths | {change['changed_path_count']} |",
        f"| Amber paths | {change['amber_path_count']} |",
        f"| Red paths | {change['red_path_count']} |",
        f"| proof outcome | {proof['outcome']} |",
        f"| promotion fallback | {proof['fallback_category']} |",
        f"| claim-overlap rejections | {coordination['claim_overlap_rejections']} |",
        f"| merge-tree conflicts | {coordination['merge_tree_conflicts']} |",
        f"| train conflict resolutions | {coordination['train_conflict_resolutions']} |",
        f"| task-to-ready seconds | {lifecycle['task_to_ready_seconds'] if lifecycle['task_to_ready_seconds'] is not None else 'n/a'} |",
        f"| ready-to-merged seconds | {lifecycle['ready_to_merged_seconds'] if lifecycle['ready_to_merged_seconds'] is not None else 'n/a'} |",
    ]
    for name, observation in payload.get("cache_exact_hits", {}).items():
        lines.append(f"| exact cache `{name}` | {observation} |")
    if timing is not None:
        lines.extend(
            [
                f"| queue seconds | {timing['queue_seconds'] if timing['queue_seconds'] is not None else 'n/a'} |",
                f"| execution seconds | {timing['execution_seconds']} |",
                f"| workflow wall seconds | {timing['workflow_wall_seconds']} |",
                f"| observed critical path seconds | {timing['critical_path_seconds']} |",
                f"| macOS job-minutes | {timing['macos_job_seconds'] / 60:.2f} |",
                f"| Linux job-minutes | {timing['linux_job_seconds'] / 60:.2f} |",
                f"| cache restore seconds | {timing['cache_restore_seconds']} |",
                f"| cache save seconds | {timing['cache_save_seconds']} |",
            ]
        )
    cache_inventory = payload.get("cache_inventory")
    if cache_inventory is not None:
        lines.extend(
            [
                f"| listed cache count | {cache_inventory['listed_cache_count']} |",
                f"| listed cache MiB | {cache_inventory['listed_size_bytes'] / 1_048_576:.2f} |",
                f"| cache churn MiB (24h) | {cache_inventory['created_last_24h_bytes'] / 1_048_576:.2f} |",
            ]
        )
    lines.extend(["", "Domain and hotspot counts contain repository-relative metadata only; source contents are never collected.", ""])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--base-ref", required=True)
    parser.add_argument("--jobs-json", type=pathlib.Path)
    parser.add_argument("--cache-json", type=pathlib.Path)
    parser.add_argument("--run-created-at")
    parser.add_argument("--observed-at")
    parser.add_argument("--proof-outcome", choices=("promoted", "full-validation", "not-applicable"), default="not-applicable")
    parser.add_argument("--fallback-category", default="not-applicable")
    parser.add_argument("--cache-observation", action="append", default=[])
    parser.add_argument("--claim-overlap-rejections", type=int, default=0)
    parser.add_argument("--merge-tree-conflicts", type=int, default=0)
    parser.add_argument("--train-conflict-resolutions", type=int, default=0)
    parser.add_argument("--task-created-at")
    parser.add_argument("--ready-at")
    parser.add_argument("--merged-at")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--summary", type=pathlib.Path)
    args = parser.parse_args()
    try:
        root = args.root.resolve()
        payload: dict[str, Any] = {
            "schema_version": SCHEMA_VERSION,
            "base_ref": args.base_ref,
            "change": change_metrics(root, changed_paths(root, args.base_ref)),
            "proof": {
                "outcome": args.proof_outcome,
                "fallback_category": args.fallback_category,
            },
            "coordination": {
                "claim_overlap_rejections": args.claim_overlap_rejections,
                "merge_tree_conflicts": args.merge_tree_conflicts,
                "train_conflict_resolutions": args.train_conflict_resolutions,
            },
            "lifecycle": lifecycle_metrics(
                [args.task_created_at, args.ready_at, args.merged_at]
            ),
        }
        if args.fallback_category not in FALLBACK_CATEGORIES:
            fail("fallback category is not closed")
        if min(
            args.claim_overlap_rejections,
            args.merge_tree_conflicts,
            args.train_conflict_resolutions,
        ) < 0:
            fail("coordination counts must not be negative")
        observations: dict[str, str] = {}
        for observation in args.cache_observation:
            name, separator, value = observation.partition("=")
            if (
                not separator
                or not name.replace("-", "").replace("_", "").isalnum()
                or value not in {"true", "false", "skipped", "unavailable"}
                or name in observations
            ):
                fail("cache observation must be a unique name=true|false|skipped|unavailable")
            observations[name] = value
        payload["cache_exact_hits"] = dict(sorted(observations.items()))
        if args.jobs_json is not None:
            payload["timing"] = job_metrics(
                read_json(args.jobs_json.resolve()), parse_timestamp(args.run_created_at)
            )
        if args.cache_json is not None:
            observed_at = parse_timestamp(args.observed_at)
            if observed_at is None:
                fail("--cache-json requires --observed-at")
            payload["cache_inventory"] = cache_metrics(
                read_json(args.cache_json.resolve()), observed_at
            )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
        summary = render_summary(payload)
        if args.summary is not None:
            args.summary.write_text(summary, encoding="utf-8")
        print(summary, end="")
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"engineering metrics: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
