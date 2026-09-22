# Runbook

Current App Store train: `1.0` (`6`). Release copy and ASC commands live in `docs/releases/current-asc-platform-version.md`; the compact train marker is `docs/releases/v1.0-app-store.md`.

## Setup

Use Python 3.9+ for the CLI. The package has no runtime Python
dependencies in `pyproject.toml`.

```bash
python3 -m pip install -e .
```

For render and integration coverage, keep `ffmpeg` and `ffprobe` on `PATH`.
For HEVC CLI export, the local ffmpeg build needs `libx265` support.

Native app builds use Xcode. `script/test_native.sh` and
`script/build_and_run.sh` resolve `TESLACAM_BUILD_ENV` first, then fall back
to `/Users/bolyki/dev/source/build-env.sh`. If neither exists, the scripts stop
before invoking `xcodebuild`; treat that as a setup blocker.

## CLI

Primary command from the repo root:

```bash
./teslacam-cli
```

Compatibility adapters to the same Python module:

```bash
python3 teslacam.py
./teslacam.sh
```

Optional install:

```bash
pip install .
teslacam-cli
```

Useful Python lanes:

```bash
python3 -m unittest tests.test_scanner tests.test_layouts tests.test_timing tests.test_cli tests.test_domain_contract
python3 -m unittest discover tests
python3 -m unittest tests.test_integration
```

Domain dry-run comparison:

```bash
teslacam-cli /absolute/path/to/TeslaCam --dry-run-json manifest.json
```

The CLI default mode is `evidence-hevc`, the portable ffmpeg equivalent of the
app's Evidence HEVC export intent. Native Original passthrough muxing and
telemetry engraving stay in the app path.

The integration test expects working `ffmpeg` fixtures.

## Lint, format, and typecheck

No dedicated lint, formatter, or Python typecheck config is present in this
repo. Do not add or run a guessed tool as if it were canonical.

Available hygiene checks:

```bash
git diff --check
python3 -m unittest discover tests
script/test_native.sh
```

Use the native lane as the Swift compile/typecheck check. Use Python
`unittest` as the Python regression gate.

## Native macOS app

Use `script/test_native.sh` for the native lane. It resolves `TESLACAM_BUILD_ENV` first and falls back to `/Users/bolyki/dev/source/build-env.sh`, then runs build-for-testing plus the app and UI test targets.

```bash
script/test_native.sh
```

Use `script/build_and_run.sh` to build and launch the app locally. The Codex
environment file `.codex/environments/environment.toml` points its Run action
at this script.

Known Xcode schemes:

- `TeslaCam`
- `TeslaCam iPad`

CI runs `TeslaCamTests` only; UI tests are local via `script/test_native.sh`.

## CI

- `.github/workflows/python-tests.yml` installs ffmpeg, installs the package
  editable, and runs `python -m unittest discover tests` on Python 3.10 and 3.12.
- `.github/workflows/native-tests.yml` builds `TeslaCam` on `macos-26`, disables
  code signing, and runs `TeslaCamTests` with `test-without-building`.

## Architecture checks

- Keep domain changes covered by shared fixtures and `docs/domain-contract.md`.
- Keep CLI planning pure; rendering and human output stay behind adapters.
- Keep native export behind validated plan plus preflight.
- Keep camera layout changes reflected in scan manifests, preview, native export, and CLI dry-run output.
- Keep derived build folders ignored and out of git.

## Debug flow

- `TESLACAM_DEBUG_SOURCE=/absolute/path/to/TeslaCam` injects a source in Debug builds.
- `TESLACAM_UI_TEST_MODE=blank` gives empty onboarding.
- `TESLACAM_UI_TEST_MODE=sample` gives a sample timeline.
- Use the in-app `Show Log` action after failed or cancelled exports.
- When gap or layout logic changes, verify true-time spacing, visible gap preview, duplicate handling, and HW4 camera detection.

## Release checks

- Confirm `MARKETING_VERSION = 1.0` and `CURRENT_PROJECT_VERSION = 6` from the Xcode project before archive/upload work.
- Cold launch starts on onboarding until a source folder is chosen.
- The loaded timeline shows exact range, export preset, duplicate policy, and per-camera controls.
- Existing-output exports choose a unique filename instead of clobbering.
- HW4 names `left`, `right`, `left_pillar`, and `right_pillar` map to the centered 3x3 layout.
- Native export stays the only shipping mac app path.
- Debug builds show recent debug events for fast triage.
- Keep macOS and iOS/iPadOS bundle identifiers, screenshots, and ASC platform operations separate as documented under `docs/releases/`.

## Done criteria for Codex tasks

- Current worktree state was checked and unrelated dirty changes were preserved.
- Commands and conventions used were derived from this repo, CI, scripts, or project files.
- Docs stay aligned across app and CLI when shared behavior changes.
- Domain behavior changes update `docs/domain-contract.md`, fixtures, Python tests, and Swift parity tests.
- Relevant verification ran, or the blocker is named with the command that failed.
- Generated exports, build products, `_legacy/`, and vendor/runtime assets remain untouched unless explicitly in scope.

## Optional pre-commit hook

`script/pre-commit.example.sh` is a ready-to-use hook that runs the fast
per-commit gates: full Python unittest suite, whitespace check on the
staged diff, and a cache-leak tripwire that flags any `TeslaCam-*`
folder appearing in user-level `~/Library/Developer/Xcode/DerivedData`
newer than the repo's `.cache/` (catches an `xcodebuild` invocation
that bypassed `-derivedDataPath`).

Install opt-in:

```bash
cp script/pre-commit.example.sh .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

Skip a single commit with `git commit --no-verify`. Native xcodebuild
tests are deliberately not run by the hook — those go through
`script/test_native.sh` before push.

## Guardrails

- `TeslaCam/Resources/LICENSES.md` and `TeslaCam/Resources/ffmpeg_bin/` are support assets, not dev notes.
- The CLI stays dependency-light and cross-platform.
- `./teslacam-cli` is the active CLI entrypoint; `teslacam.py` and `teslacam.sh` are adapters.
- `teslacam_legacy_macos.sh` is legacy reference only, not the native app export path.
- Keep app and CLI output behavior aligned for duplicate handling, time trimming, and layout selection.
