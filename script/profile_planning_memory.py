#!/usr/bin/env python3
"""Profile peak memory of the CLI planning phase across dataset sizes.

The CLI's per-event render loop is one concern (covered separately by
``--jobs`` and tracemalloc-on-real-ffmpeg work in D1/D5). This script
isolates the *planning* phase that runs before any ffmpeg invocation:
``scan_source`` → ``select_clip_sets`` → ``selected_sets_manifest`` →
``layout_manifest`` → ``dimensions_manifest``.

For each N in ``DATASET_SIZES``, the script:

1. Materializes a synthetic source folder under a tempdir with
   ``N × 6`` empty clip files (one timestamp per minute, six HW4
   cameras).
2. Times and tracemalloc-measures the planning pipeline using the
   contract's own helpers + a deterministic stub probe (every clip =
   60 s, classical 1280×960). No real ``ffprobe`` invocation.
3. Prints a single-line summary per N.

Run::

    source .cache/venv/bin/activate
    python3 script/profile_planning_memory.py

The output feeds ``docs/improvement/cli-memory-baseline.md``.
"""
from __future__ import annotations

import gc
import json
import time
import tracemalloc
from datetime import datetime, timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Tuple

from tescam_cli.composer import select_clip_sets
from tescam_cli.domain_contract import (
    dimensions_manifest,
    layout_manifest,
    scan_manifest,
    selected_sets_manifest,
)
from tescam_cli.layouts import build_camera_layout_plan, fill_missing_dimensions
from tescam_cli.models import Camera, Dimensions, DuplicatePolicy, LayoutKind
from tescam_cli.scanner import scan_source

DATASET_SIZES = (10, 100, 1_000, 10_000)
STUB_FFPROBE = Path("/usr/bin/ffprobe")
STUB_DIMENSIONS = Dimensions(width=1280, height=960)
HW4_CAMERAS = (
    "front",
    "back",
    "left",
    "right",
    "left_pillar",
    "right_pillar",
)


class StubMediaProbe:
    """Same stub used by script/regen_fixtures.py — stable across the codebase."""

    def duration(self, ffprobe, media_path):
        return 60.0

    def has_video_stream(self, ffprobe, media_path):
        return True

    def dimensions(self, ffprobe, media_path):
        return STUB_DIMENSIONS

    def fps(self, ffprobe, media_path):
        return 36.027


def materialize_synthetic_source(root: Path, count: int) -> None:
    """Write ``count`` HW4 timestamps (6 cameras each) under ``root``."""
    base = datetime(2026, 1, 1, 0, 0, 0)
    saved = root / "SavedClips"
    saved.mkdir(parents=True, exist_ok=True)
    for index in range(count):
        when = base + timedelta(minutes=index)
        stamp = when.strftime("%Y-%m-%d_%H-%M-%S")
        for camera in HW4_CAMERAS:
            (saved / f"{stamp}-{camera}.mp4").write_bytes(b"fixture")


def profile_one(count: int) -> Tuple[float, int]:
    """Return ``(wall_seconds, tracemalloc_peak_bytes)`` for the planning pipeline."""
    with TemporaryDirectory() as temp_dir:
        source = Path(temp_dir)
        materialize_synthetic_source(source, count)

        gc.collect()
        tracemalloc.start()
        wall_start = time.monotonic()

        scan = scan_source(source, duplicate_policy=DuplicatePolicy.MERGE_BY_TIME)
        first = scan.clip_sets[0].start_time
        last = scan.clip_sets[-1].start_time + timedelta(seconds=60.0)
        selected = select_clip_sets(
            scan.clip_sets,
            first,
            last,
            STUB_FFPROBE,
            media_probe=StubMediaProbe(),
        )
        layout = build_camera_layout_plan(
            profile="auto",
            available_cameras=scan.cameras,
            probed_dimensions={camera: STUB_DIMENSIONS for camera in scan.cameras},
        )
        dimensions = fill_missing_dimensions(LayoutKind.SIX_UP, {camera: STUB_DIMENSIONS for camera in scan.cameras})

        scan_block = scan_manifest(scan, source)
        selection_block = selected_sets_manifest(selected, source)
        layout_block = layout_manifest(layout)
        dimensions_block = dimensions_manifest(dimensions)

        # Force-serialise to a JSON string so the manifest's transient
        # in-memory representation is fully exercised.
        payload_size = len(
            json.dumps(
                {
                    "scan": scan_block,
                    "selection": selection_block,
                    "layout": layout_block,
                    "dimensions": dimensions_block,
                },
                sort_keys=True,
            )
        )

        wall_end = time.monotonic()
        _current, peak = tracemalloc.get_traced_memory()
        tracemalloc.stop()

    return wall_end - wall_start, peak, payload_size  # type: ignore[return-value]


def main() -> int:
    print(f"{'N':>8}  {'wall_s':>10}  {'peak_KB':>10}  {'json_KB':>10}")
    for count in DATASET_SIZES:
        wall, peak, payload = profile_one(count)
        print(
            f"{count:>8}  "
            f"{wall:>10.3f}  "
            f"{peak / 1024:>10.1f}  "
            f"{payload / 1024:>10.1f}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
