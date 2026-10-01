"""Pinned-input regression tests for the filename parser.

Every case below is a contract assertion: the file name pattern, when run
through ``_FILENAME_RE`` and ``normalize_camera``, must produce the
recorded verdict. New parser bugs surface as a test failure pointing at
the offending input. Adding a new edge case = appending a new row.

The triple ``(matched, timestamp_str, camera_value)`` captures:

- ``matched``: did ``_FILENAME_RE`` accept the filename?
- ``timestamp_str``: the raw timestamp group when matched, else ``None``
- ``camera_value``: ``Camera.<X>.value`` when ``normalize_camera`` produced
  a known camera, else ``None``

Note: ``parse_clip_timestamp`` (the strptime layer) is a separate concern
and not exercised here — these cases stop at the regex + normalizer
boundary so a "regex matches but datetime invalid" case (e.g. month=13)
is treated as ``matched=True`` with the raw timestamp string surfaced.
"""
from __future__ import annotations

import re
import unittest
from typing import Optional, Tuple

from tescam_cli.scanner import _FILENAME_RE, normalize_camera


# Each row: (input_filename, matched, timestamp_or_None, camera_value_or_None)
PINNED_CASES: list[Tuple[str, bool, Optional[str], Optional[str]]] = [
    # ─── valid HW3 ──────────────────────────────────────────────────────
    ("2026-01-01_00-00-00-front.mp4", True, "2026-01-01_00-00-00", "front"),
    ("2026-01-01_00-00-00-back.mp4", True, "2026-01-01_00-00-00", "back"),
    ("2026-01-01_00-00-00-rear.mp4", True, "2026-01-01_00-00-00", "back"),
    ("2026-01-01_00-00-00-rear_camera.mp4", True, "2026-01-01_00-00-00", "back"),
    ("2026-01-01_00-00-00-left_repeater.mp4", True, "2026-01-01_00-00-00", "left_repeater"),
    ("2026-01-01_00-00-00-right_repeater.mp4", True, "2026-01-01_00-00-00", "right_repeater"),
    ("2026-01-01_00-00-00-left_rear.mp4", True, "2026-01-01_00-00-00", "left_repeater"),
    ("2026-01-01_00-00-00-right_rear.mp4", True, "2026-01-01_00-00-00", "right_repeater"),

    # ─── valid HW4 ──────────────────────────────────────────────────────
    ("2026-01-01_00-00-00-left.mp4", True, "2026-01-01_00-00-00", "left"),
    ("2026-01-01_00-00-00-right.mp4", True, "2026-01-01_00-00-00", "right"),
    ("2026-01-01_00-00-00-left_pillar.mp4", True, "2026-01-01_00-00-00", "left_pillar"),
    ("2026-01-01_00-00-00-right_pillar.mp4", True, "2026-01-01_00-00-00", "right_pillar"),

    # ─── alias forms ───────────────────────────────────────────────────
    ("2026-01-01_00-00-00-fwd.mp4", True, "2026-01-01_00-00-00", "front"),
    ("2026-01-01_00-00-00-forward.mp4", True, "2026-01-01_00-00-00", "front"),
    ("2026-01-01_00-00-00-leftrepeater.mp4", True, "2026-01-01_00-00-00", "left_repeater"),
    ("2026-01-01_00-00-00-rightrepeater.mp4", True, "2026-01-01_00-00-00", "right_repeater"),
    # left+pillar with no underscore — the normalizer keys on "left" + "pillar"
    ("2026-01-01_00-00-00-leftpillar.mp4", True, "2026-01-01_00-00-00", "left_pillar"),
    ("2026-01-01_00-00-00-rightpillar.mp4", True, "2026-01-01_00-00-00", "right_pillar"),

    # ─── case insensitivity (regex flag) ───────────────────────────────
    ("2026-01-01_00-00-00-FRONT.mp4", True, "2026-01-01_00-00-00", "front"),
    ("2026-01-01_00-00-00-Front.mp4", True, "2026-01-01_00-00-00", "front"),
    ("2026-01-01_00-00-00-LEFT_PILLAR.mp4", True, "2026-01-01_00-00-00", "left_pillar"),

    # ─── extensions ────────────────────────────────────────────────────
    ("2026-01-01_00-00-00-front.mov", True, "2026-01-01_00-00-00", "front"),
    ("2026-01-01_00-00-00-front.MP4", True, "2026-01-01_00-00-00", "front"),
    ("2026-01-01_00-00-00-front.mkv", False, None, None),
    ("2026-01-01_00-00-00-front.txt", False, None, None),
    ("2026-01-01_00-00-00-front", False, None, None),

    # ─── trailing-digit stripping in camera token ──────────────────────
    ("2026-01-01_00-00-00-front-1.mp4", True, "2026-01-01_00-00-00", "front"),
    ("2026-01-01_00-00-00-front_2.mp4", True, "2026-01-01_00-00-00", "front"),
    ("2026-01-01_00-00-00-front12.mp4", True, "2026-01-01_00-00-00", "front"),

    # ─── hyphen / underscore variants ──────────────────────────────────
    ("2026-01-01_00-00-00-left-repeater.mp4", True, "2026-01-01_00-00-00", "left_repeater"),
    ("2026-01-01_00-00-00-left__repeater.mp4", True, "2026-01-01_00-00-00", "left_repeater"),
    ("2026-01-01_00-00-00-left--pillar.mp4", True, "2026-01-01_00-00-00", "left_pillar"),

    # ─── timestamp shape: regex accepts even nonsense components ───────
    # (parse_clip_timestamp is the layer that rejects 13/25; here the regex
    # only looks at digit-shape, so these all match.)
    ("2026-13-01_00-00-00-front.mp4", True, "2026-13-01_00-00-00", "front"),
    ("2026-01-01_25-00-00-front.mp4", True, "2026-01-01_25-00-00", "front"),
    ("9999-12-31_23-59-59-front.mp4", True, "9999-12-31_23-59-59", "front"),
    ("0001-01-01_00-00-00-front.mp4", True, "0001-01-01_00-00-00", "front"),

    # ─── malformed timestamps ──────────────────────────────────────────
    ("26-01-01_00-00-00-front.mp4", False, None, None),  # 2-digit year
    ("2026-1-01_00-00-00-front.mp4", False, None, None),  # 1-digit month
    ("2026-01-01-00-00-00-front.mp4", False, None, None),  # missing _ separator
    ("2026/01/01_00-00-00-front.mp4", False, None, None),  # wrong date sep
    ("2026-01-01_00:00:00-front.mp4", False, None, None),  # wrong time sep

    # ─── unknown camera ────────────────────────────────────────────────
    ("2026-01-01_00-00-00-roof.mp4", True, "2026-01-01_00-00-00", None),
    ("2026-01-01_00-00-00-cabin.mp4", True, "2026-01-01_00-00-00", None),
    ("2026-01-01_00-00-00-12345.mp4", True, "2026-01-01_00-00-00", None),

    # ─── empty / pathological ──────────────────────────────────────────
    ("", False, None, None),
    (".mp4", False, None, None),
    ("front.mp4", False, None, None),
    ("2026-01-01_00-00-00-.mp4", False, None, None),  # empty camera token

    # ─── unicode / non-ASCII camera ────────────────────────────────────
    # Regex camera class is [A-Za-z0-9_-] — non-ASCII is rejected outright.
    ("2026-01-01_00-00-00-frônt.mp4", False, None, None),
    ("2026-01-01_00-00-00-🎥.mp4", False, None, None),

    # ─── path traversal-ish strings (parser only sees the basename, but
    # asserting these reject defensively keeps the contract honest) ────
    ("../etc/passwd.mp4", False, None, None),
    ("..%2F2026-01-01_00-00-00-front.mp4", False, None, None),

    # ─── whitespace ────────────────────────────────────────────────────
    (" 2026-01-01_00-00-00-front.mp4", False, None, None),
    ("2026-01-01_00-00-00-front.mp4 ", False, None, None),
    ("2026-01-01_00-00-00 front.mp4", False, None, None),  # space instead of dash
]


