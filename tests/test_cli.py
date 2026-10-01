from contextlib import redirect_stdout
from datetime import datetime
from io import StringIO
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from tescam_cli.cli import (
    RunOptions,
    RunPlanBuilder,
    apply_output_conflict_policy,
    build_parser,
    main,
    resolve_output_path,
    unique_output_path,
)
from tescam_cli.composer import RenderConcatStarted, RenderPartStarted, RenderStarted, compose
from tescam_cli.models import (
    Camera,
    CellSpec,
    ClipSet,
    ComposePlan,
    Dimensions,
    DuplicatePolicy,
    EncoderPlan,
    LayoutKind,
    LayoutSpec,
    OutputConflictPolicy,
    SelectedSet,
)


class FakeMediaProbe:
    def duration(self, _ffprobe, _media_path):
        return 60.0

    def dimensions(self, _ffprobe, _media_path):
        return Dimensions(width=160, height=90)

    def fps(self, _ffprobe, _media_path):
        return 10.0

    def has_video_stream(self, _ffprobe, _media_path):
        return True

    def choose_encoder(self, _ffmpeg, mode, _x265_preset):
        return EncoderPlan(mode=mode, args=["-c:v", "libx265"], output_extension="mp4", label=f"{mode}_fake")


class FakeRunner:
    def __init__(self):
        self.commands = []

    def run(self, args, cwd=None):
        self.commands.append((list(args), cwd))
        command = list(args)
        if "-f" in command and "concat" in command:
            Path(command[-1]).write_bytes(b"fake")


class FakeReporter:
    def __init__(self):
        self.events = []

    def handle_render_event(self, event):
        self.events.append(event)


