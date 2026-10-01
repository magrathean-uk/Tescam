from pathlib import Path
from tempfile import TemporaryDirectory
import sys
import unittest

from tescam_cli.concat_safety import UnsafeConcatPath, ffconcat_path, validate_ffconcat_path
from tescam_cli.process_tools import LimitedProcessTimeout, run_limited_process
from tescam_cli.safe_output import atomic_output_target


class ProcessAndOutputSafetyTests(unittest.TestCase):
    def test_limited_process_times_out(self):
        with self.assertRaises(LimitedProcessTimeout):
            run_limited_process(
                [sys.executable, "-c", "import time; time.sleep(3)"],
                timeout_seconds=0.25,
            )

    def test_limited_process_truncates_stdout_in_memory(self):
        result = run_limited_process(
            [sys.executable, "-c", "import sys; sys.stdout.write('x' * 200000)"],
            timeout_seconds=2,
            stdout_limit_bytes=1024,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(result.stdout), 1024)
        self.assertTrue(result.stdout_truncated)

    def test_atomic_output_target_does_not_clobber_existing_final_on_failure(self):
        with TemporaryDirectory() as temp_dir:
            final = Path(temp_dir) / "out.mp4"
            final.write_bytes(b"original")
            with self.assertRaises(RuntimeError):
                with atomic_output_target(final) as temp:
                    temp.write_bytes(b"partial")
                    raise RuntimeError("render failed")
            self.assertEqual(final.read_bytes(), b"original")
            self.assertEqual([p.name for p in Path(temp_dir).iterdir()], ["out.mp4"])

    def test_atomic_output_target_replaces_on_success(self):
        with TemporaryDirectory() as temp_dir:
            final = Path(temp_dir) / "out.mp4"
            final.write_bytes(b"old")
            with atomic_output_target(final) as temp:
                temp.write_bytes(b"new")
            self.assertEqual(final.read_bytes(), b"new")

    def test_ffconcat_path_escapes_quotes_and_rejects_newlines(self):
        with TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "clip with 'quote'.mp4"
            path.write_bytes(b"x")
            escaped = ffconcat_path(path)
            # A literal single quote must be emitted as the 4-char ffmpeg
            # sequence '\'' (close, escaped-quote, reopen) — NOT the
            # doubled-backslash form '\\'' which ffmpeg mis-parses.
            self.assertIn("'\\''", escaped)
            self.assertNotIn("'\\\\''", escaped)
            # Round-trip: wrap in single quotes as the concat writer does and
            # decode the escape; it must reproduce the original resolved path.
            wrapped = f"'{escaped}'"
            decoded = wrapped[1:-1].replace("'\\''", "'")
            self.assertEqual(decoded, str(path.resolve()))
            bad = Path(temp_dir) / "bad\nname.mp4"
            with self.assertRaises(UnsafeConcatPath):
                validate_ffconcat_path(bad)


if __name__ == "__main__":
    unittest.main()