class FilenameParserPinnedRegressionTests(unittest.TestCase):
    def test_every_pinned_case_produces_recorded_verdict(self):
        # Walk every row; subTest scopes per-input failures so a single
        # parser bug can't mask the others.
        for input_name, matched, timestamp, camera_value in PINNED_CASES:
            with self.subTest(input=input_name):
                m = _FILENAME_RE.match(input_name)
                actual_matched = m is not None
                self.assertEqual(
                    actual_matched,
                    matched,
                    f"_FILENAME_RE.match({input_name!r}) regex-match changed",
                )
                if not matched:
                    self.assertIsNone(timestamp, f"fixture row malformed for {input_name!r}")
                    self.assertIsNone(camera_value, f"fixture row malformed for {input_name!r}")
                    continue

                assert m is not None  # appease type-checker
                self.assertEqual(
                    m.group("timestamp"),
                    timestamp,
                    f"timestamp group changed for {input_name!r}",
                )
                camera = normalize_camera(m.group("camera"))
                actual_camera_value = camera.value if camera is not None else None
                self.assertEqual(
                    actual_camera_value,
                    camera_value,
                    f"normalize_camera({m.group('camera')!r}) verdict changed for {input_name!r}",
                )

    def test_pinned_case_set_has_breadth(self):
        # Tripwire — if we ever drop below ~50 pinned cases the contract
        # has lost coverage. Bump the floor when intentionally pruning.
        self.assertGreaterEqual(len(PINNED_CASES), 50)

    def test_pinned_case_inputs_are_unique(self):
        # No accidental duplicates — every row must exercise a distinct input.
        seen: dict[str, int] = {}
        for index, (input_name, *_rest) in enumerate(PINNED_CASES):
            if input_name in seen:
                self.fail(f"duplicate pinned input {input_name!r} at rows {seen[input_name]} and {index}")
            seen[input_name] = index

    def test_filename_re_compiles_with_case_insensitive_flag(self):
        # If anyone strips the IGNORECASE flag, the case-variant rows above
        # would fail; keep an explicit assertion so the failure is targeted.
        self.assertTrue(_FILENAME_RE.flags & re.IGNORECASE)


if __name__ == "__main__":
    unittest.main()