class CliPathTests(unittest.TestCase):
    def test_unique_output_path_adds_incrementing_suffix(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            original = root / "out.mp4"
            second = root / "out-2.mp4"
            original.write_bytes(b"x")
            second.write_bytes(b"x")

            resolved = unique_output_path(original)

        self.assertEqual(resolved.name, "out-3.mp4")

    def test_apply_output_conflict_policy_errors_when_requested(self):
        with TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "existing.mp4"
            path.write_bytes(b"x")

            with self.assertRaises(RuntimeError):
                apply_output_conflict_policy(path, OutputConflictPolicy.ERROR)

    def test_apply_output_conflict_policy_overwrite_keeps_existing_path(self):
        with TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "existing.mp4"
            path.write_bytes(b"x")

            resolved = apply_output_conflict_policy(path, OutputConflictPolicy.OVERWRITE)

        self.assertEqual(resolved, path)

    def test_resolve_output_path_uses_directory_argument_as_output_folder(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "source"
            destination = root / "exports"
            source.mkdir()
            destination.mkdir()
            start = datetime(2026, 1, 1, 0, 0, 0)
            end = datetime(2026, 1, 1, 0, 1, 0)

            resolved = resolve_output_path(
                source,
                str(destination),
                mode="lossless",
                start_time=start,
                end_time=end,
                output_conflict=OutputConflictPolicy.UNIQUE,
            )

        self.assertEqual(resolved.parent, destination.resolve())
        self.assertTrue(resolved.name.startswith("tescam_lossless_"))
        self.assertEqual(resolved.suffix, ".mp4")

    def test_default_output_path_does_not_create_output_directory(self):
        with TemporaryDirectory() as temp_dir:
            source = Path(temp_dir)
            start = datetime(2026, 1, 1, 0, 0, 0)
            end = datetime(2026, 1, 1, 0, 1, 0)

            resolved = resolve_output_path(
                source,
                None,
                mode="lossless",
                start_time=start,
                end_time=end,
                output_conflict=OutputConflictPolicy.UNIQUE,
            )

            self.assertEqual(resolved.parent, (source / "output").resolve())
            self.assertFalse((source / "output").exists())

    def test_dry_run_json_defaults_to_stdout_and_implies_no_render_contract(self):
        args = build_parser().parse_args(["/tmp/source", "--dry-run-json"])

        self.assertEqual(args.dry_run_json, "-")

    def test_parser_defaults_to_app_style_evidence_hevc(self):
        args = build_parser().parse_args(["/tmp/source"])

        self.assertEqual(args.mode, "evidence-hevc")

    def test_parser_accepts_legacy_quality_mode(self):
        args = build_parser().parse_args(["/tmp/source", "--mode", "quality"])

        self.assertEqual(args.mode, "quality")

    def test_dry_run_json_accepts_output_path(self):
        args = build_parser().parse_args(["/tmp/source", "--dry-run-json", "/tmp/manifest.json"])

        self.assertEqual(args.dry_run_json, "/tmp/manifest.json")

    def test_run_plan_builder_resolves_plan_with_fake_probe(self):
        with TemporaryDirectory() as temp_dir:
            source = Path(temp_dir)
            for camera in ["front", "rear", "left_repeater", "right_repeater"]:
                (source / f"2026-01-01_00-00-00-{camera}.mp4").write_bytes(b"x")

            plan = RunPlanBuilder(media_probe=FakeMediaProbe()).build(
                RunOptions(
                    source_dir=source,
                    output_arg=None,
                    start_arg=None,
                    end_arg=None,
                    profile="legacy4",
                    mode="lossless",
                    ffmpeg=Path("/fake/ffmpeg"),
                    ffprobe=Path("/fake/ffprobe"),
                    workdir_arg=None,
                    keep_workdir=False,
                    x265_preset="medium",
                    loglevel="info",
                    duplicate_policy=DuplicatePolicy.MERGE_BY_TIME,
                    output_conflict=OutputConflictPolicy.UNIQUE,
                )
            )

        self.assertEqual(len(plan.selected_sets), 1)
        self.assertEqual(plan.layout.kind.value, "4up")
        self.assertEqual(plan.fps, 10.0)
        self.assertEqual(plan.encoder.label, "lossless_fake")

    def test_dry_run_does_not_create_workdir(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "clips"
            source.mkdir()
            for camera in ["front", "rear", "left_repeater", "right_repeater"]:
                (source / f"2026-01-01_00-00-00-{camera}.mp4").write_bytes(b"x")
            workdir = root / "work"

            with patch("tescam_cli.cli.resolve_tools", return_value=(Path("/fake/ffmpeg"), Path("/fake/ffprobe"))):
                with patch("tescam_cli.cli.MediaProbe", return_value=FakeMediaProbe()):
                    result = main(
                        [
                            str(source),
                            "--dry-run",
                            "--workdir",
                            str(workdir),
                            "--profile",
                            "legacy4",
                        ]
                    )

        self.assertEqual(result, 0)
        self.assertFalse(workdir.exists())

    def test_compose_emits_render_events_without_printing(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            clip = root / "2026-01-01_00-00-00-front.mp4"
            clip.write_bytes(b"x")
            selected = SelectedSet(
                clip_set=ClipSet(
                    timestamp="2026-01-01_00-00-00",
                    start_time=datetime(2026, 1, 1, 0, 0, 0),
                    files={Camera.FRONT: clip},
                ),
                duration=1.0,
                trim_start=0.0,
                trim_end=1.0,
            )
            layout = LayoutSpec(
                kind=LayoutKind.FOUR_UP,
                cameras=[Camera.FRONT],
                cell_by_camera={Camera.FRONT: CellSpec(width=160, height=90, x=0, y=0)},
                canvas_width=160,
                canvas_height=90,
            )
            runner = FakeRunner()
            reporter = FakeReporter()
            plan = ComposePlan(
                source_dir=root,
                output_file=root / "out.mp4",
                ffmpeg=Path("/fake/ffmpeg"),
                ffprobe=Path("/fake/ffprobe"),
                layout=layout,
                fps=10.0,
                encoder=EncoderPlan(
                    mode="lossless",
                    args=["-c:v", "libx265"],
                    output_extension="mp4",
                    label="lossless_fake",
                ),
                selected_sets=[selected],
                dimensions_by_camera={Camera.FRONT: Dimensions(width=160, height=90)},
                workdir=root / "work",
                keep_workdir=False,
                loglevel="info",
                media_probe=FakeMediaProbe(),
                ffmpeg_runner=runner,
                render_reporter=reporter,
            )
            output = StringIO()

            with redirect_stdout(output):
                compose(plan)

        self.assertEqual(output.getvalue(), "")
        self.assertEqual(len(runner.commands), 2)
        self.assertIsInstance(reporter.events[0], RenderStarted)
        self.assertIsInstance(reporter.events[1], RenderPartStarted)
        self.assertIsInstance(reporter.events[2], RenderConcatStarted)


if __name__ == "__main__":
    unittest.main()
