#!/usr/bin/env python3
"""Coordinate direct and train-based multi-session development safely.

State is stored under Git's common directory so every worktree created from the
same checkout observes the same active train. Mutating commands are dry-run by
default and require ``--apply``.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from dataclasses import asdict, dataclass
from typing import Any, NoReturn

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from development_domains import (  # noqa: E402
    DOMAIN_ID,
    Manifest,
    load_manifest,
    path_matches,
    patterns_overlap,
    validate_relative_pattern,
)


SCHEMA_VERSION = "apc.development-flow.v3"
PREVIOUS_SCHEMA_VERSION = "apc.development-flow.v2"
LEGACY_SCHEMA_VERSION = "apc.development-flow.v1"
COORDINATION_SCHEMA_VERSION = "apc.engineering-coordination.v1"
COORDINATION_FIELDS = (
    "claim_overlap_rejections",
    "merge_tree_conflicts",
    "train_conflict_resolutions",
)
MAIN_BRANCH = "main"
TRAIN_PREFIX = "gd-ops/train/"
TASK_PREFIX = "gd-ops/task/"
FIX_PREFIX = "gd-ops/fix/"
RELEASE_PREFIX = "gd-ops/release/"
TRAIN_PATTERN = re.compile(r"gd-ops/train/[a-z0-9][a-z0-9._-]{0,63}")
WORK_PATTERN = re.compile(r"gd-ops/(?:task|fix|release)/[A-Za-z0-9._-]+-[a-z0-9][a-z0-9._-]{0,63}")
RELEASE_PATTERN = re.compile(r"gd-ops/release/[A-Za-z0-9._-]+-[a-z0-9][a-z0-9._-]{0,63}")
TOKEN_PATTERN = re.compile(r"[A-Za-z0-9._-]+")
SLUG_PATTERN = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")


def fail(message: str) -> NoReturn:
    raise ValueError(message)


class ClaimOverlapError(ValueError):
    """An exclusive/domain/Red claim collision rejected before mutation."""


def run(
    command: list[str],
    *,
    cwd: pathlib.Path,
    check: bool = True,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        text=True,
        input=input_text,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        fail(f"command failed ({' '.join(command)}): {detail}")
    return result


def repository_root(root: pathlib.Path) -> pathlib.Path:
    value = run(
        ["git", "rev-parse", "--show-toplevel"], cwd=root.resolve()
    ).stdout.strip()
    resolved = pathlib.Path(value).resolve()
    if not resolved.is_dir():
        fail("Git repository root is unavailable")
    return resolved


def common_state_paths(root: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    common = run(
        ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
        cwd=root,
    ).stdout.strip()
    common_path = pathlib.Path(common)
    if not common_path.is_absolute():
        common_path = (root / common_path).resolve()
    state_dir = common_path / "apc-development"
    return state_dir / "state.json", state_dir / "state.lock"


def empty_state() -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "active_train": None,
        "branches": {},
        "coordination": {field: 0 for field in COORDINATION_FIELDS},
    }


def validate_state(payload: dict[str, Any]) -> dict[str, Any]:
    if set(payload) != {"schema_version", "active_train", "branches", "coordination"}:
        fail("development-flow state field inventory is invalid")
    if payload.get("schema_version") != SCHEMA_VERSION:
        fail("development-flow state schema is unsupported")
    active_train = payload.get("active_train")
    if active_train is not None and TRAIN_PATTERN.fullmatch(active_train) is None:
        fail("development-flow active train is invalid")
    branches = payload.get("branches")
    if not isinstance(branches, dict) or len(branches) > 256:
        fail("development-flow branch context inventory is invalid")
    context_fields = {
        "base",
        "base_commit",
        "domain",
        "claim",
        "claimed_paths",
        "approved_shared_paths",
        "created_at",
        "worktree",
        "release_preparation",
        "control_plane_owner",
    }
    for branch, context in branches.items():
        if (
            not isinstance(branch, str)
            or (WORK_PATTERN.fullmatch(branch) is None and TRAIN_PATTERN.fullmatch(branch) is None)
            or not isinstance(context, dict)
            or set(context) != context_fields
        ):
            fail("development-flow branch context entry is invalid")
        base = context["base"]
        if not isinstance(base, str) or (
            base != MAIN_BRANCH and TRAIN_PATTERN.fullmatch(base) is None
        ):
            fail("development-flow branch base is invalid")
        base_commit = context["base_commit"]
        if base_commit is not None and (
            not isinstance(base_commit, str)
            or re.fullmatch(r"[0-9a-f]{40}", base_commit) is None
        ):
            fail("development-flow branch base commit is invalid")
        domain = context["domain"]
        claim = context["claim"]
        if (domain is None) != (claim is None):
            fail("development-flow legacy domain and claim must both be absent")
        if domain is not None and (
            not isinstance(domain, str)
            or DOMAIN_ID.fullmatch(domain) is None
            or not isinstance(claim, str)
            or DOMAIN_ID.fullmatch(claim) is None
        ):
            fail("development-flow domain claim is invalid")
        for field in ("claimed_paths", "approved_shared_paths"):
            patterns = context[field]
            if (
                not isinstance(patterns, list)
                or len(patterns) > 256
                or len(patterns) != len(set(patterns))
            ):
                fail(f"development-flow {field} is invalid")
            for pattern in patterns:
                validate_relative_pattern(pattern, field=f"development-flow {field}")
        if domain is None and (context["claimed_paths"] or context["approved_shared_paths"]):
            fail("legacy development-flow context cannot contain path claims")
        created_at = context["created_at"]
        if created_at is not None and (
            not isinstance(created_at, str)
            or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", created_at) is None
        ):
            fail("development-flow claim timestamp is invalid")
        worktree = context["worktree"]
        if worktree is not None and (
            not isinstance(worktree, str)
            or not pathlib.Path(worktree).is_absolute()
            or len(worktree) > 4096
            or "\x00" in worktree
        ):
            fail("development-flow worktree path is invalid")
        if not isinstance(context["release_preparation"], bool) or not isinstance(
            context["control_plane_owner"], bool
        ):
            fail("development-flow branch policy flags are invalid")
    coordination = payload.get("coordination")
    if not isinstance(coordination, dict) or set(coordination) != set(COORDINATION_FIELDS):
        fail("development-flow coordination field inventory is invalid")
    if any(
        not isinstance(coordination[field], int)
        or not 0 <= coordination[field] <= 1_000_000
        for field in COORDINATION_FIELDS
    ):
        fail("development-flow coordination count is invalid")
    return payload


def migrate_previous_state(payload: dict[str, Any]) -> dict[str, Any]:
    if set(payload) != {"schema_version", "active_train", "branches"}:
        fail("previous development-flow state field inventory is invalid")
    if payload.get("schema_version") != PREVIOUS_SCHEMA_VERSION:
        fail("development-flow state schema is unsupported")
    migrated = dict(payload)
    migrated["schema_version"] = SCHEMA_VERSION
    migrated["coordination"] = {field: 0 for field in COORDINATION_FIELDS}
    return validate_state(migrated)


def migrate_legacy_state(payload: dict[str, Any]) -> dict[str, Any]:
    if set(payload) != {"schema_version", "active_train", "branch_bases"}:
        fail("legacy development-flow state field inventory is invalid")
    if payload.get("schema_version") != LEGACY_SCHEMA_VERSION:
        fail("development-flow state schema is unsupported")
    branch_bases = payload.get("branch_bases")
    if not isinstance(branch_bases, dict) or len(branch_bases) > 256:
        fail("legacy development-flow branch inventory is invalid")
    migrated = empty_state()
    migrated["active_train"] = payload.get("active_train")
    for branch, base in branch_bases.items():
        migrated["branches"][branch] = {
            "base": base,
            "base_commit": None,
            "domain": None,
            "claim": None,
            "claimed_paths": [],
            "approved_shared_paths": [],
            "created_at": None,
            "worktree": None,
            "release_preparation": False,
            "control_plane_owner": False,
        }
    return validate_state(migrated)


def read_state(path: pathlib.Path) -> dict[str, Any]:
    if not path.exists():
        return empty_state()
    metadata = path.lstat()
    if not path.is_file() or path.is_symlink() or metadata.st_size > 256 * 1024:
        fail("development-flow state must be a bounded regular file")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        fail("development-flow state must contain one JSON object")
    if payload.get("schema_version") == LEGACY_SCHEMA_VERSION:
        return migrate_legacy_state(payload)
    if payload.get("schema_version") == PREVIOUS_SCHEMA_VERSION:
        return migrate_previous_state(payload)
    return validate_state(payload)


def update_state(root: pathlib.Path, transform: Any) -> dict[str, Any]:
    state_path, lock_path = common_state_paths(root)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        state = transform(read_state(state_path))
        validate_state(state)
        descriptor, temporary = tempfile.mkstemp(
            prefix=".state.", dir=state_path.parent
        )
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(state, handle, sort_keys=True, separators=(",", ":"))
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, state_path)
        finally:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
        return state


def record_coordination(root: pathlib.Path, event: str, count: int) -> dict[str, Any]:
    if event not in COORDINATION_FIELDS or not 1 <= count <= 10_000:
        fail("coordination event or count is invalid")

    def transform(state: dict[str, Any]) -> dict[str, Any]:
        updated = state["coordination"][event] + count
        if updated > 1_000_000:
            fail("development-flow coordination count exceeds its bound")
        state["coordination"][event] = updated
        return state

    return update_state(root, transform)


def coordination_marker(context: dict[str, Any], state: dict[str, Any]) -> str:
    created_at = context.get("created_at")
    if not isinstance(created_at, str):
        fail("branch claim timestamp is required for engineering metrics")
    payload = {
        "schema_version": COORDINATION_SCHEMA_VERSION,
        "task_created_at": created_at,
        **{field: state["coordination"][field] for field in COORDINATION_FIELDS},
    }
    return (
        "<!-- apc-engineering-coordination-v1 "
        + json.dumps(payload, sort_keys=True, separators=(",", ":"))
        + " -->"
    )


@dataclass(frozen=True)
class LaneDecision:
    lane: str
    base_branch: str | None
    reason: str
    active_train: str | None


def choose_lane(
    requested: str,
    *,
    hotfix: bool,
    small: bool,
    agents: int,
    cross_component: bool,
    active_train: str | None,
    explicit_train: str | None = None,
) -> LaneDecision:
    if agents <= 0:
        fail("agent count must be positive")
    train = explicit_train or active_train
    if train is not None and TRAIN_PATTERN.fullmatch(train) is None:
        fail("train branch must use gd-ops/train/<name>")
    if requested == "direct":
        return LaneDecision("direct", MAIN_BRANCH, "agent explicitly selected direct", train)
    if requested == "train":
        if train is None:
            fail("train lane requires --train or one active shared train")
        return LaneDecision("train", train, "agent explicitly selected train", train)
    if requested != "auto":
        fail("lane must be auto, direct, or train")
    if hotfix:
        return LaneDecision("direct", MAIN_BRANCH, "hotfix uses the direct lane", train)
    if train is not None:
        return LaneDecision("train", train, "shared active train is available", train)
    if agents > 1 or cross_component:
        return LaneDecision(
            "train",
            None,
            "parallel or cross-component work requires the main agent to start a train",
            None,
        )
    if small:
        return LaneDecision("direct", MAIN_BRANCH, "small isolated change", None)
    return LaneDecision(
        "direct",
        MAIN_BRANCH,
        "single-agent isolated work defaults to direct; the agent may choose train",
        None,
    )


@dataclass(frozen=True)
class CIContext:
    lane: str
    full_candidate: bool
    release_source: bool
    release_preparation: bool


def ci_context(event: str, base: str, head: str, draft: bool) -> CIContext:
    if event == "push":
        if base != MAIN_BRANCH:
            fail("authoritative push CI is restricted to main")
        return CIContext("main-push", True, True, False)
    if event != "pull_request":
        fail("CI development lane supports only pull_request and push")
    if base == MAIN_BRANCH:
        if TRAIN_PATTERN.fullmatch(head):
            lane = "train-to-main"
        elif RELEASE_PATTERN.fullmatch(head):
            lane = "release-preparation-to-main"
        else:
            lane = "direct-to-main"
        return CIContext(lane, not draft, False, RELEASE_PATTERN.fullmatch(head) is not None)
    if TRAIN_PATTERN.fullmatch(base):
        if WORK_PATTERN.fullmatch(head) is None:
            fail("a train accepts only gd-ops/task/* or gd-ops/fix/* pull requests")
        if RELEASE_PATTERN.fullmatch(head):
            fail("release preparation branches must target main")
        return CIContext("task-to-train", False, False, False)
    fail("pull request base must be main or gd-ops/train/<name>")


def ensure_new_branch(root: pathlib.Path, branch: str, worktree: pathlib.Path) -> None:
    if worktree.exists():
        fail(f"worktree path already exists: {worktree}")
    local = run(
        ["git", "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
        cwd=root,
        check=False,
    )
    if local.returncode == 0:
        fail(f"local branch already exists: {branch}")
    remote = run(
        ["git", "ls-remote", "--exit-code", "--heads", "origin", branch],
        cwd=root,
        check=False,
    )
    if remote.returncode == 0:
        fail(f"remote branch already exists: {branch}")
    if remote.returncode not in (0, 2):
        fail(f"could not inspect remote branch {branch}: {remote.stderr.strip()}")


def command_plan(commands: list[list[str]], **metadata: Any) -> None:
    print(
        json.dumps(
            {"apply": False, "commands": commands, **metadata},
            indent=2,
            sort_keys=True,
        )
    )


def claim_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def remote_base_commit(root: pathlib.Path, base: str) -> str:
    commit = run(
        ["git", "rev-parse", "--verify", f"refs/remotes/origin/{base}^{{commit}}"],
        cwd=root,
    ).stdout.strip()
    if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        fail("remote base commit is invalid")
    return commit


def selected_claim_context(
    manifest: Manifest,
    *,
    domain_id: str,
    claim_id: str,
    approved_shared_paths: list[str],
    control_plane_owner: bool,
    release_preparation: bool,
    base: str,
    base_commit: str,
    worktree: pathlib.Path,
) -> dict[str, Any]:
    domain = manifest.domain(domain_id)
    claim = domain.claim(claim_id)
    if domain.control_plane and not control_plane_owner:
        fail(
            f"domain {domain.id!r} is restricted to the declared control-plane owner"
        )
    approved: list[str] = []
    for pattern in approved_shared_paths:
        shared = domain.shared(pattern)
        if shared.risk == "red" and not control_plane_owner:
            fail(f"Red path {pattern!r} requires the control-plane owner")
        approved.append(pattern)
    if len(approved) != len(set(approved)):
        fail("approved shared paths contain duplicates")
    return {
        "base": base,
        "base_commit": base_commit,
        "domain": domain.id,
        "claim": claim.id,
        "claimed_paths": sorted(claim.paths),
        "approved_shared_paths": sorted(approved),
        "created_at": claim_timestamp(),
        "worktree": str(worktree),
        "release_preparation": release_preparation,
        "control_plane_owner": control_plane_owner,
    }


def context_pattern_risk(manifest: Manifest, context: dict[str, Any], pattern: str) -> str:
    domain_id = context.get("domain")
    if domain_id is None:
        return "legacy"
    domain = manifest.domain(domain_id)
    for shared in domain.shared_paths:
        if shared.path == pattern:
            return shared.risk
    return "owned"


def ensure_claim_available(
    manifest: Manifest,
    state: dict[str, Any],
    branch: str,
    context: dict[str, Any],
) -> None:
    domain = manifest.domain(context["domain"])
    for other_branch, other in state["branches"].items():
        if other_branch == branch or other["domain"] is None:
            continue
        other_domain = manifest.domain(other["domain"])
        overlaps = [
            (path, other_path)
            for path in context["claimed_paths"]
            for other_path in other["claimed_paths"]
            if patterns_overlap(path, other_path)
        ]
        if overlaps:
            raise ClaimOverlapError(
                f"exclusive path claim overlaps active branch {other_branch}: {overlaps[0]}"
            )
        if domain.id == other_domain.id and (
            not domain.allow_parallel_claims or not other_domain.allow_parallel_claims
        ):
            raise ClaimOverlapError(
                f"domain {domain.id!r} permits only one active claim; "
                f"branch {other_branch} already owns it"
            )
        for pattern in context["approved_shared_paths"]:
            for other_pattern in other["approved_shared_paths"]:
                if not patterns_overlap(pattern, other_pattern):
                    continue
                risks = {
                    context_pattern_risk(manifest, context, pattern),
                    context_pattern_risk(manifest, other, other_pattern),
                }
                if "red" in risks:
                    raise ClaimOverlapError(
                        f"Red path approval overlaps active branch {other_branch}: "
                        f"{pattern!r} and {other_pattern!r}"
                    )


def ensure_claim_available_recorded(
    root: pathlib.Path,
    manifest: Manifest,
    state: dict[str, Any],
    branch: str,
    context: dict[str, Any],
) -> None:
    try:
        ensure_claim_available(manifest, state, branch, context)
    except ClaimOverlapError:
        record_coordination(root, "claim_overlap_rejections", 1)
        raise


def context_allows_path(context: dict[str, Any], path: str) -> bool:
    return any(
        path_matches(path, pattern)
        for pattern in [*context["claimed_paths"], *context["approved_shared_paths"]]
    )


def changed_paths(root: pathlib.Path, base_commit: str) -> list[str]:
    result = run(
        ["git", "diff", "--name-only", "-z", base_commit, "HEAD", "--"],
        cwd=root,
    )
    return sorted(
        {
            os.fsdecode(item)
            for item in result.stdout.encode("utf-8", "surrogateescape").split(b"\0")
            if item
        }
    )


def focused_validation(manifest: Manifest, context: dict[str, Any]) -> list[str]:
    if context["domain"] is None:
        return []
    return [
        " ".join(command)
        for command in manifest.domain(context["domain"]).focused_tests
    ]


def repository_name(root: pathlib.Path) -> str:
    payload = json.loads(
        run(["gh", "repo", "view", "--json", "nameWithOwner"], cwd=root).stdout
    )
    value = payload.get("nameWithOwner")
    if not isinstance(value, str) or value.count("/") != 1:
        fail("GitHub repository identity is unavailable")
    return value


def train_start(args: argparse.Namespace, root: pathlib.Path) -> None:
    if SLUG_PATTERN.fullmatch(args.name) is None:
        fail("train name must be a lowercase slug")
    branch = f"{TRAIN_PREFIX}{args.name}"
    worktree = args.worktree.resolve()
    state_path, _ = common_state_paths(root)
    current_state = read_state(state_path)
    if current_state["active_train"] not in (None, branch):
        fail(f"another train is already active: {current_state['active_train']}")
    ensure_new_branch(root, branch, worktree)
    commands: list[list[str]] = [
        ["git", "fetch", "origin", MAIN_BRANCH],
        [
            "git",
            "worktree",
            "add",
            "-b",
            branch,
            str(worktree),
            f"refs/remotes/origin/{MAIN_BRANCH}",
        ],
        ["git", "-C", str(worktree), "push", "-u", "origin", branch],
    ]
    if not args.apply:
        command_plan(
            commands,
            lane="train",
            branch=branch,
            base=MAIN_BRANCH,
            domain=args.domain,
            claim=args.claim,
        )
        return
    run(commands[0], cwd=root)
    manifest = load_manifest(root)
    context = selected_claim_context(
        manifest,
        domain_id=args.domain,
        claim_id=args.claim,
        approved_shared_paths=args.approve_shared,
        control_plane_owner=args.control_plane_owner,
        release_preparation=False,
        base=MAIN_BRANCH,
        base_commit=remote_base_commit(root, MAIN_BRANCH),
        worktree=worktree,
    )
    ensure_claim_available_recorded(root, manifest, current_state, branch, context)
    run(commands[1], cwd=root)
    run(commands[2], cwd=root)

    def transform(state: dict[str, Any]) -> dict[str, Any]:
        if state["active_train"] not in (None, branch):
            fail(f"another train is already active: {state['active_train']}")
        state["active_train"] = branch
        ensure_claim_available(manifest, state, branch, context)
        state["branches"][branch] = context
        return state

    state = update_state(root, transform)
    print(json.dumps(state, indent=2, sort_keys=True))


def task_start(args: argparse.Namespace, root: pathlib.Path) -> None:
    if TOKEN_PATTERN.fullmatch(args.task) is None:
        fail("task identifier is invalid")
    if SLUG_PATTERN.fullmatch(args.slug) is None:
        fail("task slug must be lowercase")
    state_path, _ = common_state_paths(root)
    state = read_state(state_path)
    decision = choose_lane(
        args.lane,
        hotfix=args.hotfix,
        small=args.small,
        agents=args.agents,
        cross_component=args.cross_component,
        active_train=state["active_train"],
        explicit_train=args.train,
    )
    if decision.base_branch is None:
        fail("start a shared train before creating this parallel task worktree")
    if args.release_preparation and decision.base_branch != MAIN_BRANCH:
        fail("release preparation must use the direct lane to main")
    kind = "release" if args.release_preparation else "fix" if args.hotfix else "task"
    branch = f"gd-ops/{kind}/{args.task}-{args.slug}"
    if WORK_PATTERN.fullmatch(branch) is None:
        fail("generated work branch is invalid")
    worktree = args.worktree.resolve()
    ensure_new_branch(root, branch, worktree)
    base = decision.base_branch
    commands = [
        ["git", "fetch", "origin", base],
        [
            "git",
            "worktree",
            "add",
            "-b",
            branch,
            str(worktree),
            f"refs/remotes/origin/{base}",
        ],
    ]
    if not args.apply:
        command_plan(
            commands,
            lane=decision.lane,
            reason=decision.reason,
            branch=branch,
            base=base,
            domain=args.domain,
            claim=args.claim,
            release_preparation=args.release_preparation,
        )
        return
    run(commands[0], cwd=root)
    manifest = load_manifest(root)
    context = selected_claim_context(
        manifest,
        domain_id=args.domain,
        claim_id=args.claim,
        approved_shared_paths=args.approve_shared,
        control_plane_owner=args.control_plane_owner,
        release_preparation=args.release_preparation,
        base=base,
        base_commit=remote_base_commit(root, base),
        worktree=worktree,
    )
    ensure_claim_available_recorded(root, manifest, state, branch, context)
    run(commands[1], cwd=root)

    def transform(current: dict[str, Any]) -> dict[str, Any]:
        ensure_claim_available(manifest, current, branch, context)
        current["branches"][branch] = context
        return current

    update_state(root, transform)
    print(
        json.dumps(
            {"lane": decision.lane, "reason": decision.reason, "branch": branch, "base": base},
            indent=2,
            sort_keys=True,
        )
    )


def branch_claim(args: argparse.Namespace, root: pathlib.Path) -> None:
    worktree = args.worktree.resolve()
    branch = run(["git", "branch", "--show-current"], cwd=worktree).stdout.strip()
    if WORK_PATTERN.fullmatch(branch) is None and TRAIN_PATTERN.fullmatch(branch) is None:
        fail("claim target must be a managed task, fix, release, or train branch")
    state_path, _ = common_state_paths(root)
    state = read_state(state_path)
    existing = state["branches"].get(branch)
    if existing is None:
        fail("branch base metadata is missing; recreate the worktree with this tool")
    base = existing["base"]
    run(["git", "fetch", "origin", base], cwd=root)
    manifest = load_manifest(root)
    context = selected_claim_context(
        manifest,
        domain_id=args.domain,
        claim_id=args.claim,
        approved_shared_paths=args.approve_shared,
        control_plane_owner=args.control_plane_owner,
        release_preparation=args.release_preparation,
        base=base,
        base_commit=existing["base_commit"] or remote_base_commit(root, base),
        worktree=worktree,
    )
    if not args.apply:
        ensure_claim_available(manifest, state, branch, context)
        print(
            json.dumps(
                {"apply": False, "branch": branch, "context": context},
                indent=2,
                sort_keys=True,
            )
        )
        return
    ensure_claim_available_recorded(root, manifest, state, branch, context)

    def transform(current: dict[str, Any]) -> dict[str, Any]:
        if branch not in current["branches"]:
            fail("branch context disappeared while acquiring the state lock")
        ensure_claim_available(manifest, current, branch, context)
        current["branches"][branch] = context
        return current

    update_state(root, transform)
    print(json.dumps({"branch": branch, "context": context}, indent=2, sort_keys=True))


def branch_ref(root: pathlib.Path, branch: str) -> str | None:
    for ref in (branch, f"refs/remotes/origin/{branch}"):
        if run(["git", "rev-parse", "--verify", f"{ref}^{{commit}}"], cwd=root, check=False).returncode == 0:
            return ref
    return None


def conflicts(root: pathlib.Path, *, record: bool = False) -> None:
    state_path, _ = common_state_paths(root)
    state = read_state(state_path)
    manifest = load_manifest(root)
    branches = sorted(state["branches"])
    reports: list[dict[str, Any]] = []
    for index, first in enumerate(branches):
        first_context = state["branches"][first]
        for second in branches[index + 1 :]:
            second_context = state["branches"][second]
            claim_overlaps = sorted(
                {
                    f"{left} <> {right}"
                    for left in first_context["claimed_paths"]
                    for right in second_context["claimed_paths"]
                    if patterns_overlap(left, right)
                }
            )
            shared_overlaps = sorted(
                {
                    f"{left} <> {right}"
                    for left in first_context["approved_shared_paths"]
                    for right in second_context["approved_shared_paths"]
                    if patterns_overlap(left, right)
                }
            )
            order_dependency = False
            if first_context["domain"] and second_context["domain"]:
                first_domain = manifest.domain(first_context["domain"])
                second_domain = manifest.domain(second_context["domain"])
                order_dependency = (
                    second_domain.id in first_domain.dependencies
                    or first_domain.id in second_domain.dependencies
                    or bool(shared_overlaps)
                )
            first_ref = branch_ref(root, first)
            second_ref = branch_ref(root, second)
            textual_conflict: bool | None = None
            merge_detail = "branch ref unavailable"
            if first_ref is not None and second_ref is not None:
                result = run(
                    ["git", "merge-tree", "--write-tree", first_ref, second_ref],
                    cwd=root,
                    check=False,
                )
                textual_conflict = result.returncode != 0
                merge_detail = (result.stderr.strip() or result.stdout.strip())[:4000]
            if claim_overlaps or shared_overlaps or order_dependency or textual_conflict:
                reports.append(
                    {
                        "branches": [first, second],
                        "claim_overlaps": claim_overlaps,
                        "shared_interface_overlaps": shared_overlaps,
                        "shared_interface_order_dependency": order_dependency,
                        "textual_conflict": textual_conflict,
                        "merge_tree": merge_detail,
                    }
                )
    merge_tree_conflicts = sum(
        report["textual_conflict"] is True for report in reports
    )
    if record and merge_tree_conflicts:
        record_coordination(root, "merge_tree_conflicts", merge_tree_conflicts)
    print(
        json.dumps(
            {
                "active_branches": branches,
                "conflicts": reports,
                "recorded_merge_tree_conflicts": merge_tree_conflicts if record else 0,
            },
            indent=2,
            sort_keys=True,
        )
    )


def pr_open(args: argparse.Namespace, root: pathlib.Path) -> None:
    worktree = args.worktree.resolve()
    branch = run(
        ["git", "branch", "--show-current"], cwd=worktree
    ).stdout.strip()
    if WORK_PATTERN.fullmatch(branch) is None and TRAIN_PATTERN.fullmatch(branch) is None:
        fail("PR head must be a managed task, fix, or train branch")
    state_path, _ = common_state_paths(root)
    state = read_state(state_path)
    context = state["branches"].get(branch)
    if context is None:
        fail("branch base metadata is missing; recreate the worktree with this tool")
    if context["domain"] is None or context["base_commit"] is None:
        fail("branch has no typed path claim; run branch-claim before opening a PR")
    base = context["base"]
    manifest = load_manifest(root)
    manifest.domain(context["domain"]).claim(context["claim"])
    if context["release_preparation"] != (RELEASE_PATTERN.fullmatch(branch) is not None):
        fail("release preparation identity disagrees with the managed branch name")
    repository = repository_name(root)
    validation = focused_validation(manifest, context)
    metadata_body = "\n".join(
        [
            "## Development claim / 开发声明",
            "",
            f"- Domain: `{context['domain']}`",
            f"- Claim: `{context['claim']}`",
            f"- Base commit: `{context['base_commit']}`",
            f"- Release preparation: `{'yes' if context['release_preparation'] else 'no'}`",
            "- Focused validation:",
            *[f"  - `{command}`" for command in validation],
            "",
            coordination_marker(context, state),
        ]
    )
    if args.body_file:
        body_path = args.body_file.resolve()
        metadata = body_path.lstat()
        if not body_path.is_file() or body_path.is_symlink() or metadata.st_size > 256 * 1024:
            fail("PR body must be a bounded regular file")
        body = body_path.read_text(encoding="utf-8").rstrip() + "\n\n" + metadata_body
    else:
        body = metadata_body
    commands = [
        ["git", "fetch", "origin", base],
        ["git", "-C", str(worktree), "push", "-u", "origin", branch],
        [
            "gh",
            "pr",
            "create",
            "--repo",
            repository,
            "--head",
            branch,
            "--base",
            base,
            "--title",
            args.title,
            "--body",
            body,
            *([] if args.ready else ["--draft"]),
        ],
    ]
    if not args.apply:
        command_plan(
            commands,
            branch=branch,
            base=base,
            ready=args.ready,
            domain=context["domain"],
            claim=context["claim"],
            focused_validation=validation,
        )
        return
    if run(["git", "status", "--porcelain"], cwd=worktree).stdout.strip():
        fail("PR worktree must be clean before push")
    run(commands[0], cwd=root)
    if run(
        ["git", "merge-base", "--is-ancestor", context["base_commit"], "HEAD"],
        cwd=worktree,
        check=False,
    ).returncode != 0:
        fail("recorded branch base is not an ancestor of the PR head")
    paths = changed_paths(worktree, context["base_commit"])
    outside = [path for path in paths if not context_allows_path(context, path)]
    if outside:
        fail("PR diff exceeds the declared path claim: " + ", ".join(outside))
    run(commands[1], cwd=root)
    local_head = run(["git", "rev-parse", "HEAD"], cwd=worktree).stdout.strip()
    remote = run(["git", "ls-remote", "--heads", "origin", branch], cwd=root).stdout.strip().split()
    if len(remote) != 2 or remote[0] != local_head:
        fail("remote PR branch SHA does not match the clean local head")
    created = run(commands[2], cwd=root).stdout.strip()
    if not created.startswith("https://github.com/"):
        fail("gh did not return a pull request URL")
    print(
        json.dumps(
            {
                "url": created,
                "branch": branch,
                "base": base,
                "head": local_head,
                "domain": context["domain"],
                "claim": context["claim"],
                "changed_paths": paths,
                "focused_validation": validation,
            },
            sort_keys=True,
        )
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    subparsers = parser.add_subparsers(dest="command", required=True)

    decide = subparsers.add_parser("decide")
    decide.add_argument("--lane", choices=("auto", "direct", "train"), default="auto")
    decide.add_argument("--hotfix", action="store_true")
    decide.add_argument("--small", action="store_true")
    decide.add_argument("--agents", type=int, default=1)
    decide.add_argument("--cross-component", action="store_true")
    decide.add_argument("--train")

    ci = subparsers.add_parser("ci-context")
    ci.add_argument("--event", choices=("pull_request", "push"), required=True)
    ci.add_argument("--base", required=True)
    ci.add_argument("--head", default="")
    ci.add_argument("--draft", choices=("true", "false"), default="false")
    ci.add_argument("--format", choices=("json", "github"), default="json")

    status = subparsers.add_parser("status")
    status.set_defaults()

    train = subparsers.add_parser("train-start")
    train.add_argument("--name", required=True)
    train.add_argument("--worktree", type=pathlib.Path, required=True)
    train.add_argument("--domain", required=True)
    train.add_argument("--claim", required=True)
    train.add_argument("--approve-shared", action="append", default=[])
    train.add_argument("--control-plane-owner", action="store_true")
    train.add_argument("--apply", action="store_true")

    clear = subparsers.add_parser("train-clear")
    clear.add_argument("--train", required=True)
    clear.add_argument("--apply", action="store_true")

    task = subparsers.add_parser("task-start")
    task.add_argument("--task", required=True)
    task.add_argument("--slug", required=True)
    task.add_argument("--worktree", type=pathlib.Path, required=True)
    task.add_argument("--lane", choices=("auto", "direct", "train"), default="auto")
    task.add_argument("--train")
    task.add_argument("--hotfix", action="store_true")
    task.add_argument("--small", action="store_true")
    task.add_argument("--agents", type=int, default=1)
    task.add_argument("--cross-component", action="store_true")
    task.add_argument("--domain", required=True)
    task.add_argument("--claim", required=True)
    task.add_argument("--approve-shared", action="append", default=[])
    task.add_argument("--control-plane-owner", action="store_true")
    task.add_argument("--release-preparation", action="store_true")
    task.add_argument("--apply", action="store_true")

    claim = subparsers.add_parser("branch-claim")
    claim.add_argument("--worktree", type=pathlib.Path, required=True)
    claim.add_argument("--domain", required=True)
    claim.add_argument("--claim", required=True)
    claim.add_argument("--approve-shared", action="append", default=[])
    claim.add_argument("--control-plane-owner", action="store_true")
    claim.add_argument("--release-preparation", action="store_true")
    claim.add_argument("--apply", action="store_true")

    conflicts_parser = subparsers.add_parser("conflicts")
    conflicts_parser.add_argument("--record", action="store_true")

    coordination = subparsers.add_parser("coordination-record")
    coordination.add_argument("--event", choices=COORDINATION_FIELDS, required=True)
    coordination.add_argument("--count", type=int, default=1)
    coordination.add_argument("--apply", action="store_true")

    pr = subparsers.add_parser("pr-open")
    pr.add_argument("--worktree", type=pathlib.Path, required=True)
    pr.add_argument("--title", required=True)
    pr.add_argument("--body-file", type=pathlib.Path)
    pr.add_argument("--ready", action="store_true")
    pr.add_argument("--apply", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = repository_root(args.root)
    state_path, _ = common_state_paths(root)
    if args.command == "decide":
        state = read_state(state_path)
        decision = choose_lane(
            args.lane,
            hotfix=args.hotfix,
            small=args.small,
            agents=args.agents,
            cross_component=args.cross_component,
            active_train=state["active_train"],
            explicit_train=args.train,
        )
        print(json.dumps(asdict(decision), sort_keys=True))
    elif args.command == "ci-context":
        context = ci_context(args.event, args.base, args.head, args.draft == "true")
        if args.format == "github":
            for key, value in asdict(context).items():
                rendered = "1" if value is True else "0" if value is False else value
                print(f"{key}={rendered}")
        else:
            print(json.dumps(asdict(context), sort_keys=True))
    elif args.command == "status":
        print(json.dumps(read_state(state_path), indent=2, sort_keys=True))
    elif args.command == "coordination-record":
        if not args.apply:
            command_plan(
                [], action="record-coordination", event=args.event, count=args.count
            )
        else:
            print(
                json.dumps(
                    record_coordination(root, args.event, args.count),
                    indent=2,
                    sort_keys=True,
                )
            )
    elif args.command == "train-start":
        train_start(args, root)
    elif args.command == "train-clear":
        if TRAIN_PATTERN.fullmatch(args.train) is None:
            fail("train branch is invalid")
        if not args.apply:
            command_plan([], action="clear-active-train", train=args.train)
        else:
            def transform(state: dict[str, Any]) -> dict[str, Any]:
                if state["active_train"] != args.train:
                    fail("requested train is not the active train")
                related = [
                    branch
                    for branch, context in state["branches"].items()
                    if branch == args.train or context["base"] == args.train
                ]
                dirty: list[str] = []
                for branch in related:
                    worktree = state["branches"][branch]["worktree"]
                    if worktree and pathlib.Path(worktree).is_dir() and run(
                        ["git", "status", "--porcelain"],
                        cwd=pathlib.Path(worktree),
                    ).stdout.strip():
                        dirty.append(branch)
                if dirty:
                    fail("train clear refuses dirty worktrees: " + ", ".join(dirty))
                state["active_train"] = None
                for branch in related:
                    del state["branches"][branch]
                return state

            print(json.dumps(update_state(root, transform), indent=2, sort_keys=True))
    elif args.command == "task-start":
        task_start(args, root)
    elif args.command == "branch-claim":
        branch_claim(args, root)
    elif args.command == "conflicts":
        conflicts(root, record=args.record)
    else:
        pr_open(args, root)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"development-flow: {error}", file=sys.stderr)
        raise SystemExit(1)
