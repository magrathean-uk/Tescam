from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest


REAL_FOOTAGE_ENV = "TESCAM_REAL_FOOTAGE_SOURCE"
REAL_FOOTAGE_RENDER_ENV = "TESCAM_REAL_FOOTAGE_RENDER"


def _real_footage_render_opted_in() -> bool:
    """The render test is heavier than the planner test (~3 s wall +
    ~10 MB output for a 2-second window). Require an explicit opt-in
    via ``TESCAM_REAL_FOOTAGE_RENDER`` so routine
    ``unittest discover`` runs are not slowed even when the source
    folder happens to be present.
    """
    raw = os.environ.get(REAL_FOOTAGE_RENDER_ENV, "")
    return raw.strip().lower() in {"1", "true", "yes", "y", "on"}


def _real_footage_source() -> Path | None:
    """Return the configured real-footage source folder, or ``None``.

    Two ways to opt in:
    - ``TESCAM_REAL_FOOTAGE_SOURCE=/abs/path`` (preferred, works on
      any machine and in CI if a runner happens to have a sample).
    - ``~/Downloads/Tescam`` exists (local convenience for the
      project owner — same path used in
      ``docs/improvement/real-footage-baseline-2026-05-09.md``).

    Either way, the test only fires when the path is a directory; CI
    runs without either path skip the test silently.
    """
    explicit = os.environ.get(REAL_FOOTAGE_ENV)
    if explicit:
        candidate = Path(explicit).expanduser()
        if candidate.is_dir():
            return candidate
        return None
    fallback = Path.home() / "Downloads" / "Tescam"
    if fallback.is_dir():
        return fallback
    return None


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg/ffprobe required")
class IntegrationTests(unittest.TestCase):
    def test_cli_dry_run_json_writes_manifest_without_render(self):
        repo_root = Path(__file__).resolve().parent.parent
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "clips"
            source.mkdir(parents=True)
            for camera in ["front", "rear", "left_repeater", "right_repeater"]:
                file_path = source / f"2026-01-01_00-00-00-{camera}.mp4"
                subprocess.run(
                    [
                        "ffmpeg",
                        "-y",
                        "-hide_banner",
                        "-loglevel",
                        "error",
                        "-f",
                        "lavfi",
                        "-i",
                        "testsrc=size=160x90:rate=10",
                        "-t",
                        "1",
                        "-c:v",
                        "libx264",
                        str(file_path),
                    ],
                    check=True,
                )
            manifest_path = root / "manifest.json"

            subprocess.run(
                [
                    sys.executable,
                    str(repo_root / "tescam.py"),
                    str(source),
                    "--dry-run-json",
                    str(manifest_path),
                    "--start",
                    "2026-01-01 00:00:00",
                    "--end",
                    "2026-01-01 00:00:01",
                    "--profile",
                    "legacy4",
                ],
                check=True,
            )

            self.assertTrue(manifest_path.exists())
            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(payload["type"], "tescam.dry-run")
            self.assertEqual(payload["scan"]["clip_set_count"], 1)
            self.assertEqual(payload["selection"]["clip_set_count"], 1)

    def test_cli_composes_lossless_hevc_mp4(self):
        repo_root = Path(__file__).resolve().parent.parent
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "clips"
            source.mkdir(parents=True)
            for index, camera in enumerate(["front", "rear", "left_repeater", "right_repeater"]):
                file_path = source / f"2026-01-01_00-00-00-{camera}.mp4"
                subprocess.run(
                    [
                        "ffmpeg",
                        "-y",
                        "-hide_banner",
                        "-loglevel",
                        "error",
                        "-f",
                        "lavfi",
                        "-i",
                        f"testsrc=size=160x90:rate=10",
                        "-t",
                        "1",
                        "-c:v",
                        "libx264",
                        str(file_path),
                    ],
                    check=True,
                )
            output = root / "out.mp4"
            subprocess.run(
                [
                    sys.executable,
                    str(repo_root / "tescam.py"),
                    str(source),
                    "--output",
                    str(output),
                    "--start",
                    "2026-01-01 00:00:00",
                    "--end",
                    "2026-01-01 00:00:01",
                    "--mode",
                    "lossless",
                    "--profile",
                    "legacy4",
                    "--loglevel",
                    "error",
                ],
                check=True,
            )
            self.assertTrue(output.exists())
            probe = subprocess.run(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-select_streams",
                    "v:0",
                    "-show_entries",
                    "stream=codec_name,width,height",
                    "-of",
                    "default=nk=1:nw=1",
                    str(output),
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            fields = probe.stdout.strip().splitlines()
            self.assertEqual(fields[0], "hevc")
            self.assertEqual(fields[1], "320")
            self.assertEqual(fields[2], "180")

    def test_cli_substitutes_black_tile_for_corrupt_camera(self):
        repo_root = Path(__file__).resolve().parent.parent
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "clips"
            source.mkdir(parents=True)
            for camera in ["front", "rear", "left_repeater"]:
                file_path = source / f"2026-01-01_00-00-00-{camera}.mp4"
                subprocess.run(
                    [
                        "ffmpeg",
                        "-y",
                        "-hide_banner",
                        "-loglevel",
                        "error",
                        "-f",
                        "lavfi",
                        "-i",
                        f"testsrc=size=160x90:rate=10",
                        "-t",
                        "1",
                        "-c:v",
                        "libx264",
                        str(file_path),
                    ],
                    check=True,
                )
            (source / "2026-01-01_00-00-00-right_repeater.mp4").write_bytes(b"not-a-valid-mp4")
            output = root / "out_corrupt.mp4"
            subprocess.run(
                [
                    sys.executable,
                    str(repo_root / "tescam.py"),
                    str(source),
                    "--output",
                    str(output),
                    "--start",
                    "2026-01-01 00:00:00",
                    "--end",
                    "2026-01-01 00:00:01",
                    "--mode",
                    "lossless",
                    "--profile",
                    "legacy4",
                    "--loglevel",
                    "error",
                ],
                check=True,
            )
            self.assertTrue(output.exists())
            probe = subprocess.run(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-select_streams",
                    "v:0",
                    "-show_entries",
                    "stream=codec_name,width,height",
                    "-of",
                    "default=nk=1:nw=1",
                    str(output),
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            fields = probe.stdout.strip().splitlines()
            self.assertEqual(fields[0], "hevc")
            self.assertEqual(fields[1], "320")
            self.assertEqual(fields[2], "180")


@unittest.skipUnless(_real_footage_source() is not None, f"real-footage source not configured (set {REAL_FOOTAGE_ENV} or place a folder at ~/Downloads/Tescam)")
class RealFootageIntegrationTests(unittest.TestCase):
    """Opt-in tests that run against real Tesla recording data.

    Skipped on CI and on any machine where the configured source
    folder is missing. When fired, they exercise the planner end-to-
    end against real bytes — that's a different surface from the
    synthetic IntegrationTests above, which always run on tiny
    160×90 lavfi clips.

    These do NOT trigger an actual render — wall-clock + GB output
    would be too heavy for an autonomous loop. Render-side coverage
    stays in IntegrationTests on synthetic input.
    """

    def test_cli_dry_run_json_against_real_footage(self):
        repo_root = Path(__file__).resolve().parent.parent
        source = _real_footage_source()
        assert source is not None  # guarded by the skipUnless decorator

        with TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "manifest.json"
            subprocess.run(
                [
                    sys.executable,
                    str(repo_root / "tescam.py"),
                    str(source),
                    "--dry-run-json",
                    str(manifest_path),
                ],
                check=True,
            )
            self.assertTrue(manifest_path.exists())
            payload = json.loads(manifest_path.read_text(encoding="utf-8"))

        # Manifest envelope.
        self.assertEqual(payload.get("type"), "tescam.dry-run")
        self.assertEqual(payload.get("schema_version"), 1)

        # Scan should find at least one clip set in real footage.
        scan = payload.get("scan", {})
        self.assertGreater(scan.get("clip_set_count", 0), 0, "real footage must produce at least one clip set")
        self.assertIn("cameras", scan)
        self.assertGreater(len(scan["cameras"]), 0, "real footage must surface at least one camera")

        # Selection block lines up with scan when no explicit time range
        # is passed; the CLI defaults to the dataset's natural range.
        selection = payload.get("selection", {})
        self.assertGreaterEqual(
            selection.get("clip_set_count", 0),
            1,
            "selection must include at least one clip set under default range",
        )
        self.assertGreater(
            selection.get("rendered_duration", 0.0),
            0.0,
            "rendered_duration must be positive on real footage",
        )

        # Layout invariants — fixture-pinned profile must surface and
        # canvas dimensions must be positive integers.
        layout = payload.get("layout", {})
        self.assertIn(layout.get("kind"), {"4up", "6up"})
        self.assertIn(layout.get("profile"), {"auto", "legacy4", "sixcam"})
        canvas = layout.get("canvas", {})
        self.assertGreater(canvas.get("width", 0), 0)
        self.assertGreater(canvas.get("height", 0), 0)

        # Probed FPS must be a sensible Tescam-ish value (the contract
        # has historically seen ~24 and ~36 from different firmware).
        # 1 < fps < 120 is the conservative envelope.
        fps = payload.get("fps")
        self.assertIsInstance(fps, (int, float))
        self.assertGreater(fps, 1.0)
        self.assertLess(fps, 120.0)


@unittest.skipUnless(
    _real_footage_source() is not None and _real_footage_render_opted_in(),
    f"real-footage render test requires a configured source AND {REAL_FOOTAGE_RENDER_ENV}=1 (heavier than planner test; ~3s wall + 10 MB output)",
)
class RealFootageRenderIntegrationTests(unittest.TestCase):
    """Opt-in real-footage render. Skipped by default — both
    `_real_footage_source()` and `TESCAM_REAL_FOOTAGE_RENDER=1`
    must hold for it to fire. CI never has either; local
    developers turn it on when validating the end-to-end ffmpeg
    pipeline against real bytes (e.g. before shipping a release
    candidate).

    The test renders a tight 2-second window with the fastest
    encoder preset so the wall-clock stays small and the output
    fits comfortably in a TemporaryDirectory.
    """

    def test_cli_renders_brief_window_from_real_footage(self):
        repo_root = Path(__file__).resolve().parent.parent
        source = _real_footage_source()
        assert source is not None  # guarded by skipUnless

        with TemporaryDirectory() as temp_dir:
            output = Path(temp_dir) / "render.mp4"
            subprocess.run(
                [
                    sys.executable,
                    str(repo_root / "tescam.py"),
                    str(source),
                    "--start",
                    "2026-04-08 11:30:35",
                    "--end",
                    "2026-04-08 11:30:37",
                    "--output",
                    str(output),
                    "--mode",
                    "quality",
                    "--x265-preset",
                    "ultrafast",
                    "--loglevel",
                    "error",
                ],
                check=True,
            )
            self.assertTrue(output.exists(), "render must produce an output mp4")
            self.assertGreater(output.stat().st_size, 0, "output must be non-empty")

            probe = subprocess.run(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-select_streams",
                    "v:0",
                    "-show_entries",
                    "stream=codec_name,width,height",
                    "-of",
                    "default=nk=1:nw=1",
                    str(output),
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            fields = probe.stdout.strip().splitlines()
            self.assertEqual(fields[0], "hevc", "real-footage render must produce HEVC output")
            # HW3 4-cam canvas: 2560 × 1920 (two 1280×960 tiles per row).
            self.assertEqual(fields[1], "2560")
            self.assertEqual(fields[2], "1920")


if __name__ == "__main__":
    unittest.main()
