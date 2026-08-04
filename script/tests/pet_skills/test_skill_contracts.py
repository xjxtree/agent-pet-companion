#!/usr/bin/env python3
"""Structure and synchronization tests for the two pet-making Skills."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import stat
import unittest


REPOSITORY = Path(__file__).resolve().parents[3]
MAKER = REPOSITORY / "skills" / "agent-pet-maker"
STUDIO = REPOSITORY / "skills" / "agent-pet-studio"
MAKER_HELPER = MAKER / "scripts" / "petpack_workspace.py"

SPEC = importlib.util.spec_from_file_location("petpack_workspace", MAKER_HELPER)
assert SPEC is not None and SPEC.loader is not None
maker_helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(maker_helper)


def frontmatter(path: Path) -> dict[str, str]:
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "---":
        raise AssertionError(f"{path} has no YAML frontmatter")
    try:
        closing = lines.index("---", 1)
    except ValueError as error:
        raise AssertionError(f"{path} has unterminated YAML frontmatter") from error
    fields: dict[str, str] = {}
    for line in lines[1:closing]:
        key, separator, value = line.partition(":")
        if not separator:
            raise AssertionError(f"invalid frontmatter line in {path}: {line!r}")
        fields[key.strip()] = value.strip()
    return fields


def markdown_links(path: Path) -> list[Path]:
    text = path.read_text(encoding="utf-8")
    targets = re.findall(r"\[[^]]+\]\(([^)]+)\)", text)
    return [
        (path.parent / target.split("#", 1)[0]).resolve()
        for target in targets
        if target and not re.match(r"^[a-z]+://", target)
    ]


class SkillStructureTests(unittest.TestCase):
    def test_frontmatter_is_minimal_and_trigger_descriptions_are_specific(self) -> None:
        expected = {
            MAKER / "SKILL.md": "agent-pet-maker",
            STUDIO / "SKILL.md": "agent-pet-studio",
        }
        for path, name in expected.items():
            with self.subTest(skill=name):
                fields = frontmatter(path)
                self.assertEqual(set(fields), {"name", "description"})
                self.assertEqual(fields["name"], name)
                self.assertIn(".petpack V3", fields["description"])
                self.assertIn("Use", fields["description"])

    def test_entry_files_are_concise_and_all_links_resolve(self) -> None:
        limits = {MAKER / "SKILL.md": 160, STUDIO / "SKILL.md": 120}
        for path, maximum in limits.items():
            with self.subTest(path=path):
                self.assertLessEqual(
                    len(path.read_text(encoding="utf-8").splitlines()), maximum
                )
                for target in markdown_links(path):
                    self.assertTrue(target.is_file(), f"broken Skill link: {target}")

        for path in sorted((MAKER / "references").glob("*.md")):
            with self.subTest(reference=path.name):
                for target in markdown_links(path):
                    self.assertTrue(target.is_file(), f"broken reference link: {target}")

    def test_studio_contains_only_its_runtime_instruction_file(self) -> None:
        files = sorted(
            path.relative_to(STUDIO).as_posix()
            for path in STUDIO.rglob("*")
            if path.is_file() and "__pycache__" not in path.parts
        )
        self.assertEqual(files, ["SKILL.md"])

    def test_history_and_rejected_field_catalogs_are_absent_from_skill_prose(self) -> None:
        prose = [MAKER / "SKILL.md", STUDIO / "SKILL.md"] + sorted(
            (MAKER / "references").glob("*.md")
        )
        forbidden = (
            "V1/V2",
            "V1 or V2",
            "native_fps",
            "state_durations_ms",
            "removed package state",
            "historical",
            "legacy",
        )
        for path in prose:
            content = path.read_text(encoding="utf-8")
            for token in forbidden:
                with self.subTest(path=path.name, token=token):
                    self.assertNotIn(token, content)

    def test_shared_contracts_have_one_clear_owner(self) -> None:
        maker = (MAKER / "SKILL.md").read_text(encoding="utf-8")
        studio = (STUDIO / "SKILL.md").read_text(encoding="utf-8")
        for content in (maker, studio):
            self.assertIn("petpack-v3.md", content)
            self.assertIn("security.md", content)
            self.assertIn("visual-production-and-native-resolution.md", content)
            self.assertIn("transparent-frame-production.md", content)
            self.assertIn("dreamina-high-production.md", content)
        self.assertNotIn("260, 220, 240", maker)
        self.assertNotIn("260, 220, 240", studio)

        visual = (
            MAKER / "references" / "visual-production-and-native-resolution.md"
        ).read_text(encoding="utf-8")
        dreamina = (
            MAKER / "references" / "dreamina-high-production.md"
        ).read_text(encoding="utf-8")
        self.assertNotIn("--model_version=5.0Pro", visual)
        self.assertIn("--model_version=5.0Pro", dreamina)

    def test_openai_metadata_matches_the_portable_skill(self) -> None:
        metadata = (MAKER / "agents" / "openai.yaml").read_text(encoding="utf-8")
        self.assertIn('display_name: "Agent Pet Maker"', metadata)
        self.assertIn("$agent-pet-companion:agent-pet-maker", metadata)
        short = re.search(r'short_description: "([^"]+)"', metadata)
        self.assertIsNotNone(short)
        assert short is not None
        self.assertGreaterEqual(len(short.group(1)), 25)
        self.assertLessEqual(len(short.group(1)), 64)


class ContractSynchronizationTests(unittest.TestCase):
    def test_documented_creation_timing_matches_the_maker_helper(self) -> None:
        contract = (MAKER / "references" / "petpack-v3.md").read_text(
            encoding="utf-8"
        )
        rows: dict[str, tuple[list[int], str, int]] = {}
        pattern = re.compile(
            r"^\| `([^`]+)` \| ([0-9, ]+) \| `([^`]+)`[^|]*\| (\d+) \|$"
        )
        for line in contract.splitlines():
            match = pattern.match(line)
            if match:
                rows[match.group(1)] = (
                    [int(value.strip()) for value in match.group(2).split(",")],
                    match.group(3),
                    int(match.group(4)),
                )

        self.assertEqual(set(rows), set(maker_helper.STATES))
        self.assertEqual(sum(len(row[0]) for row in rows.values()), 50)
        for state, timing in maker_helper.DEFAULT_STATE_TIMINGS.items():
            with self.subTest(state=state):
                durations, mode, reduced = rows[state]
                self.assertEqual(durations, timing["frame_durations_ms"])
                self.assertEqual(mode, timing["playback"]["mode"])
                self.assertEqual(reduced, timing["reduced_motion_frame_index"])

    def test_provider_tiers_and_dreamina_canvas_math_are_consistent(self) -> None:
        visual = (
            MAKER / "references" / "visual-production-and-native-resolution.md"
        ).read_text(encoding="utf-8")
        studio = (STUDIO / "SKILL.md").read_text(encoding="utf-8")
        for required in (
            "ChatGPT/Codex built-in `imagegen`",
            "approximate 1K–2K",
            "`low`, `standard`",
            "`high` 576×624",
        ):
            self.assertIn(required, visual + studio)

        guide = (MAKER / "references" / "dreamina-high-production.md").read_text(
            encoding="utf-8"
        )
        for required in (
            "--model_version=5.0Pro",
            "--resolution_type=4k",
            "--ratio=3:4",
            "--generate_num=1",
            "--poll=60",
            "gen_status=querying",
            "dreamina query_result --submit_id=<submit_id>",
        ):
            self.assertIn(required, guide)

        rows = re.findall(
            r"\| (\d+) \| (\d+)×1536 \| (\d+) \| (\d+)×(\d+) \|",
            guide,
        )
        self.assertEqual(len(rows), 4)
        for raw_count, raw_width, raw_slot, raw_crop_w, raw_crop_h in rows:
            count, width, slot, crop_w, crop_h = map(
                int, (raw_count, raw_width, raw_slot, raw_crop_w, raw_crop_h)
            )
            with self.subTest(frame_count=count):
                self.assertEqual(width, count * slot)
                self.assertLessEqual(crop_w, slot)
                self.assertEqual(crop_w * 13, crop_h * 12)
                self.assertGreaterEqual(crop_w, 576)
                self.assertGreaterEqual(crop_h, 624)

    def test_maker_scripts_are_executable_and_parse_as_python(self) -> None:
        for path in sorted((MAKER / "scripts").glob("*.py")):
            with self.subTest(script=path.name):
                mode = path.stat().st_mode
                self.assertTrue(mode & stat.S_IXUSR)
                compile(path.read_text(encoding="utf-8"), str(path), "exec")


if __name__ == "__main__":
    unittest.main()
