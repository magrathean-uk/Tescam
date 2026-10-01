from pathlib import Path
from tempfile import TemporaryDirectory
import os
import unittest

from tescam_cli.models import Camera, DuplicatePolicy
from tescam_cli.scanner import normalize_camera, scan_source


class ScannerSecurityTests(unittest.TestCase):
    def test_scan_ignores_symlinked_directories_and_media_files(self):
        if not hasattr(os, "symlink"):
            self.skipTest("symlink unsupported")
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "root"
            external = Path(temp_dir) / "external"
            root.mkdir()
            external.mkdir()
            (root / "2026-01-01_00-00-00-front.mp4").write_bytes(b"front")
            (external / "2026-01-01_00-00-00-rear.mp4").write_bytes(b"rear")
            os.symlink(external, root / "linked_dir", target_is_directory=True)
            os.symlink(external / "2026-01-01_00-00-00-rear.mp4", root / "2026-01-01_00-00-00-rear.mp4")

            result = scan_source(root)

        self.assertEqual(len(result.clip_sets), 1)
        self.assertIn(Camera.FRONT, result.clip_sets[0].files)
        self.assertNotIn(Camera.BACK, result.clip_sets[0].files)

    def test_scan_ignores_special_files_when_present(self):
        if not hasattr(os, "mkfifo"):
            self.skipTest("mkfifo unsupported")
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fifo = root / "2026-01-01_00-00-00-front.mp4"
            os.mkfifo(fifo)
            (root / "2026-01-01_00-00-00-rear.mp4").write_bytes(b"rear")

            result = scan_source(root)

        self.assertEqual(len(result.clip_sets), 1)
        self.assertNotIn(Camera.FRONT, result.clip_sets[0].files)
        self.assertIn(Camera.BACK, result.clip_sets[0].files)

    def test_scan_keeps_duplicate_policy_semantics(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            a = root / "a"
            b = root / "b"
            a.mkdir()
            b.mkdir()
            older = a / "2026-01-01_00-00-00-front.mp4"
            newer = b / "2026-01-01_00-00-00-front.mp4"
            older.write_bytes(b"older")
            newer.write_bytes(b"newer")
            os.utime(older, (1_700_000_000, 1_700_000_000))
            os.utime(newer, (1_700_000_100, 1_700_000_100))

            result = scan_source(root, DuplicatePolicy.PREFER_NEWEST)

        self.assertEqual(result.duplicate_file_count, 1)
        self.assertEqual(result.duplicate_timestamp_count, 1)
        self.assertEqual(result.clip_sets[0].files[Camera.FRONT].resolve(), newer.resolve())

    def test_scan_ignores_hidden_path_components_and_suspicious_names(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            hidden = root / ".hidden"
            hidden.mkdir()
            (hidden / "2026-01-01_00-00-00-front.mp4").write_bytes(b"hidden")
            (root / "2026-01-01_00-00-00-rear.mp4").write_bytes(b"rear")
            (root / "-bad.mp4").write_bytes(b"bad")
            (root / "2026-01-01_00-00-00-unknown_camera.mp4").write_bytes(b"bad")

            result = scan_source(root)

        self.assertEqual(len(result.clip_sets), 1)
        self.assertNotIn(Camera.FRONT, result.clip_sets[0].files)
        self.assertIn(Camera.BACK, result.clip_sets[0].files)

    def test_normalize_camera_keeps_contract_aliases(self):
        self.assertEqual(normalize_camera("front"), Camera.FRONT)
        self.assertEqual(normalize_camera("rear"), Camera.BACK)
        self.assertEqual(normalize_camera("left-repeater"), Camera.LEFT_REPEATER)
        self.assertEqual(normalize_camera("right_rear"), Camera.RIGHT_REPEATER)
        self.assertEqual(normalize_camera("left_pillar_2"), Camera.LEFT_PILLAR)
        self.assertIsNone(normalize_camera("unknown_camera"))


if __name__ == "__main__":
    unittest.main()
