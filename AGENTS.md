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

<!-- clean-development-policy:v1 (canonical text: ~/dev/source/dev-bootstrap/snippets/clean-development-policy.md) -->
## Clean development (mandatory)

This project follows [Clean Development](https://github.com/magrathean-uk/clean-development) and the machine rule that nothing creates tool state under `~` (only the allow-listed agent homes).

- The shell environment comes from `~/.zshenv`, which loads `~/dev/env.zsh`. It routes every tool home and cache (`CARGO_HOME`, `RUSTUP_HOME`, `XDG_*`, `BUNDLE_USER_HOME`, `npm_config_cache`, `XCODE_DERIVED_DATA_PATH`, ...) and switches telemetry off. Never unset, override or bypass those variables. If a script needs a scrubbed environment, re-export them with `source ~/dev/env.zsh`.
- Run builds, tests, installs and anything else that writes caches or build output through Clean Development: `clean-development run --session session-only -- <command>`. Follow its docs and keep its receipts.
- Do not add installers or scripts that default into `~` (`~/.cargo`, `~/.rustup`, `~/.cache`, `~/.npm`, `~/.swiftpm`, `~/.gradle`, ...) and do not hardcode `$HOME` paths for caches; use the routed variables.
- Before finishing, run `dev-env-check` (must pass) and `dev-audit` (no new entries in `~`). If your work caused a violation, fix the cause in the repo and say so.

## Pending URL migration

The next release must apply [NEXT-RELEASE-URLS.md](NEXT-RELEASE-URLS.md): product sites moved to `https://magrathean.uk/solutions/<slug>/` and support addresses to `contact+<slug>@magrathean.uk`. Remove this section with that file once released.
