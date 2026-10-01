"""Confirm the ffprobe parallelization actually parallelizes.

These tests use a stub ``MediaProbe`` whose ``duration``/``has_video_stream``/
``dimensions`` calls each block on ``time.sleep`` for a known interval. With
4 worker threads and 8 unique paths, parallel wall-clock should be roughly
half the sequential time — well under serial × 1.5 — and the results must
be identical to the serial baseline.
"""
from __future__ import annotations

import os
import time
import unittest
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory

from tescam_cli.composer import (
    _PROBE_MAX_WORKERS_DEFAULT,
    _concurrent_probe,
    collect_clip_readability,
    probe_dimensions_for_selection,
    select_clip_sets,
)
from tescam_cli.models import Camera, ClipSet, Dimensions, SelectedSet


_STUB_FFPROBE = Path("/usr/bin/ffprobe")
_PROBE_DELAY_SECONDS = 0.10


class _SleepProbe:
    """Stub probe that simulates I/O-bound ffprobe latency.

    Each call sleeps for a configurable delay so we can see parallelism in
    wall-clock numbers. Returns deterministic answers so result equality
    is testable.
    """

    def __init__(self, delay: float = _PROBE_DELAY_SECONDS) -> None:
        self.delay = delay
        self.duration_calls = 0
        self.dimension_calls = 0
        self.video_stream_calls = 0
        self.fps_calls = 0

    def duration(self, ffprobe, media_path):
        time.sleep(self.delay)
        self.duration_calls += 1
        return 60.0

    def dimensions(self, ffprobe, media_path):
        time.sleep(self.delay)
        self.dimension_calls += 1
        return Dimensions(width=1280, height=960)

    def fps(self, ffprobe, media_path):
        time.sleep(self.delay)
        self.fps_calls += 1
        return 36.027

    def has_video_stream(self, ffprobe, media_path):
        time.sleep(self.delay)
        self.video_stream_calls += 1
        return True


def _make_clip_set_with_paths(temp_dir: Path, timestamp: str, cameras_to_paths) -> ClipSet:
    files = {}
    for camera, path_name in cameras_to_paths.items():
        file_path = temp_dir / path_name
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_bytes(b"fixture")
        files[camera] = file_path
    return ClipSet(timestamp=timestamp, start_time=_TS, files=files)


_TS = datetime(2026, 6, 1, 0, 0, 0)


class ConcurrentProbeHelperTests(unittest.TestCase):
    def test_default_is_four_workers(self):
        self.assertEqual(_PROBE_MAX_WORKERS_DEFAULT, 4)

    def test_runs_jobs_in_parallel_under_serial_time_budget(self):
        # 8 jobs × 0.1 s = 0.8 s sequential; 4 workers should finish in ~0.2-0.3 s.
        delay = 0.10
        jobs = [(i, (lambda d=delay: (time.sleep(d), True)[1])) for i in range(8)]
        start = time.monotonic()
        result = _concurrent_probe(jobs, max_workers=4)
        elapsed = time.monotonic() - start
        self.assertEqual(result, {i: True for i in range(8)})
        self.assertLess(
            elapsed,
            8 * delay * 0.6,  # well under serial × 0.6 (i.e. > ~1.7× speedup)
            f"expected concurrent probe to be much faster than serial; got {elapsed:.3f}s",
        )

    def test_max_workers_one_runs_serially(self):
        delay = 0.05
        jobs = [(i, (lambda d=delay: (time.sleep(d), True)[1])) for i in range(4)]
        start = time.monotonic()
        result = _concurrent_probe(jobs, max_workers=1)
        elapsed = time.monotonic() - start
        self.assertEqual(result, {i: True for i in range(4)})
        # Serial baseline: should be at least 4 × delay (allow 10% scheduling slop).
        self.assertGreaterEqual(elapsed, 4 * delay * 0.9)

    def test_empty_jobs_returns_empty_dict(self):
        self.assertEqual(_concurrent_probe([]), {})


