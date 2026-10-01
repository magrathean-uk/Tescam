import sys
import unittest

from tescam_cli.ffmpeg_tools import (
    FFMPEG_ERROR_STDERR_TAIL_LINES,
    FfmpegRuntimeError,
    extract_filter_complex,
    format_ffmpeg_failure,
    run_command,
)


class ExtractFilterComplexTests(unittest.TestCase):
    def test_returns_value_when_present(self):
        args = ["ffmpeg", "-i", "a.mp4", "-filter_complex", "[0:v]scale=w:h[v]", "-y", "out.mp4"]
        self.assertEqual(extract_filter_complex(args), "[0:v]scale=w:h[v]")

    def test_returns_none_when_absent(self):
        self.assertIsNone(extract_filter_complex(["ffmpeg", "-i", "a.mp4", "-y", "out.mp4"]))

    def test_returns_first_when_repeated(self):
        # Real ffmpeg invocations only ever pass one filter graph, but the
        # contract should still be deterministic if a caller fat-fingers it.
        args = ["ffmpeg", "-filter_complex", "first", "-filter_complex", "second"]
        self.assertEqual(extract_filter_complex(args), "first")

    def test_returns_none_when_no_value_after_flag(self):
        # Trailing -filter_complex with no value is malformed but must not crash.
        self.assertIsNone(extract_filter_complex(["ffmpeg", "-filter_complex"]))


class FormatFfmpegFailureTests(unittest.TestCase):
    def test_short_stderr_no_filter_graph_renders_full_tail(self):
        payload = format_ffmpeg_failure(
            returncode=1,
            args=["ffmpeg", "-i", "in.mp4", "-y", "out.mp4"],
            stderr="line1\nline2\nline3",
            stderr_truncated_by_byte_limit=False,
        )
        self.assertIsNone(payload["filter_graph"])
        self.assertEqual(payload["kept_lines"], 3)
        self.assertEqual(payload["total_lines"], 3)
        self.assertIn("ffmpeg/ffprobe exited with code 1", payload["message"])
        self.assertIn("stderr:", payload["message"])
        self.assertIn("  line1", payload["message"])
        self.assertIn("  line3", payload["message"])
        self.assertNotIn("Filter graph:", payload["message"])
        self.assertNotIn("last", payload["message"])

    def test_long_stderr_truncates_to_last_n_lines_with_count_hint(self):
        big_stderr = "\n".join(f"line{i}" for i in range(120))
        payload = format_ffmpeg_failure(
            returncode=2,
            args=["ffmpeg", "-i", "in.mp4"],
            stderr=big_stderr,
            stderr_truncated_by_byte_limit=False,
        )
        self.assertEqual(payload["kept_lines"], FFMPEG_ERROR_STDERR_TAIL_LINES)
        self.assertEqual(payload["total_lines"], 120)
        self.assertIn(f"last {FFMPEG_ERROR_STDERR_TAIL_LINES} of 120 lines", payload["message"])
        # The first 80 lines must be gone from the surfaced text.
        self.assertNotIn("line0\n", payload["message"])
        self.assertNotIn("line79\n", payload["message"])
        # The last line must be present.
        self.assertIn("line119", payload["message"])

    def test_filter_graph_is_extracted_and_collapsed_in_args(self):
        payload = format_ffmpeg_failure(
            returncode=1,
            args=[
                "ffmpeg",
                "-i", "front.mp4",
                "-i", "back.mp4",
                "-filter_complex",
                "[0:v]scale=1280:960[v0];[1:v]scale=1280:960[v1];[v0][v1]xstack=inputs=2:layout=0_0|0_960[vout]",
                "-map", "[vout]",
                "-y", "out.mp4",
            ],
            stderr="Conversion failed!\nError opening filter\n",
            stderr_truncated_by_byte_limit=False,
        )
        self.assertEqual(
            payload["filter_graph"],
            "[0:v]scale=1280:960[v0];[1:v]scale=1280:960[v1];[v0][v1]xstack=inputs=2:layout=0_0|0_960[vout]",
        )
        self.assertIn("Filter graph:", payload["message"])
        self.assertIn("xstack=inputs=2", payload["message"])
        # The args line collapses the filter graph to a placeholder so the
        # graph is shown once, in its dedicated section.
        self.assertIn("<see filter graph below>", payload["message"])
        self.assertIn("Conversion failed!", payload["message"])

    def test_byte_limit_only_no_decoded_lines(self):
        # Edge case: the byte limit stripped the buffer down to nothing decodable.
        payload = format_ffmpeg_failure(
            returncode=1,
            args=["ffmpeg"],
            stderr="",
            stderr_truncated_by_byte_limit=True,
        )
        self.assertIn("captured but exceeded byte limit", payload["message"])
        self.assertEqual(payload["total_lines"], 0)

    def test_byte_limit_combined_with_line_truncation_mentions_both(self):
        big_stderr = "\n".join(f"line{i}" for i in range(80))
        payload = format_ffmpeg_failure(
            returncode=1,
            args=["ffmpeg"],
            stderr=big_stderr,
            stderr_truncated_by_byte_limit=True,
        )
        self.assertIn(
            f"last {FFMPEG_ERROR_STDERR_TAIL_LINES} of 80 lines",
            payload["message"],
        )
        self.assertIn("exceeded byte limit", payload["message"])


class RunCommandFailureSurfacesAttributesTests(unittest.TestCase):
    def test_failed_subprocess_attaches_structured_payload(self):
        # Drive a real subprocess via run_command so the integration with
        # process_tools is exercised. Use the host python with a tiny
        # script that emits a multi-line stderr and exits non-zero.
        script = (
            "import sys; "
            "sys.stderr.write('header\\n'); "
            "sys.stderr.write('\\n'.join(f'line{i}' for i in range(60))); "
            "sys.stderr.write('\\nfinal\\n'); "
            "sys.exit(7)"
        )
        with self.assertRaises(FfmpegRuntimeError) as ctx:
            run_command([sys.executable, "-c", script])
        exc = ctx.exception
        self.assertEqual(exc.exit_code, 7)
        self.assertIsNotNone(exc.command_args)
        self.assertIsNone(exc.filter_graph)
        self.assertIsNotNone(exc.stderr_full)
        self.assertIn("final", exc.stderr_full)
        # The summary surfaces the tail and the count hint.
        self.assertIn("ffmpeg/ffprobe exited with code 7", str(exc))
        # 1 (header) + 60 (line0..line59) + 1 (final) = 62 lines, > 40.
        self.assertIn(f"last {FFMPEG_ERROR_STDERR_TAIL_LINES}", str(exc))
        self.assertIn("final", str(exc))
        # The very first line should NOT be in the truncated tail.
        self.assertNotIn("header\n", exc.stderr_tail or "")


if __name__ == "__main__":
    unittest.main()
