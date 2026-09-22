#!/usr/bin/env bash
#
# Optional pre-commit hook for Tescam.
#
# Runs the fast checks every commit should clear:
#   - the full Python unittest suite
#   - whitespace damage check on the staged diff
#   - cache-isolation tripwire (no DerivedData / system venv leak)
#
# Install (opt-in, never auto-installed):
#
#   cp script/pre-commit.example.sh .git/hooks/pre-commit
#   chmod +x .git/hooks/pre-commit
#
# Skip on a one-off basis with `git commit --no-verify`.
#
# Native macOS tests (xcodebuild + TeslaCamTests) are deliberately NOT
# run by this hook — they take too long for a per-commit gate. Run them
# locally with `script/test_native.sh` before pushing.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Source the loop's cache-isolation env if it exists. Hook is non-fatal
# when the env is missing — it just falls back to whatever python3 is on
# PATH. The checks below are safe either way.
if [[ -f "$REPO_ROOT/.cache/build-env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.cache/build-env.sh"
fi
if [[ -f "$REPO_ROOT/.cache/venv/bin/activate" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.cache/venv/bin/activate"
fi

echo "[pre-commit] Python unittest suite..."
PYTHON_BIN="$(command -v python3 || command -v python || true)"
if [[ -z "$PYTHON_BIN" ]]; then
  echo "[pre-commit] python3 not on PATH; skipping unittest run."
else
  if ! "$PYTHON_BIN" -m unittest discover tests > /tmp/teslacam-pre-commit.log 2>&1; then
    echo "[pre-commit] FAIL — Python tests failed. Tail of /tmp/teslacam-pre-commit.log:" >&2
    tail -20 /tmp/teslacam-pre-commit.log >&2
    exit 1
  fi
  tail -3 /tmp/teslacam-pre-commit.log
fi

echo "[pre-commit] git diff --check (whitespace)..."
if ! git diff --cached --check; then
  echo "[pre-commit] FAIL — whitespace damage in the staged diff." >&2
  exit 1
fi

# Cache-leak tripwire: any TeslaCam-* derived-data folder newer than the
# repo's .cache root means an xcodebuild call escaped -derivedDataPath.
if [[ -d "$REPO_ROOT/.cache" ]]; then
  if find "$HOME/Library/Developer/Xcode/DerivedData" \
       -maxdepth 2 -name 'TeslaCam-*' \
       -newer "$REPO_ROOT/.cache" \
       -print -quit 2>/dev/null | grep -q .; then
    echo "[pre-commit] FAIL — cache leak: TeslaCam-* in user DerivedData newer than .cache/." >&2
    echo "             An xcodebuild invocation bypassed -derivedDataPath." >&2
    exit 1
  fi
fi

echo "[pre-commit] OK"
