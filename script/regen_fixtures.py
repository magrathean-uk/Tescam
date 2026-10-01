#!/usr/bin/env python3
"""Regenerate every ``expected_*`` block in every domain fixture.

A single entry point that recomputes:

- ``expected_scan`` (per duplicate policy) from ``scan_manifest``
- ``expected_layout`` (per profile) from ``layout_manifest``
- ``expected_selection`` (per duplicate policy) from
  ``select_clip_sets`` + ``selected_sets_manifest``
- ``expected_output`` from ``apply_output_conflict_policy`` exercised
  against the fixture's natural default filename

A stub ``MediaProbe`` pretends every clip is exactly 60 s long so
fixture data does not depend on ``ffprobe`` being installed nor on real
mp4 bytes.

Authoring a new fixture: drop a JSON file under
``fixtures/domain/cases/`` containing at minimum::

    {
      "name": "...",
      "description": "...",
      "schema_version": 1,
      "files": [{"path": "..."}, ...]
    }

Then run::

    source .cache/venv/bin/activate
    python3 script/regen_fixtures.py

This will populate every ``expected_*`` block. Re-run whenever a
contract surface changes (scan/layout/selection/output) and commit
the updated fixtures.
"""
from __future__ import annotations

import json
import os
from datetime import timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any, Dict, List

from tescam_cli.cli import (
    apply_output_conflict_policy,
    dataset_range,
    default_output_filename,
)
from tescam_cli.composer import select_clip_sets
from tescam_cli.domain_contract import (
    layout_manifest,
    scan_manifest,
    selected_sets_manifest,
)
from tescam_cli.layouts import build_camera_layout_plan
from tescam_cli.models import DuplicatePolicy, OutputConflictPolicy
from tescam_cli.scanner import scan_source

REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURE_DIR = REPO_ROOT / "fixtures" / "domain" / "cases"

STUB_FFPROBE = Path("/usr/bin/ffprobe")
STUB_DURATION_SECONDS = 60.0
ERROR_MESSAGE_FRAGMENT = "Output file already exists"


class StubMediaProbe:
    """Deterministic probe used by both the regenerator and the parity tests."""

    def duration(self, ffprobe: Path, media_path: Path) -> float:  # noqa: ARG002
        return STUB_DURATION_SECONDS

    def has_video_stream(self, ffprobe: Path, media_path: Path) -> bool:  # noqa: ARG002
        return True

    def dimensions(self, ffprobe: Path, media_path: Path):  # noqa: ARG002
        return None

    def fps(self, ffprobe: Path, media_path: Path) -> float:  # noqa: ARG002
        return 36.027


