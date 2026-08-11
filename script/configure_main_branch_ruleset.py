#!/usr/bin/env python3
"""Install repository settings plus protected main and train rulesets.

The command is deliberately dry-run by default. Full ``--apply`` refuses to
mutate GitHub unless the current remote default-branch commit already has a
successful ``Required CI`` check produced by GitHub Actions. ``--settings-only``
is the explicit exception for reversible merge settings. This makes the initial
CI migration safe: push the workflow first, wait for it to pass, then protect
the branches without creating an impossible required-check dependency.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from typing import Any, NoReturn


API_VERSION = "2026-03-10"
RULESET_NAME = "Protected default branch"
TRAIN_RULESET_NAME = "Protected integration trains"
REQUIRED_CHECK = "Required CI"
REQUIRED_WORKFLOW = ".github/workflows/ci.yml"


def fail(message: str) -> NoReturn:
    raise ValueError(message)


def run(command: list[str], *, input_text: str | None = None) -> str:
    result = subprocess.run(
        command,
        check=False,
        text=True,
        input=input_text,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        fail(f"command failed ({' '.join(command)}): {detail}")
    return result.stdout


def gh_json(endpoint: str) -> Any:
    return json.loads(
        run(
            [
                "gh",
                "api",
                "-H",
                "Accept: application/vnd.github+json",
                "-H",
                f"X-GitHub-Api-Version: {API_VERSION}",
                endpoint,
            ]
        )
    )


def select_required_check(
    payload: dict[str, Any], repository: str
) -> dict[str, int | str]:
    candidates = []
    details_pattern = re.compile(
        rf"https://github[.]com/{re.escape(repository)}/actions/runs/([1-9][0-9]*)/job/[1-9][0-9]*"
    )
    for check in payload.get("check_runs", []):
        if not isinstance(check, dict):
            continue
        app = check.get("app") or {}
        details_match = details_pattern.fullmatch(str(check.get("details_url") or ""))
        if (
            check.get("name") == REQUIRED_CHECK
            and check.get("status") == "completed"
            and check.get("conclusion") == "success"
            and app.get("slug") == "github-actions"
            and isinstance(check.get("id"), int)
            and check["id"] > 0
            and isinstance(app.get("id"), int)
            and app["id"] > 0
            and details_match is not None
        ):
            candidates.append((check, int(details_match.group(1))))
    if not candidates:
        fail(
            f"remote default-branch commit has no successful {REQUIRED_CHECK!r} "
            "check from GitHub Actions; push the workflow and wait for CI first"
        )
    candidates.sort(
        key=lambda item: (item[0].get("completed_at") or "", item[0].get("id") or 0)
    )
    selected, workflow_run_id = candidates[-1]
    return {
        "check_run_id": int(selected["id"]),
        "integration_id": int(selected["app"]["id"]),
        "workflow_run_id": workflow_run_id,
        "completed_at": str(selected.get("completed_at") or ""),
    }


def validate_workflow_run(
    payload: dict[str, Any], repository: str, default_branch: str, commit: str
) -> None:
    head_repository = payload.get("head_repository") or {}
    if not (
        payload.get("path") == REQUIRED_WORKFLOW
        and payload.get("event") == "push"
        and payload.get("head_branch") == default_branch
        and payload.get("head_sha") == commit
        and payload.get("status") == "completed"
        and payload.get("conclusion") == "success"
        and head_repository.get("full_name") == repository
    ):
        fail(
            f"{REQUIRED_CHECK!r} does not belong to a successful trusted "
            f"{REQUIRED_WORKFLOW} push for the exact default-branch commit"
        )


def pull_request_rule() -> dict[str, Any]:
    return {
        "type": "pull_request",
        "parameters": {
            "allowed_merge_methods": ["squash"],
            "dismiss_stale_reviews_on_push": False,
            "require_code_owner_review": False,
            "require_last_push_approval": False,
            "required_approving_review_count": 0,
            "required_review_thread_resolution": True,
        },
    }


def status_rule(integration_id: int, *, strict: bool) -> dict[str, Any]:
    return {
        "type": "required_status_checks",
        "parameters": {
            "do_not_enforce_on_create": True,
            "required_status_checks": [
                {
                    "context": REQUIRED_CHECK,
                    "integration_id": integration_id,
                }
            ],
            "strict_required_status_checks_policy": strict,
        },
    }


def ruleset_payload(integration_id: int, *, train: bool = False) -> dict[str, Any]:
    if integration_id <= 0:
        fail("GitHub Actions integration ID must be positive")
    rules = [
        {"type": "non_fast_forward"},
        {"type": "required_linear_history"},
        pull_request_rule(),
        status_rule(integration_id, strict=not train),
    ]
    if not train:
        rules.insert(0, {"type": "deletion"})
    return {
        "name": TRAIN_RULESET_NAME if train else RULESET_NAME,
        "target": "branch",
        "enforcement": "active",
        "bypass_actors": [],
        "conditions": {
            "ref_name": {
                "include": ["refs/heads/gd-ops/train/*"] if train else ["~DEFAULT_BRANCH"],
                "exclude": [],
            }
        },
        # Trains are intentionally deletable after their final PR merges. Main
        # alone carries the deletion prohibition.
        "rules": rules,
    }


def repository_settings_payload() -> dict[str, Any]:
    return {
        "allow_auto_merge": True,
        "delete_branch_on_merge": True,
        "allow_merge_commit": False,
        "allow_rebase_merge": False,
        "allow_squash_merge": True,
        "allow_update_branch": True,
        "squash_merge_commit_title": "PR_TITLE",
        "squash_merge_commit_message": "PR_BODY",
    }


def existing_ruleset_id(payload: list[dict[str, Any]], name: str = RULESET_NAME) -> int | None:
    matches = [
        item
        for item in payload
        if item.get("name") == name and item.get("target") == "branch"
    ]
    if len(matches) > 1:
        fail(f"multiple repository rulesets are named {name!r}")
    if not matches:
        return None
    ruleset_id = matches[0].get("id")
    if not isinstance(ruleset_id, int) or ruleset_id <= 0:
        fail(f"existing {name!r} ruleset has an invalid ID")
    return ruleset_id


def mutate_ruleset(repository: str, ruleset_id: int | None, payload: dict[str, Any]) -> Any:
    endpoint = f"repos/{repository}/rulesets"
    method = "POST"
    if ruleset_id is not None:
        endpoint = f"{endpoint}/{ruleset_id}"
        method = "PUT"
    return json.loads(
        run(
            [
                "gh",
                "api",
                "--method",
                method,
                "-H",
                "Accept: application/vnd.github+json",
                "-H",
                f"X-GitHub-Api-Version: {API_VERSION}",
                endpoint,
                "--input",
                "-",
            ],
            input_text=json.dumps(payload, sort_keys=True),
        )
    )


def mutate_repository_settings(repository: str, payload: dict[str, Any]) -> Any:
    return json.loads(
        run(
            [
                "gh",
                "api",
                "--method",
                "PATCH",
                "-H",
                "Accept: application/vnd.github+json",
                "-H",
                f"X-GitHub-Api-Version: {API_VERSION}",
                f"repos/{repository}",
                "--input",
                "-",
            ],
            input_text=json.dumps(payload, sort_keys=True),
        )
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Plan or apply the Required CI ruleset for the GitHub default branch."
    )
    parser.add_argument(
        "--repository",
        help="GitHub OWNER/REPO; defaults to the repository selected by gh",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="create or update the ruleset after verifying remote Required CI",
    )
    parser.add_argument(
        "--settings-only",
        action="store_true",
        help="configure reversible repository merge settings without installing rulesets",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repository = args.repository or json.loads(
        run(["gh", "repo", "view", "--json", "nameWithOwner"])
    )["nameWithOwner"]
    if not isinstance(repository, str) or repository.count("/") != 1:
        fail("repository must be OWNER/REPO")

    repository_data = gh_json(f"repos/{repository}")
    default_branch = repository_data.get("default_branch")
    if not isinstance(default_branch, str) or not default_branch:
        fail("repository has no default branch")
    settings = repository_settings_payload()
    if args.settings_only:
        plan = {
            "apply": args.apply,
            "repository": repository,
            "repository_settings": settings,
        }
        if not args.apply:
            print(json.dumps(plan, indent=2, sort_keys=True))
            return 0
        response = mutate_repository_settings(repository, settings)
        print(
            json.dumps(
                {key: response.get(key) for key in settings},
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    branch_data = gh_json(f"repos/{repository}/branches/{default_branch}")
    commit = (branch_data.get("commit") or {}).get("sha")
    if not isinstance(commit, str) or len(commit) != 40:
        fail("default branch did not resolve to a full commit")

    check = select_required_check(
        gh_json(f"repos/{repository}/commits/{commit}/check-runs?filter=latest&per_page=100"),
        repository,
    )
    validate_workflow_run(
        gh_json(f"repos/{repository}/actions/runs/{check['workflow_run_id']}"),
        repository,
        default_branch,
        commit,
    )
    main_payload = ruleset_payload(int(check["integration_id"]))
    train_payload = ruleset_payload(int(check["integration_id"]), train=True)
    rulesets = gh_json(f"repos/{repository}/rulesets?includes_parents=false&targets=branch")
    main_ruleset_id = existing_ruleset_id(rulesets, RULESET_NAME)
    train_ruleset_id = existing_ruleset_id(rulesets, TRAIN_RULESET_NAME)
    plan = {
        "apply": args.apply,
        "repository": repository,
        "default_branch": default_branch,
        "commit": commit,
        "required_check": check,
        "repository_settings": settings,
        "rulesets": [
            {
                "action": "update" if main_ruleset_id is not None else "create",
                "ruleset_id": main_ruleset_id,
                "payload": main_payload,
            },
            {
                "action": "update" if train_ruleset_id is not None else "create",
                "ruleset_id": train_ruleset_id,
                "payload": train_payload,
            },
        ],
    }
    if not args.apply:
        print(json.dumps(plan, indent=2, sort_keys=True))
        return 0

    mutate_repository_settings(repository, settings)
    main_response = mutate_ruleset(repository, main_ruleset_id, main_payload)
    train_response = mutate_ruleset(repository, train_ruleset_id, train_payload)
    print(
        json.dumps(
            {
                "repository": repository,
                "commit": commit,
                "rulesets": [
                    {
                        "ruleset_id": main_response.get("id"),
                        "name": main_response.get("name"),
                        "enforcement": main_response.get("enforcement"),
                    },
                    {
                        "ruleset_id": train_response.get("id"),
                        "name": train_response.get("name"),
                        "enforcement": train_response.get("enforcement"),
                    },
                ],
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"configure-main-branch-ruleset: {error}", file=sys.stderr)
        raise SystemExit(1)
