# Tescam agent guide

Tescam contains a SwiftUI app for macOS, iPhone, and iPad, plus a dependency-light Python CLI. Read `README.md` for the product overview and `RUNBOOK.md` for build and release procedures.

## Structure

- `Tescam/` contains the shared native engine, platform UI, export path, playback, and resources.
- `TescamTests/` and `TescamUITests/` cover native behavior.
- `tescam_cli/` and `tests/` contain the Python CLI and its tests.
- `fixtures/domain/cases/` and `docs/domain-contract.md` define behavior shared by Swift and Python.
- `_legacy/` and `tescam_legacy_macos.sh` are reference-only.

## Working rules

- Keep native app and CLI documentation aligned.
- For a shared-domain change, update the contract, fixtures, Swift behavior and tests, and Python behavior and tests together.
- Keep CLI planning pure. Put rendering and human-facing output behind adapters.
- Native export is the shipping app path. Do not treat the CLI as the app export implementation.
- A mobile-only UI change uses the existing `AppState` API and does not edit the shared core. Register a new Swift source file in both `Tescam` and `Tescam iPad` targets in `Tescam.xcodeproj/project.pbxproj`.
- Preserve the manual codec picker and the opt-in telemetry engraving control.
- Do not add Sentry, analytics, or external crash telemetry. Keep diagnostics local.
- Do not edit vendor or runtime assets, generated output, or `Tescam/Resources/LICENSES.md` unless the task covers them.
- Keep release and App Store facts in `docs/development/`.
- Legal files (`LICENSE`, `NOTICE`, `docs/legal/`, contributor terms, copyright and
  attribution strings) are owner-controlled: change them only on the owner's explicit
  instruction.
- Preserve unrelated working-tree changes. Do not use `--break-system-packages`.
- Complete authorized work through relevant checks, including safe local edits, tests, dependency setup and Git operations needed for the task. Make routine decisions and use existing authorization without repeated permission requests.
- Preserve owner holds and the documented authority for signing, release, publishing and live-service changes. Ask only when an action needs authority beyond the current request or materially changes its scope.
- Delegate independent, bounded work when the benefit exceeds the overhead. Give workers distinct ownership and acceptance checks, choose a model and reasoning level suited to the task, and review their results.
- Keep durable guidance in maintained documentation. Do not create duplicate instruction files or disposable plans, transcripts, status reports, or screenshots in the source tree.

## Commands

```sh
python3 -m pip install -e .
./tescam-cli
python3 tescam.py
./tescam.sh
python3 -m unittest tests.test_domain_contract
python3 -m unittest discover tests
script/test_native.sh
script/build_and_run.sh
python3 script/regen_fixtures.py
git diff --check
```

Native commands require `TESCAM_BUILD_ENV` or the project-supported local build environment. If neither is available, report the setup blocker instead of improvising an `xcodebuild` invocation. There is no dedicated lint, formatter, or Python type-check configuration. Use the focused check for the changed boundary, then broaden verification when the change warrants it.

## Models

Claude Code (Fable, or Opus 5.5, for cross-cutting work and review; Sonnet 5.5 for routine implementation; Haiku 5.5 for exploration) or Codex `gpt-6.1-sol` (`gpt-6-luna` for swarm exploration). Keep changes small; distinguish local checks from device and live-service evidence.

<!-- clean-development-policy:v4 (clean-development 0.6.0; canonical: bolyki-dev/clean-development/docs/policy-snippet.md) -->
## Clean development (mandatory)

- Storage is routed for you: every zsh loads `~/dev/machine/env.zsh`; hooks pin the mode per session (`$CLEAN_DEV_MODE` is `external` when the 4TB is attached, else `internal`). Do not wrap commands, override or unset the routed variables.
- Temp files go to `$TMPDIR` (session scratch, deleted at session end), throwaway build output to `$CLEAN_DEV_BUILDS`, caches wherever their variables point. Never write caches, builds or temp files into `~`, `~/dev` or this repo outside its git-ignored build directories.
- Internal mode: before any download or build likely over 5 GB, stop and ask G (suggest waiting for the 4TB).
- This repo's `.clean-development.json` (schema v2) lists its git-ignored `buildDirs`/`depDirs`; keep it accurate when the build layout changes.
- No dot-folders in `~` or `~/dev`. `.env` files stay git-ignored; read them only when the task needs them; never commit them.

## Pending URL migration

The next release must apply [NEXT-RELEASE-URLS.md](NEXT-RELEASE-URLS.md): product sites moved to `https://magrathean.uk/solutions/<slug>/` and support addresses to `contact+<slug>@magrathean.uk`. Remove this section with that file once released.
