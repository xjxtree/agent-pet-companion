#!/usr/bin/env python3
"""Retain bounded image-call evidence outside a petpack and check retry policy."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile

SCHEMA = "apc.pet-generation-evidence.v1"
FILENAME = "generation-evidence.json"
OBJECTS = ("base", "idle", "thinking", "tool", "waiting", "done", "failed", "acknowledge", "drag_left", "drag_right")
MAX_ATTEMPTS = 180
MAX_LEDGER_BYTES = 512 * 1024
MAX_IMAGE_BYTES = 64 * 1024 * 1024
MAX_PROMPT_BYTES = 64 * 1024
ATTEMPT_KEYS = {"call_id", "object", "provider", "mode", "outcome", "reason", "source", "source_sha256", "prompt", "prompt_sha256"}


class EvidenceError(ValueError):
    pass


def read_bounded(path: Path, maximum: int) -> bytes:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > maximum:
        raise EvidenceError("Evidence inputs must be bounded regular files, not symlinks")
    with path.open("rb") as handle:
        data = handle.read(maximum + 1)
    if len(data) > maximum:
        raise EvidenceError("Evidence input exceeds its size limit")
    return data


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def artifact(root: Path, relative: object) -> Path:
    if not isinstance(relative, str) or not relative or len(relative) > 512:
        raise EvidenceError("Evidence artifact path is invalid")
    parts = relative.split("/")
    if any(part in ("", ".", "..") for part in parts) or "\\" in relative:
        raise EvidenceError("Evidence artifacts must use safe workspace-relative paths")
    path = root
    for part in parts:
        path = path / part
        if path.is_symlink():
            raise EvidenceError("Evidence artifact paths must not traverse symlinks")
    if not path.resolve().is_relative_to(root.resolve()):
        raise EvidenceError("Evidence artifact escapes its workspace")
    return path


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError("Generation evidence contains a duplicate JSON key")
        result[key] = value
    return result


def read_ledger(root: Path, *, missing: bool = False) -> dict:
    path = root / FILENAME
    if missing and not path.exists():
        return {"schema_version": SCHEMA, "attempts": []}
    value = json.loads(read_bounded(path, MAX_LEDGER_BYTES), object_pairs_hook=unique_object)
    if not isinstance(value, dict) or not {"schema_version", "attempts"} <= set(value) or set(value) - {"schema_version", "attempts", "selections"} or value["schema_version"] != SCHEMA:
        raise EvidenceError("Generation evidence has an incompatible schema")
    if not isinstance(value["attempts"], list) or len(value["attempts"]) > MAX_ATTEMPTS:
        raise EvidenceError("Generation evidence has too many attempts")
    return value


def check_next(attempts: list[dict], object_name: str, provider: str, mode: str) -> None:
    if object_name not in OBJECTS or provider not in ("codex_imagegen", "other") or mode not in ("native_alpha", "flat_chroma"):
        raise EvidenceError("Unknown generation object, provider, or source mode")
    if provider != "codex_imagegen" or mode != "flat_chroma":
        return
    # A successful generation closes its attempt cycle. Old failures cannot
    # authorize chroma for a later revision of the same base/action.
    failed = []
    for attempt in attempts:
        if attempt["object"] != object_name:
            continue
        if attempt["outcome"] == "accepted":
            failed = []
        elif attempt["provider"] == "codex_imagegen" and attempt["mode"] == "native_alpha":
            failed.append(attempt)
    if len(failed) < 3:
        raise EvidenceError(f"{object_name}: chroma fallback requires at least 3 rejected native image calls in this cycle")


def validate_ledger(root: Path, value: dict, required: list[str] = ()) -> None:
    from PIL import Image

    seen_calls = set()
    seen_sources = set()
    previous = {}
    accepted = []
    selections = value.get("selections", {})
    if not isinstance(selections, dict) or set(selections) - set(OBJECTS):
        raise EvidenceError("Generation selections must name known objects")
    for name, selection in selections.items():
        if not isinstance(selection, dict) or set(selection) != {"call_id", "reason"} or not all(isinstance(v, str) for v in selection.values()) or not 12 <= len(selection["reason"].strip()) <= 500:
            raise EvidenceError("Generation selection requires a recorded call and concrete review reason")
        if not any(a.get("call_id") == selection["call_id"] and a.get("object") == name for a in value["attempts"] if isinstance(a, dict)):
            raise EvidenceError("Generation selection references an unknown or mismatched call")
    for item in value["attempts"]:
        if not isinstance(item, dict) or set(item) != ATTEMPT_KEYS:
            raise EvidenceError("Generation attempt fields are invalid")
        if any(not isinstance(item[key], str) for key in ATTEMPT_KEYS):
            raise EvidenceError("Generation attempt values must be strings")
        call_id = item["call_id"]
        if not isinstance(call_id, str) or not 1 <= len(call_id) <= 128 or any(ord(c) < 32 for c in call_id) or call_id in seen_calls:
            raise EvidenceError("Each executed image call needs a unique bounded call_id")
        if item["outcome"] not in ("accepted", "rejected") or not isinstance(item["reason"], str) or not 12 <= len(item["reason"].strip()) <= 500:
            raise EvidenceError("Each image call needs an accepted/rejected outcome and a concrete review reason")
        check_next(accepted, item["object"], item["provider"], item["mode"])
        source = artifact(root, item["source"])
        prompt = artifact(root, item["prompt"])
        if source.resolve() in seen_sources:
            raise EvidenceError("Repeated processing of one source is not another image call")
        if digest(read_bounded(source, MAX_IMAGE_BYTES)) != item["source_sha256"] or digest(read_bounded(prompt, MAX_PROMPT_BYTES)) != item["prompt_sha256"]:
            raise EvidenceError("Generation evidence source or prompt changed after recording")
        prompt_text = read_bounded(prompt, MAX_PROMPT_BYTES).decode("utf-8")
        if not prompt_text.strip():
            raise EvidenceError("The executed prompt must not be empty")
        if item["outcome"] == "accepted" or selections.get(item["object"], {}).get("call_id") == call_id:
            with Image.open(source) as decoded:
                if decoded.width * decoded.height > 32_000_000 or getattr(decoded, "n_frames", 1) != 1:
                    raise EvidenceError("Accepted source must be one bounded still image")
                alpha = decoded.convert("RGBA").getchannel("A").histogram()
                if item["mode"] == "native_alpha" and (not alpha[0] or not sum(alpha[16:])):
                    raise EvidenceError("Accepted native output needs actual transparent and visible pixels")
                if item["mode"] == "flat_chroma" and sum(alpha[:255]):
                    raise EvidenceError("Accepted flat-chroma output must be fully opaque")
        prior = previous.get(item["object"])
        if prior and prior["outcome"] == "rejected" and prior["mode"] == item["mode"] == "native_alpha" and prior["prompt_sha256"] == item["prompt_sha256"]:
            raise EvidenceError("A failed native attempt requires a changed prompt before retrying")
        seen_calls.add(call_id)
        seen_sources.add(source.resolve())
        previous[item["object"]] = item
        accepted.append(item)
    for name in required:
        if name in selections:
            continue
        if name not in previous or previous[name]["outcome"] != "accepted":
            raise EvidenceError(f"{name}: latest image-generation attempt has not been accepted")


def binding(root: Path, required: list[str]) -> str:
    value = read_ledger(root)
    validate_ledger(root, value, required)
    return digest(read_bounded(root / FILENAME, MAX_LEDGER_BYTES))


def write_ledger(root: Path, ledger: dict) -> None:
    encoded = (json.dumps(ledger, ensure_ascii=False, indent=2) + "\n").encode()
    if len(encoded) > MAX_LEDGER_BYTES:
        raise EvidenceError("Generation evidence exceeds its size limit")
    descriptor, temporary = tempfile.mkstemp(prefix=".generation-evidence-", dir=root)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
        os.replace(temporary, root / FILENAME)
    finally:
        Path(temporary).unlink(missing_ok=True)


def reassess(args: argparse.Namespace) -> dict:
    """Review an existing output after processing without inventing an image call."""
    root = Path(args.workspace).expanduser().resolve()
    ledger = read_ledger(root)
    validate_ledger(root, ledger)
    matches = [item for item in ledger["attempts"] if item["call_id"] == args.call_id]
    if not matches:
        raise EvidenceError("Cannot reassess an unrecorded image call")
    item = matches[0]
    latest = next(entry for entry in reversed(ledger["attempts"]) if entry["object"] == item["object"])
    if latest is not item:
        raise EvidenceError("Reassess only the latest call for an object; do not rewrite historical retry cycles")
    if not 12 <= len(args.reason.strip()) <= 500:
        raise EvidenceError("Reassessment needs a concrete reason of 12 to 500 characters")
    # Preserve the original assessment in an immutable workspace-side receipt.
    history = root / ".generation-inputs"
    if history.is_symlink():
        raise EvidenceError("Generation evidence directory must not be a symlink")
    history.mkdir(exist_ok=True, mode=0o700)
    previous = dict(item)
    item["outcome"] = args.outcome
    item["reason"] = args.reason
    validate_ledger(root, ledger)
    descriptor, receipt = tempfile.mkstemp(prefix="reassessment-", suffix=".json", dir=history)
    with os.fdopen(descriptor, "w") as handle:
        json.dump({"previous": previous, "current": item}, handle, ensure_ascii=False, indent=2)
    write_ledger(root, ledger)
    return {"ok": True, "attempt_count": len(ledger["attempts"]), "call_id": args.call_id, "receipt": receipt}


def select(args: argparse.Namespace) -> dict:
    """Select retained artwork after QA without rewriting historical retry cycles."""
    root = Path(args.workspace).expanduser().resolve()
    ledger = read_ledger(root)
    validate_ledger(root, ledger)
    item = next((a for a in ledger["attempts"] if a["call_id"] == args.call_id), None)
    if item is None:
        raise EvidenceError("Cannot select an unrecorded image call")
    ledger.setdefault("selections", {})[item["object"]] = {"call_id": args.call_id, "reason": args.reason}
    validate_ledger(root, ledger, [item["object"]])
    write_ledger(root, ledger)
    return {"ok": True, "attempt_count": len(ledger["attempts"]), "call_id": args.call_id, "object": item["object"]}


def record(args: argparse.Namespace) -> dict:
    from PIL import Image

    root = Path(args.workspace).expanduser().resolve()
    if not root.is_dir():
        raise EvidenceError("Generation workspace must already exist")
    ledger = read_ledger(root, missing=True)
    validate_ledger(root, ledger)
    if len(ledger["attempts"]) >= MAX_ATTEMPTS:
        raise EvidenceError("Generation attempt limit reached")
    check_next(ledger["attempts"], args.object, args.provider, args.mode)
    source_bytes = read_bounded(Path(args.source), MAX_IMAGE_BYTES)
    prompt_bytes = read_bounded(Path(args.prompt_file), MAX_PROMPT_BYTES)
    if not prompt_bytes.decode("utf-8").strip():
        raise EvidenceError("The actual executed prompt must not be empty")
    with Image.open(Path(args.source)) as image:
        if image.format not in ("PNG", "JPEG", "WEBP") or getattr(image, "n_frames", 1) != 1 or image.width * image.height > 32_000_000:
            raise EvidenceError("Generation output must be one supported bounded still image")
        extension = {"PNG": "png", "JPEG": "jpg", "WEBP": "webp"}[image.format]
        alpha = image.convert("RGBA").getchannel("A").histogram()
        if args.outcome == "accepted":
            if args.mode == "native_alpha" and (not alpha[0] or not sum(alpha[16:])):
                raise EvidenceError("Accepted native output needs actual transparent and visible pixels")
            if args.mode == "flat_chroma" and sum(alpha[:255]):
                raise EvidenceError("Accepted flat-chroma output must be fully opaque")
    parent = root / ".generation-inputs"
    if parent.is_symlink():
        raise EvidenceError("Generation evidence directory must not be a symlink")
    parent.mkdir(exist_ok=True, mode=0o700)
    saved = Path(tempfile.mkdtemp(prefix="attempt-", dir=parent))
    try:
        source = saved / f"source.{extension}"
        prompt = saved / "prompt.txt"
        source.write_bytes(source_bytes)
        prompt.write_bytes(prompt_bytes)
        source.chmod(0o600)
        prompt.chmod(0o600)
        attempt = {
            "call_id": args.call_id, "object": args.object, "provider": args.provider,
            "mode": args.mode, "outcome": args.outcome, "reason": args.reason,
            "source": source.relative_to(root).as_posix(), "source_sha256": digest(source_bytes),
            "prompt": prompt.relative_to(root).as_posix(), "prompt_sha256": digest(prompt_bytes),
        }
        ledger["attempts"].append(attempt)
        ledger.get("selections", {}).pop(args.object, None)
        validate_ledger(root, ledger)
        write_ledger(root, ledger)
    except BaseException:
        shutil.rmtree(saved)
        raise
    return {"ok": True, "attempt_count": len(ledger["attempts"]), "evidence": str(root / FILENAME)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    selection = sub.add_parser("select", help="Select any retained output after quality review without changing call history")
    selection.add_argument("--workspace", required=True)
    selection.add_argument("--call-id", required=True)
    selection.add_argument("--reason", required=True)
    review = sub.add_parser("reassess", help="Review the latest retained output after quality-preserving processing; does not count as a generation")
    review.add_argument("--workspace", required=True)
    review.add_argument("--call-id", required=True)
    review.add_argument("--outcome", required=True, choices=("accepted", "rejected"))
    review.add_argument("--reason", required=True)
    for command in ("check", "record"):
        child = sub.add_parser(command)
        child.add_argument("--workspace", required=True)
        child.add_argument("--object", required=True, choices=OBJECTS)
        child.add_argument("--provider", required=True, choices=("codex_imagegen", "other"))
        child.add_argument("--mode", required=True, choices=("native_alpha", "flat_chroma"))
        if command == "record":
            child.add_argument("--call-id", required=True)
            child.add_argument("--source", required=True)
            child.add_argument("--prompt-file", required=True)
            child.add_argument("--outcome", required=True, choices=("accepted", "rejected"))
            child.add_argument("--reason", required=True)
    args = parser.parse_args()
    try:
        if args.command == "select":
            result = select(args)
        elif args.command == "reassess":
            result = reassess(args)
        elif args.command == "record":
            result = record(args)
        else:
            root = Path(args.workspace).expanduser().resolve()
            ledger = read_ledger(root, missing=True)
            validate_ledger(root, ledger)
            check_next(ledger["attempts"], args.object, args.provider, args.mode)
            result = {"ok": True, "object": args.object, "mode": args.mode}
        print(json.dumps(result))
    except (EvidenceError, OSError, ValueError) as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
