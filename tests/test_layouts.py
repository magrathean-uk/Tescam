import unittest
import json
from pathlib import Path

from tescam_cli.domain_contract import layout_manifest
from tescam_cli.layouts import build_camera_layout_plan, build_layout, fill_missing_dimensions
from tescam_cli.models import Camera, Dimensions, LayoutKind


FIXTURE_DIR = Path(__file__).resolve().parent.parent / "fixtures" / "domain" / "cases"


class LayoutTests(unittest.TestCase):
    def test_four_up_canvas_uses_per_column_and_row_max(self):
        layout = build_layout(
            LayoutKind.FOUR_UP,
            {
                Camera.FRONT: Dimensions(1920, 1080),
                Camera.BACK: Dimensions(1280, 720),
                Camera.LEFT_REPEATER: Dimensions(1280, 960),
                Camera.RIGHT_REPEATER: Dimensions(1280, 960),
            },
        )
        self.assertEqual(layout.canvas_width, 3200)
        self.assertEqual(layout.canvas_height, 2040)
        self.assertEqual(layout.cell_by_camera[Camera.FRONT].width, 1920)
        self.assertEqual(layout.cell_by_camera[Camera.BACK].width, 1280)
        self.assertEqual(layout.cell_by_camera[Camera.LEFT_REPEATER].y, 1080)

    def test_fill_missing_dimensions_uses_max_known(self):
        complete = fill_missing_dimensions(
            LayoutKind.SIX_UP,
            {
                Camera.FRONT: Dimensions(1920, 1080),
                Camera.BACK: Dimensions(1920, 1080),
            },
        )
        self.assertEqual(complete[Camera.LEFT_PILLAR].width, 1920)
        self.assertEqual(complete[Camera.RIGHT].height, 1080)

    def test_six_up_canvas_uses_two_by_three_grid(self):
        layout = build_layout(
            LayoutKind.SIX_UP,
            {
                Camera.FRONT: Dimensions(1920, 1080),
                Camera.BACK: Dimensions(1920, 1080),
                Camera.LEFT: Dimensions(1280, 960),
                Camera.RIGHT: Dimensions(1280, 960),
                Camera.LEFT_PILLAR: Dimensions(1280, 960),
                Camera.RIGHT_PILLAR: Dimensions(1280, 960),
            },
        )
        self.assertEqual(layout.canvas_width, 5760)
        self.assertEqual(layout.canvas_height, 2160)
        self.assertEqual(layout.cell_by_camera[Camera.FRONT].x, 0)
        self.assertEqual(layout.cell_by_camera[Camera.BACK].x, 1920)
        self.assertEqual(layout.cell_by_camera[Camera.LEFT].x, 3840)
        self.assertEqual(layout.cell_by_camera[Camera.RIGHT].y, 1080)
        self.assertEqual(layout.cell_by_camera[Camera.LEFT_PILLAR].y, 1080)

    def test_shared_layout_fixtures_match_python_contract_plan(self):
        checked = 0
        for fixture_path in sorted(FIXTURE_DIR.glob("*.json")):
            case = json.loads(fixture_path.read_text(encoding="utf-8"))
            expected_layout = case.get("expected_layout")
            if expected_layout is None:
                continue
            checked += 1
            cameras = {
                Camera(entry)
                for policy in case["expected_scan"].values()
                for entry in policy["cameras"]
            }
            for profile, expected in expected_layout.items():
                with self.subTest(fixture=fixture_path.name, profile=profile):
                    layout = build_camera_layout_plan(
                        profile,
                        cameras,
                        {},
                    )
                    self.assertEqual(layout_manifest(layout), expected)
        self.assertGreaterEqual(checked, 1)


if __name__ == "__main__":
    unittest.main()