class CollectClipReadabilityRunsConcurrentlyTests(unittest.TestCase):
    def test_8_unique_paths_finish_under_serial_budget(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            # 4 sets × 2 cameras each = 8 unique paths.
            selected = []
            for i in range(4):
                clip_set = _make_clip_set_with_paths(
                    root,
                    f"2026-06-01_00-{i:02d}-00",
                    {
                        Camera.FRONT: f"set{i}/front.mp4",
                        Camera.BACK: f"set{i}/back.mp4",
                    },
                )
                selected.append(SelectedSet(clip_set=clip_set, duration=60.0, trim_start=0.0, trim_end=60.0))

            probe = _SleepProbe(delay=0.10)
            start = time.monotonic()
            result = collect_clip_readability(_STUB_FFPROBE, selected, media_probe=probe)
            elapsed = time.monotonic() - start

        # All unique paths must be present and resolved to True (the stub returns True).
        self.assertEqual(len(result), 8)
        self.assertTrue(all(value is True for value in result.values()))
        # 8 calls × 0.1s = 0.8s serial; with 4 workers should take < 0.5 s.
        self.assertLess(
            elapsed,
            0.5,
            f"expected parallel readability probe to finish well under 0.5s, got {elapsed:.3f}s",
        )
        self.assertEqual(probe.video_stream_calls, 8)


class ProbeDimensionsForSelectionRunsConcurrentlyTests(unittest.TestCase):
    def test_per_camera_dimension_probes_run_concurrently(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            clip_set = _make_clip_set_with_paths(
                root,
                "2026-06-01_00-00-00",
                {
                    Camera.FRONT: "front.mp4",
                    Camera.BACK: "back.mp4",
                    Camera.LEFT_REPEATER: "left_repeater.mp4",
                    Camera.RIGHT_REPEATER: "right_repeater.mp4",
                },
            )
            selected = [SelectedSet(clip_set=clip_set, duration=60.0, trim_start=0.0, trim_end=60.0)]
            probe = _SleepProbe(delay=0.10)

            start = time.monotonic()
            dimensions = probe_dimensions_for_selection(_STUB_FFPROBE, selected, media_probe=probe)
            elapsed = time.monotonic() - start

        self.assertEqual(set(dimensions), {Camera.FRONT, Camera.BACK, Camera.LEFT_REPEATER, Camera.RIGHT_REPEATER})
        # 4 cameras × 0.1s = 0.4s serial; with 4 workers should take ~0.1-0.2 s.
        self.assertLess(
            elapsed,
            0.3,
            f"expected parallel dimension probe to finish well under 0.3s, got {elapsed:.3f}s",
        )


class SelectClipSetsConcurrentDurationProbeTests(unittest.TestCase):
    def test_per_set_duration_probes_run_concurrently(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            clip_sets = []
            for i in range(8):
                # Each set gets one front clip; clip_set_duration walks the
                # files, so the stub probe is hit once per set.
                clip_set = _make_clip_set_with_paths(
                    root,
                    f"2026-06-01_00-{i:02d}-00",
                    {Camera.FRONT: f"set{i}/front.mp4"},
                )
                # Override timestamp so each set is sequential in time.
                clip_set = ClipSet(
                    timestamp=clip_set.timestamp,
                    start_time=datetime(2026, 6, 1, 0, i, 0),
                    files=clip_set.files,
                )
                clip_sets.append(clip_set)

            start_time = clip_sets[0].start_time
            end_time = datetime(2026, 6, 1, 23, 0, 0)
            probe = _SleepProbe(delay=0.10)

            start = time.monotonic()
            selected = select_clip_sets(clip_sets, start_time, end_time, _STUB_FFPROBE, media_probe=probe)
            elapsed = time.monotonic() - start

        self.assertEqual(len(selected), 8)
        # 8 sets × 0.1s = 0.8s serial; with 4 workers should be < 0.5 s.
        self.assertLess(
            elapsed,
            0.5,
            f"expected parallel duration probe to finish well under 0.5s, got {elapsed:.3f}s",
        )


class EnvOverrideTests(unittest.TestCase):
    def test_env_var_caps_worker_count(self):
        from tescam_cli.composer import _probe_max_workers

        original = os.environ.get("TESCAM_PROBE_JOBS")
        try:
            os.environ["TESCAM_PROBE_JOBS"] = "1"
            self.assertEqual(_probe_max_workers(), 1)
            os.environ["TESCAM_PROBE_JOBS"] = "16"
            self.assertEqual(_probe_max_workers(), 16)
            os.environ["TESCAM_PROBE_JOBS"] = "garbage"
            self.assertEqual(_probe_max_workers(), _PROBE_MAX_WORKERS_DEFAULT)
            os.environ["TESCAM_PROBE_JOBS"] = "0"
            self.assertEqual(_probe_max_workers(), _PROBE_MAX_WORKERS_DEFAULT)
        finally:
            if original is None:
                os.environ.pop("TESCAM_PROBE_JOBS", None)
            else:
                os.environ["TESCAM_PROBE_JOBS"] = original


if __name__ == "__main__":
    unittest.main()
