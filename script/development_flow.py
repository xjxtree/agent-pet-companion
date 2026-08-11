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
from dataclasses import asdict, dataclass
from typing import Any, NoReturn


SCHEMA_VERSION = "apc.development-flow.v1"
MAIN_BRANCH = "main"
TRAIN_PREFIX = "gd-ops/train/"
TASK_PREFIX = "gd-ops/task/"
FIX_PREFIX = "gd-ops/fix/"
TRAIN_PATTERN = re.compile(r"gd-ops/train/[a-z0-9][a-z0-9._-]{0,63}")
WORK_PATTERN = re.compile(r"gd-ops/(?:task|fix)/[A-Za-z0-9._-]+-[a-z0-9][a-z0-9._-]{0,63}")
TOKEN_PATTERN = re.compile(r"[A-Za-z0-9._-]+")
SLUG_PATTERN = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")


def fail(message: str) -> NoReturn:
    raise ValueError(message)


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
        "branch_bases": {},
    }


def validate_state(payload: dict[str, Any]) -> dict[str, Any]:
    if set(payload) != {"schema_version", "active_train", "branch_bases"}:
        fail("development-flow state field inventory is invalid")
    if payload.get("schema_version") != SCHEMA_VERSION:
        fail("development-flow state schema is unsupported")
    active_train = payload.get("active_train")
    if active_train is not None and TRAIN_PATTERN.fullmatch(active_train) is None:
        fail("development-flow active train is invalid")
    branch_bases = payload.get("branch_bases")
    if not isinstance(branch_bases, dict) or len(branch_bases) > 256:
        fail("development-flow branch-base inventory is invalid")
    for branch, base in branch_bases.items():
        if (
            not isinstance(branch, str)
            or not isinstance(base, str)
            or (WORK_PATTERN.fullmatch(branch) is None and TRAIN_PATTERN.fullmatch(branch) is None)
            or (base != MAIN_BRANCH and TRAIN_PATTERN.fullmatch(base) is None)
        ):
            fail("development-flow branch-base entry is invalid")
    return payload


def read_state(path: pathlib.Path) -> dict[str, Any]:
    if not path.exists():
        return empty_state()
    metadata = path.lstat()
    if not path.is_file() or path.is_symlink() or metadata.st_size > 256 * 1024:
        fail("development-flow state must be a bounded regular file")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        fail("development-flow state must contain one JSON object")
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


def ci_context(event: str, base: str, head: str, draft: bool) -> CIContext:
    if event == "push":
        if base != MAIN_BRANCH:
            fail("authoritative push CI is restricted to main")
        return CIContext("main-push", True, True)
    if event != "pull_request":
        fail("CI development lane supports only pull_request and push")
    if base == MAIN_BRANCH:
        lane = "train-to-main" if TRAIN_PATTERN.fullmatch(head) else "direct-to-main"
        return CIContext(lane, not draft, False)
    if TRAIN_PATTERN.fullmatch(base):
        if WORK_PATTERN.fullmatch(head) is None:
            fail("a train accepts only gd-ops/task/* or gd-ops/fix/* pull requests")
        return CIContext("task-to-train", False, False)
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
        command_plan(commands, lane="train", branch=branch, base=MAIN_BRANCH)
        return
    for command in commands:
        run(command, cwd=root)

    def transform(state: dict[str, Any]) -> dict[str, Any]:
        if state["active_train"] not in (None, branch):
            fail(f"another train is already active: {state['active_train']}")
        state["active_train"] = branch
        state["branch_bases"][branch] = MAIN_BRANCH
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
    kind = "fix" if args.hotfix else "task"
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
        )
        return
    for command in commands:
        run(command, cwd=root)

    def transform(current: dict[str, Any]) -> dict[str, Any]:
        current["branch_bases"][branch] = base
        return current

    update_state(root, transform)
    print(
        json.dumps(
            {"lane": decision.lane, "reason": decision.reason, "branch": branch, "base": base},
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
    base = state["branch_bases"].get(branch)
    if base is None:
        base = MAIN_BRANCH if TRAIN_PATTERN.fullmatch(branch) else None
    if base is None:
        fail("branch base metadata is missing; recreate the worktree with this tool")
    repository = repository_name(root)
    commands = [
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
            *(
                ["--body-file", str(args.body_file.resolve())]
                if args.body_file
                else ["--fill"]
            ),
            *([] if args.ready else ["--draft"]),
        ],
    ]
    if not args.apply:
        command_plan(commands, branch=branch, base=base, ready=args.ready)
        return
    if run(["git", "status", "--porcelain"], cwd=worktree).stdout.strip():
        fail("PR worktree must be clean before push")
    run(commands[0], cwd=root)
    created = run(commands[1], cwd=root).stdout.strip()
    if not created.startswith("https://github.com/"):
        fail("gh did not return a pull request URL")
    print(json.dumps({"url": created, "branch": branch, "base": base}, sort_keys=True))


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
    task.add_argument("--apply", action="store_true")

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
                state["active_train"] = None
                return state

            print(json.dumps(update_state(root, transform), indent=2, sort_keys=True))
    elif args.command == "task-start":
        task_start(args, root)
    else:
        pr_open(args, root)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"development-flow: {error}", file=sys.stderr)
        raise SystemExit(1)
