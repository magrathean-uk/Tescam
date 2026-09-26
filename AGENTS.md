# Tescam agent guide

Tescam contains a SwiftUI app for macOS, iPhone, and iPad, plus a dependency-light Python CLI. Read `README.md` for the product overview and `RUNBOOK.md` for build and release procedures.

## Structure

- `TeslaCam/` contains the shared native engine, platform UI, export path, playback, and resources.
- `TeslaCamTests/` and `TeslaCamUITests/` cover native behavior.
- `teslacam_cli/` and `tests/` contain the Python CLI and its tests.
- `fixtures/domain/cases/` and `docs/domain-contract.md` define behavior shared by Swift and Python.
- `_legacy/` and `teslacam_legacy_macos.sh` are reference-only.

## Working rules

- Keep native app and CLI documentation aligned.
- For a shared-domain change, update the contract, fixtures, Swift behavior and tests, and Python behavior and tests together.
- Keep CLI planning pure. Put rendering and human-facing output behind adapters.
- Native export is the shipping app path. Do not treat the CLI as the app export implementation.
- A mobile-only UI change uses the existing `AppState` API and does not edit the shared core. Register a new Swift source file in both `TeslaCam` and `TeslaCam iPad` targets in `TeslaCam.xcodeproj/project.pbxproj`.
- Preserve the manual codec picker and the opt-in telemetry engraving control.
- Do not add Sentry, analytics, or external crash telemetry. Keep diagnostics local.
- Do not edit vendor or runtime assets, generated output, or `TeslaCam/Resources/LICENSES.md` unless the task covers them.
- Keep release and App Store facts in `docs/releases/`.
- Preserve unrelated working-tree changes. Do not use `--break-system-packages`.
- Complete authorized work through relevant checks, including safe local edits, tests, dependency setup and Git operations needed for the task. Make routine decisions and use existing authorization without repeated permission requests.
- Preserve owner holds and the documented authority for signing, release, publishing and live-service changes. Ask only when an action needs authority beyond the current request or materially changes its scope.
- Delegate independent, bounded work when the benefit exceeds the overhead. Give workers distinct ownership and acceptance checks, choose a model and reasoning level suited to the task, and review their results.
- Keep durable guidance in maintained documentation. Do not create duplicate instruction files or disposable plans, transcripts, status reports, or screenshots in the source tree.

## Commands

```sh
python3 -m pip install -e .
./teslacam-cli
python3 teslacam.py
./teslacam.sh
python3 -m unittest tests.test_domain_contract
python3 -m unittest discover tests
script/test_native.sh
script/build_and_run.sh
python3 script/regen_fixtures.py
git diff --check
```

Native commands require `TESLACAM_BUILD_ENV` or the project-supported local build environment. If neither is available, report the setup blocker instead of improvising an `xcodebuild` invocation. There is no dedicated lint, formatter, or Python type-check configuration. Use the focused check for the changed boundary, then broaden verification when the change warrants it.

Consider [Clean Development](https://github.com/magrathean-uk/clean-development) for keeping supported build and cache output managed.
