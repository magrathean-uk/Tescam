import json
import os
from datetime import timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from tescam_cli.cli import (
    apply_output_conflict_policy,
    dataset_range,
    default_output_filename,
    unique_output_path,
)
from tescam_cli.composer import select_clip_sets
from tescam_cli.domain_contract import (
    dry_run_manifest,
    manifest_json,
    scan_manifest,
    selected_sets_manifest,
)
from tescam_cli.layouts import build_camera_layout_plan, build_layout, fill_missing_dimensions
from tescam_cli.models import Camera, Dimensions, DuplicatePolicy, LayoutKind, OutputConflictPolicy, SelectedSet
from tescam_cli.scanner import scan_source

FIXTURE_DIR = Path(__file__).resolve().parent.parent / "fixtures" / "domain" / "cases"

# Stand-in ffprobe + duration that mirror ``script/regen_selection_fixtures.py``.
# Keep the two in lockstep; this parity test is the gate that catches drift.
_STUB_FFPROBE = Path("/usr/bin/ffprobe")
_STUB_DURATION_SECONDS = 60.0


class _StubMediaProbe:
    """Deterministic probe for fixture-driven selection tests.

    Same shape as ``script/regen_selection_fixtures.py``'s stub. Every clip is
    60 s, every clip has a video stream, dimensions/fps are unused for
    selection itself.
    """

    def duration(self, ffprobe, media_path):
        return _STUB_DURATION_SECONDS

    def has_video_stream(self, ffprobe, media_path):
        return True

    def dimensions(self, ffprobe, media_path):
        return None

    def fps(self, ffprobe, media_path):
        return 36.027


