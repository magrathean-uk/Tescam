from pathlib import Path
from tempfile import TemporaryDirectory
import os
import unittest

from tescam_cli.probe_cache import RunProbeCache


class ProbeCacheTests(unittest.TestCase):
    def test_reuses_value_for_unchanged_file_and_operation(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            media = root / "clip.mp4"
            ffprobe = root / "ffprobe"
            media.write_bytes(b"a")
            ffprobe.write_bytes(b"x")
            calls = 0
            cache = RunProbeCache()

            def compute():
                nonlocal calls
                calls += 1
                return 12.5

            self.assertEqual(cache.get_or_compute(ffprobe, media, "duration", compute), 12.5)
            self.assertEqual(cache.get_or_compute(ffprobe, media, "duration", compute), 12.5)
            self.assertEqual(calls, 1)
            self.assertEqual(cache.size, 1)

    def test_invalidates_when_media_file_changes(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            media = root / "clip.mp4"
            ffprobe = root / "ffprobe"
            media.write_bytes(b"a")
            ffprobe.write_bytes(b"x")
            calls = 0
            cache = RunProbeCache()

            def compute():
                nonlocal calls
                calls += 1
                return calls

            self.assertEqual(cache.get_or_compute(ffprobe, media, "duration", compute), 1)
            media.write_bytes(b"changed")
            os.utime(media, None)
            self.assertEqual(cache.get_or_compute(ffprobe, media, "duration", compute), 2)
            self.assertEqual(calls, 2)

    def test_keeps_operations_separate(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            media = root / "clip.mp4"
            ffprobe = root / "ffprobe"
            media.write_bytes(b"a")
            ffprobe.write_bytes(b"x")
            calls = 0
            cache = RunProbeCache()

            def compute():
                nonlocal calls
                calls += 1
                return calls

            self.assertEqual(cache.get_or_compute(ffprobe, media, "duration", compute), 1)
            self.assertEqual(cache.get_or_compute(ffprobe, media, "dimensions", compute), 2)
            self.assertEqual(calls, 2)


if __name__ == "__main__":
    unittest.main()
