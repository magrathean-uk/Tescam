from datetime import datetime, timedelta
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from tescam_cli.cli import dataset_range
from tescam_cli.composer import select_clip_sets
from tescam_cli.models import Camera, ClipSet


class DurationProbe:
    def __init__(self, durations):
        self.durations = durations

    def duration(self, _ffprobe, path):
        return self.durations[path]


class TimingTests(unittest.TestCase):
    def test_dataset_range_uses_longest_camera_in_last_set(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            front = root / "front.mp4"
            right = root / "right.mp4"
            front.write_bytes(b"x")
            right.write_bytes(b"x")

            first = ClipSet(
                timestamp="2026-01-01_00-00-00",
                start_time=datetime(2026, 1, 1, 0, 0, 0),
                files={Camera.FRONT: front},
            )
            last = ClipSet(
                timestamp="2026-01-01_00-01-00",
                start_time=datetime(2026, 1, 1, 0, 1, 0),
                files={Camera.FRONT: front, Camera.RIGHT: right},
            )

            durations = {front: 30.0, right: 75.0}
            start_time, end_time = dataset_range([first, last], Path("/fake/ffprobe"), DurationProbe(durations))

        self.assertEqual(start_time, first.start_time)
        self.assertEqual(end_time, last.start_time + timedelta(seconds=75))

    def test_select_clip_sets_uses_longest_camera_duration(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            front = root / "front.mp4"
            right = root / "right.mp4"
            front.write_bytes(b"x")
            right.write_bytes(b"x")

            clip_set = ClipSet(
                timestamp="2026-01-01_00-00-00",
                start_time=datetime(2026, 1, 1, 0, 0, 0),
                files={Camera.FRONT: front, Camera.RIGHT: right},
            )
            durations = {front: 30.0, right: 60.0}

            selected = select_clip_sets(
                [clip_set],
                start_time=datetime(2026, 1, 1, 0, 0, 10),
                end_time=datetime(2026, 1, 1, 0, 0, 55),
                ffprobe=Path("/fake/ffprobe"),
                media_probe=DurationProbe(durations),
            )

        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0].duration, 60.0)
        self.assertEqual(selected[0].trim_start, 10.0)
        self.assertEqual(selected[0].trim_end, 55.0)


if __name__ == "__main__":
    unittest.main()