class DomainFixtureParityTests(unittest.TestCase):
    def test_shared_scan_fixtures_match_python_manifest_for_all_duplicate_policies(self):
        cases = sorted(FIXTURE_DIR.glob("*.json"))
        self.assertGreaterEqual(len(cases), 4)
        for fixture_path in cases:
            with self.subTest(fixture=fixture_path.name):
                case = json.loads(fixture_path.read_text(encoding="utf-8"))
                with TemporaryDirectory() as temp_dir:
                    source = Path(temp_dir)
                    _materialize_case(case, source)
                    for policy in DuplicatePolicy:
                        with self.subTest(policy=policy.value):
                            result = scan_source(source, duplicate_policy=policy)
                            manifest = scan_manifest(result, source)
                            manifest.pop("schema_version")
                            manifest.pop("type")
                            self.assertEqual(manifest, case["expected_scan"][policy.value])

    def test_shared_layout_fixtures_round_trip_through_scan_then_layout_for_all_profiles(self):
        from tescam_cli.domain_contract import layout_manifest
        cases = sorted(FIXTURE_DIR.glob("*.json"))
        self.assertGreaterEqual(len(cases), 4)
        for fixture_path in cases:
            with self.subTest(fixture=fixture_path.name):
                case = json.loads(fixture_path.read_text(encoding="utf-8"))
                self.assertIn("expected_layout", case, f"{fixture_path.name} missing expected_layout")
                self.assertEqual(set(case["expected_layout"]), {"auto", "legacy4", "sixcam"})
                with TemporaryDirectory() as temp_dir:
                    source = Path(temp_dir)
                    _materialize_case(case, source)
                    scan = scan_source(source, duplicate_policy=DuplicatePolicy.MERGE_BY_TIME)
                    for profile in ("auto", "legacy4", "sixcam"):
                        with self.subTest(profile=profile):
                            layout = build_camera_layout_plan(
                                profile=profile,
                                available_cameras=scan.cameras,
                                probed_dimensions={},
                            )
                            self.assertEqual(layout_manifest(layout), case["expected_layout"][profile])

    def test_shared_selection_fixtures_round_trip_through_select_clip_sets_for_all_duplicate_policies(self):
        cases = sorted(FIXTURE_DIR.glob("*.json"))
        self.assertGreaterEqual(len(cases), 4)
        for fixture_path in cases:
            with self.subTest(fixture=fixture_path.name):
                case = json.loads(fixture_path.read_text(encoding="utf-8"))
                self.assertIn(
                    "expected_selection",
                    case,
                    f"{fixture_path.name} missing expected_selection — run script/regen_fixtures.py",
                )
                self.assertEqual(
                    set(case["expected_selection"]),
                    {policy.value for policy in DuplicatePolicy},
                    f"{fixture_path.name} expected_selection must cover every duplicate policy",
                )
                with TemporaryDirectory() as temp_dir:
                    source = Path(temp_dir)
                    _materialize_case(case, source)
                    for policy in DuplicatePolicy:
                        with self.subTest(policy=policy.value):
                            try:
                                scan = scan_source(source, duplicate_policy=policy)
                            except RuntimeError:
                                self.assertEqual(
                                    case["expected_selection"][policy.value],
                                    {"clip_set_count": 0, "rendered_duration": 0.0, "clip_sets": []},
                                )
                                continue
                            if not scan.clip_sets:
                                self.assertEqual(
                                    case["expected_selection"][policy.value],
                                    {"clip_set_count": 0, "rendered_duration": 0.0, "clip_sets": []},
                                )
                                continue
                            first = scan.clip_sets[0].start_time
                            last = scan.clip_sets[-1].start_time + timedelta(seconds=_STUB_DURATION_SECONDS)
                            selected = select_clip_sets(
                                scan.clip_sets,
                                first,
                                last,
                                _STUB_FFPROBE,
                                media_probe=_StubMediaProbe(),
                            )
                            self.assertEqual(
                                selected_sets_manifest(selected, source),
                                case["expected_selection"][policy.value],
                            )

    def test_shared_output_fixtures_match_apply_output_conflict_policy_for_all_policies(self):
        cases = sorted(FIXTURE_DIR.glob("*.json"))
        self.assertGreaterEqual(len(cases), 4)
        for fixture_path in cases:
            with self.subTest(fixture=fixture_path.name):
                case = json.loads(fixture_path.read_text(encoding="utf-8"))
                self.assertIn(
                    "expected_output",
                    case,
                    f"{fixture_path.name} missing expected_output — run script/regen_fixtures.py",
                )
                expected = case["expected_output"]
                with TemporaryDirectory() as temp_dir:
                    source = Path(temp_dir)
                    _materialize_case(case, source)
                    try:
                        scan = scan_source(source, duplicate_policy=DuplicatePolicy.MERGE_BY_TIME)
                        clip_sets = scan.clip_sets
                    except RuntimeError:
                        clip_sets = []

                if not clip_sets:
                    self.assertTrue(
                        expected.get("empty_dataset"),
                        f"{fixture_path.name} produced no clips but expected_output is non-empty",
                    )
                    continue

                self.assertNotIn(
                    "empty_dataset",
                    expected,
                    f"{fixture_path.name} expected_output.empty_dataset must not be set when clips exist",
                )
                start, end = dataset_range(clip_sets, _STUB_FFPROBE, media_probe=_StubMediaProbe())
                actual_defaults = {
                    mode: default_output_filename(mode, start, end)
                    for mode in ("lossless", "quality")
                }
                self.assertEqual(actual_defaults, expected["default_filename_by_mode"])

                target_name = actual_defaults["lossless"]

                # `unique` cascade: three calls in a fresh tempdir.
                with TemporaryDirectory() as out_dir:
                    target = Path(out_dir) / target_name
                    actual_unique = []
                    for _ in range(3):
                        picked = apply_output_conflict_policy(target, OutputConflictPolicy.UNIQUE)
                        actual_unique.append(picked.name)
                        picked.touch()
                self.assertEqual(actual_unique, expected["unique_resolution"])

                # `overwrite` policy returns the same path even if a file exists.
                with TemporaryDirectory() as out_dir:
                    target = Path(out_dir) / target_name
                    target.touch()
                    picked = apply_output_conflict_policy(target, OutputConflictPolicy.OVERWRITE)
                self.assertEqual(picked.name, expected["overwrite_with_conflict"])

                # `error` policy raises with a stable message fragment.
                expected_error = expected["error_with_conflict"]
                with TemporaryDirectory() as out_dir:
                    target = Path(out_dir) / target_name
                    target.touch()
                    if expected_error.get("raises"):
                        with self.assertRaises(RuntimeError) as ctx:
                            apply_output_conflict_policy(target, OutputConflictPolicy.ERROR)
                        self.assertEqual(type(ctx.exception).__name__, expected_error["exception_type"])
                        self.assertIn(expected_error["message_contains"], str(ctx.exception))
                    else:
                        # Currently no fixture exercises the no-raise branch
                        # (existence + ERROR policy always raises). Keep the
                        # assertion present so future fixtures stay honest.
                        picked = apply_output_conflict_policy(target, OutputConflictPolicy.ERROR)
                        self.assertEqual(picked.name, target_name)

    def test_default_output_filename_matches_contract_format(self):
        from datetime import datetime
        start = datetime(2026, 1, 1, 0, 0, 0)
        end = datetime(2026, 1, 1, 0, 5, 30)
        self.assertEqual(
            default_output_filename("lossless", start, end),
            "tescam_lossless_2026-01-01_00-00-00_to_2026-01-01_00-05-30.mp4",
        )
        self.assertEqual(
            default_output_filename("fast", start, end),
            "tescam_fast_2026-01-01_00-00-00_to_2026-01-01_00-05-30.mp4",
        )

    def test_unique_output_path_appends_dash_counter(self):
        with TemporaryDirectory() as temp_dir:
            base = Path(temp_dir) / "tescam_lossless_a_to_b.mp4"
            base.write_bytes(b"")
            self.assertEqual(unique_output_path(base).name, "tescam_lossless_a_to_b-2.mp4")
            (base.parent / "tescam_lossless_a_to_b-2.mp4").write_bytes(b"")
            self.assertEqual(unique_output_path(base).name, "tescam_lossless_a_to_b-3.mp4")

    def test_dry_run_manifest_is_machine_readable_and_contains_export_contract(self):
        with TemporaryDirectory() as temp_dir:
            source = Path(temp_dir)
            front = source / "2026-01-01_00-00-00-front.mp4"
            back = source / "2026-01-01_00-00-00-rear.mp4"
            front.write_bytes(b"front")
            back.write_bytes(b"back")

            result = scan_source(source)
            selected = [
                SelectedSet(
                    clip_set=result.clip_sets[0],
                    duration=60.0,
                    trim_start=5.0,
                    trim_end=30.0,
                )
            ]
            dimensions = fill_missing_dimensions(
                LayoutKind.FOUR_UP,
                {
                    Camera.FRONT: Dimensions(width=1280, height=960),
                    Camera.BACK: Dimensions(width=1280, height=960),
                },
            )
            layout = build_layout(LayoutKind.FOUR_UP, dimensions)
            manifest = dry_run_manifest(
                source_dir=source,
                output_file=source / "output.mp4",
                start_time=result.clip_sets[0].start_time,
                end_time=result.clip_sets[0].start_time,
                profile="legacy4",
                mode="lossless",
                duplicate_policy=DuplicatePolicy.MERGE_BY_TIME,
                output_conflict=OutputConflictPolicy.UNIQUE,
                scan_result=result,
                selected_sets=selected,
                layout=layout,
                dimensions=dimensions,
                fps=30.0,
                encoder_label="x265 lossless HEVC",
            )

        payload = json.loads(manifest_json(manifest))
        self.assertEqual(payload["schema_version"], 1)
        self.assertEqual(payload["type"], "tescam.dry-run")
        self.assertEqual(payload["duplicate_policy"], "merge-by-time")
        self.assertEqual(payload["output_conflict"], "unique")
        self.assertEqual(payload["telemetry"]["sei_inspection"], "not_performed")
        self.assertFalse(payload["telemetry"]["cli_render_overlay"])
        self.assertTrue(payload["telemetry"]["native_export_overlay"])
        self.assertEqual(payload["telemetry"]["speed_units"], ["km/h", "mph"])
        self.assertEqual(payload["scan"]["clip_set_count"], 1)
        self.assertEqual(payload["selection"]["rendered_duration"], 25.0)
        self.assertEqual(payload["layout"]["kind"], "4up")


def _materialize_case(case: dict, source: Path) -> None:
    for entry in case["files"]:
        path = source / entry["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"fixture")
        if "mtime" in entry:
            os.utime(path, (entry["mtime"], entry["mtime"]))




if __name__ == "__main__":
    unittest.main()
