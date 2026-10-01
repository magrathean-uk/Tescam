"""Idempotency test for ``script/regen_fixtures.py``.

The regen script's contract is "running it on existing fixtures is a
no-op": every committed `expected_*` block must reproduce exactly when
the script re-runs against the same input. If the regen output changes
shape without the matching fixture refresh, this test fails — and the
fixture parity tests (`test_domain_contract`) start drifting.

The ``regen`` test loads each fixture, computes the four expected_*
blocks via the regen helpers, and diffs against the committed values.
This is cheaper than running the standalone script and round-tripping
through disk: same coverage, no temp file churn.
"""
from __future__ import annotations

import importlib.util
import json
import unittest
from copy import deepcopy
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURE_DIR = REPO_ROOT / "fixtures" / "domain" / "cases"
REGEN_PATH = REPO_ROOT / "script" / "regen_fixtures.py"


def _load_regen_module():
    """Load ``script/regen_fixtures.py`` as a module despite the
    ``script/`` directory not being a Python package.
    """
    spec = importlib.util.spec_from_file_location("tescam_regen_fixtures", REGEN_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not spec {REGEN_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RegenFixturesIdempotencyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.regen = _load_regen_module()

    def test_every_fixture_reproduces_its_committed_blocks(self):
        cases = sorted(FIXTURE_DIR.glob("*.json"))
        self.assertGreaterEqual(len(cases), 4)
        regen = self.regen

        for fixture_path in cases:
            with self.subTest(fixture=fixture_path.name):
                committed = json.loads(fixture_path.read_text(encoding="utf-8"))
                # The regen helpers mutate the input in place; copy so
                # we leave the committed shape untouched between subtests.
                input_case = deepcopy(committed)
                regenerated = regen.regenerate(input_case)

                # Each expected_* block must match what's currently
                # committed. If you intentionally changed contract
                # behaviour, run script/regen_fixtures.py and commit
                # the regenerated fixtures BEFORE this test sees them.
                for key in ("expected_scan", "expected_layout", "expected_selection", "expected_output"):
                    actual = regenerated.get(key)
                    expected = committed.get(key)
                    self.assertEqual(
                        actual,
                        expected,
                        f"{fixture_path.name}: {key} drifted from regen output. "
                        f"Run `python3 script/regen_fixtures.py` and commit.",
                    )

    def test_regen_regenerate_is_a_no_op_on_already_regenerated_input(self):
        # Calling regen twice in a row must produce identical output;
        # the second call sees fully-populated expected_* blocks but
        # rebuilds them from the source-of-truth helpers, so the
        # outcome must be byte-identical to the first call.
        regen = self.regen
        for fixture_path in sorted(FIXTURE_DIR.glob("*.json")):
            with self.subTest(fixture=fixture_path.name):
                case_a = json.loads(fixture_path.read_text(encoding="utf-8"))
                first = regen.regenerate(deepcopy(case_a))
                second = regen.regenerate(deepcopy(first))
                self.assertEqual(
                    json.dumps(first, sort_keys=True),
                    json.dumps(second, sort_keys=True),
                    f"{fixture_path.name}: regen.regenerate is not idempotent",
                )


if __name__ == "__main__":
    unittest.main()