def materialize_case(case: Dict[str, Any], source: Path) -> None:
    """Write the fixture's declared file tree under ``source``."""
    for entry in case["files"]:
        path = source / entry["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"fixture")
        if "mtime" in entry:
            os.utime(path, (entry["mtime"], entry["mtime"]))


def _scan_block(case: Dict[str, Any]) -> Dict[str, Any]:
    blocks: Dict[str, Any] = {}
    with TemporaryDirectory() as temp_dir:
        source = Path(temp_dir)
        materialize_case(case, source)
        for policy in DuplicatePolicy:
            try:
                result = scan_source(source, duplicate_policy=policy)
            except RuntimeError:
                # Fixture has no recognizable clips. Currently unused, but
                # keep the branch so future zero-clip fixtures can be wired
                # in without changing the regen contract.
                blocks[policy.value] = {"empty_dataset": True}
                continue
            manifest = scan_manifest(result, source)
            manifest.pop("schema_version", None)
            manifest.pop("type", None)
            blocks[policy.value] = manifest
    return blocks


def _layout_block(case: Dict[str, Any]) -> Dict[str, Any]:
    blocks: Dict[str, Any] = {}
    with TemporaryDirectory() as temp_dir:
        source = Path(temp_dir)
        materialize_case(case, source)
        try:
            scan = scan_source(source, duplicate_policy=DuplicatePolicy.MERGE_BY_TIME)
            cameras = scan.cameras
        except RuntimeError:
            cameras = set()
        for profile in ("auto", "legacy4", "sixcam"):
            layout = build_camera_layout_plan(
                profile=profile,
                available_cameras=cameras,
                probed_dimensions={},
            )
            blocks[profile] = layout_manifest(layout)
    return blocks


def _selection_block(case: Dict[str, Any]) -> Dict[str, Any]:
    blocks: Dict[str, Any] = {}
    for policy in DuplicatePolicy:
        with TemporaryDirectory() as temp_dir:
            source = Path(temp_dir)
            materialize_case(case, source)
            try:
                scan = scan_source(source, duplicate_policy=policy)
            except RuntimeError:
                blocks[policy.value] = {"clip_set_count": 0, "rendered_duration": 0.0, "clip_sets": []}
                continue
            if not scan.clip_sets:
                blocks[policy.value] = {"clip_set_count": 0, "rendered_duration": 0.0, "clip_sets": []}
                continue
            first = scan.clip_sets[0].start_time
            last = scan.clip_sets[-1].start_time + timedelta(seconds=STUB_DURATION_SECONDS)
            selected = select_clip_sets(
                scan.clip_sets,
                first,
                last,
                STUB_FFPROBE,
                media_probe=StubMediaProbe(),
            )
            blocks[policy.value] = selected_sets_manifest(selected, source)
    return blocks


def _output_block(case: Dict[str, Any]) -> Dict[str, Any]:
    with TemporaryDirectory() as temp_dir:
        source = Path(temp_dir)
        materialize_case(case, source)
        try:
            scan = scan_source(source, duplicate_policy=DuplicatePolicy.MERGE_BY_TIME)
        except RuntimeError:
            return {"empty_dataset": True}
        if not scan.clip_sets:
            return {"empty_dataset": True}
        start, end = dataset_range(scan.clip_sets, STUB_FFPROBE, media_probe=StubMediaProbe())

    defaults = {
        mode: default_output_filename(mode, start, end)
        for mode in ("lossless", "quality")
    }
    target_name = defaults["lossless"]

    unique_resolution: List[str] = []
    with TemporaryDirectory() as out_dir:
        target = Path(out_dir) / target_name
        for _ in range(3):
            picked = apply_output_conflict_policy(target, OutputConflictPolicy.UNIQUE)
            unique_resolution.append(picked.name)
            picked.touch()

    with TemporaryDirectory() as out_dir:
        target = Path(out_dir) / target_name
        target.touch()
        overwrite_resolved = apply_output_conflict_policy(target, OutputConflictPolicy.OVERWRITE).name

    error_block: Dict[str, Any] = {"raises": False, "exception_type": None, "message_contains": None}
    with TemporaryDirectory() as out_dir:
        target = Path(out_dir) / target_name
        target.touch()
        try:
            apply_output_conflict_policy(target, OutputConflictPolicy.ERROR)
        except RuntimeError as exc:
            assert ERROR_MESSAGE_FRAGMENT in str(exc), (
                f"error policy must surface a message containing {ERROR_MESSAGE_FRAGMENT!r}; "
                f"got: {exc!r}"
            )
            error_block = {
                "raises": True,
                "exception_type": type(exc).__name__,
                "message_contains": ERROR_MESSAGE_FRAGMENT,
            }

    return {
        "default_filename_by_mode": defaults,
        "unique_resolution": unique_resolution,
        "overwrite_with_conflict": overwrite_resolved,
        "error_with_conflict": error_block,
    }


def regenerate(case: Dict[str, Any]) -> Dict[str, Any]:
    case["expected_scan"] = _scan_block(case)
    case["expected_layout"] = _layout_block(case)
    case["expected_selection"] = _selection_block(case)
    case["expected_output"] = _output_block(case)
    return case


def main() -> int:
    cases = sorted(FIXTURE_DIR.glob("*.json"))
    if not cases:
        print(f"No fixtures found under {FIXTURE_DIR}")
        return 1
    for fixture_path in cases:
        case = json.loads(fixture_path.read_text(encoding="utf-8"))
        regenerate(case)
        rendered = json.dumps(case, indent=2, sort_keys=True) + "\n"
        fixture_path.write_text(rendered, encoding="utf-8")
        print(f"updated {fixture_path.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
