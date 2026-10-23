# Tescam project context

Tescam contains a SwiftUI app for macOS, iPhone, and iPad, plus a dependency-light Python CLI. `README.md` has the product overview; `RUNBOOK.md` describes build and release procedures.

## Structure and behaviour

- `Tescam/` contains the shared native engine, platform UI, export path, playback, and resources. Native export is the shipping app export implementation.
- `TescamTests/` and `TescamUITests/` contain native tests.
- `tescam_cli/` and `tests/` contain the Python CLI and its tests. CLI planning is separate from rendering and human-facing output adapters.
- `fixtures/domain/cases/` and `docs/domain-contract.md` describe behaviour shared by Swift and Python.
- `_legacy/` and `tescam_legacy_macos.sh` contain historical reference material.
- Mobile UI uses the `AppState` API. The Xcode project has `Tescam` and `Tescam iPad` targets, with source membership recorded in `Tescam.xcodeproj/project.pbxproj`.
- The app has a manual codec picker, opt-in telemetry engraving, and local diagnostics.
- `Tescam/Resources/LICENSES.md` contains resource licences; `docs/development/` contains release and App Store information.

## Command reference

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

Native commands depend on `TESCAM_BUILD_ENV` or the project-supported local build environment. There is no dedicated lint, formatter, or Python type-check configuration.

The workstation environment is loaded from `~/dev/machine/env.zsh`. Its routed locations include `$TMPDIR` for session scratch, `$CLEAN_DEV_BUILDS` for throwaway build output, and tool-specific cache variables. `.clean-development.json` describes this project's build and dependency directories.

## URL migration reference

[NEXT-RELEASE-URLS.md](NEXT-RELEASE-URLS.md) records the migration to `https://magrathean.uk/solutions/<slug>/` and `contact+<slug>@magrathean.uk`.
