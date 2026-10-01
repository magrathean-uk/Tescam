from __future__ import annotations

import json
import unittest
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory

from tescam_cli.cli import resolve_event_window
from tescam_cli.events import scan_events
from tescam_cli.ffmpeg_tools import ToolResolutionError, choose_encoder


def _write_event(folder: Path, payload: dict) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "event.json").write_text(json.dumps(payload), encoding="utf-8")


class ScanEventsTests(unittest.TestCase):
    def test_scans_sentry_and_saved_sorted_by_time(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            _write_event(
                root / "SentryClips" / "2026-04-18_14-09-29",
                {
                    "timestamp": "2026-04-18T14:08:30",
                    "city": "Covent Garden",
                    "street": "Whitcomb Street",
                    "est_lat": "51.5101",
                    "est_lon": "-0.131181",
                    "reason": "sentry_aware_object_detection",
                    "camera": "0",
                },
            )
            _write_event(
                root / "SavedClips" / "2026-04-14_10-00-00",
                {"timestamp": "2026-04-14T10:00:05", "reason": "user_interaction_honk"},
            )
            # RecentClips has no event.json and must be ignored.
            (root / "RecentClips").mkdir()

            events = scan_events(root)
            self.assertEqual(len(events), 2)
            # Sorted by timestamp: the April 14 Saved event precedes April 18.
            self.assertEqual(events[0].category, "SavedClips")
            self.assertEqual(events[1].category, "SentryClips")
            sentry = events[1]
            self.assertEqual(sentry.timestamp, datetime(2026, 4, 18, 14, 8, 30))
            self.assertEqual(sentry.reason, "sentry_aware_object_detection")
            self.assertAlmostEqual(sentry.latitude, 51.5101)
            self.assertIn("Covent Garden", sentry.location)

    def test_ignores_missing_and_malformed_event_json(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "SentryClips" / "no_json").mkdir(parents=True)
            bad = root / "SentryClips" / "bad_json"
            bad.mkdir(parents=True)
            (bad / "event.json").write_text("{not valid", encoding="utf-8")
            self.assertEqual(scan_events(root), [])

    def test_resolve_event_window_centres_on_trigger(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            _write_event(
                root / "SentryClips" / "2026-04-18_14-09-29",
                {"timestamp": "2026-04-18T14:08:30", "reason": "x"},
            )
            events = scan_events(root)
            start, end = resolve_event_window(events, 1, pre_seconds=30.0, post_seconds=20.0)
            self.assertEqual(start, datetime(2026, 4, 18, 14, 8, 0))
            self.assertEqual(end, datetime(2026, 4, 18, 14, 8, 50))

    def test_resolve_event_window_rejects_out_of_range(self):
        with TemporaryDirectory() as temp_dir:
            _write_event(
                Path(temp_dir) / "SentryClips" / "e",
                {"timestamp": "2026-04-18T14:08:30"},
            )
            events = scan_events(Path(temp_dir))
            with self.assertRaises(RuntimeError):
                resolve_event_window(events, 5, 30.0, 30.0)


class DeliveryPresetTests(unittest.TestCase):
    """``choose_encoder`` for the review/share delivery modes.

    Patches the encoders-text probe so the test never shells out to ffmpeg.
    """

    def _choose(self, mode: str, encoders_text: str):
        import tescam_cli.ffmpeg_tools as ft

        original = ft._encoders_text
        ft._encoders_text = lambda *_a, **_k: encoders_text
        try:
            return choose_encoder(Path("/usr/bin/ffmpeg"), mode, "medium")
        finally:
            ft._encoders_text = original

    def test_review_prefers_videotoolbox_when_available(self):
        plan = self._choose("review", "hevc_videotoolbox\nlibx265\n")
        self.assertEqual(plan.label, "hevc_review")
        self.assertIn("hevc_videotoolbox", plan.args)
        self.assertNotIn("libx265", plan.args)

    def test_review_uses_videotoolbox_without_x265(self):
        plan = self._choose("review", "hevc_videotoolbox\n")
        self.assertEqual(plan.label, "hevc_review")
        self.assertIn("hevc_videotoolbox", plan.args)

    def test_evidence_hevc_matches_app_style_quality_mode(self):
        plan = self._choose("evidence-hevc", "libx265\n")
        self.assertEqual(plan.label, "hevc_evidence")
        self.assertIn("libx265", plan.args)
        self.assertIn("6", plan.args)

    def test_share_falls_back_to_x265_crf_without_videotoolbox(self):
        plan = self._choose("share", "libx265\n")
        self.assertEqual(plan.label, "hevc_share")
        self.assertIn("libx265", plan.args)
        self.assertIn("28", plan.args)  # CRF for share

    def test_delivery_mode_errors_without_any_hevc_encoder(self):
        with self.assertRaises(ToolResolutionError):
            self._choose("review", "libx264\nmjpeg\n")


if __name__ == "__main__":
    unittest.main()
