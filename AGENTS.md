# Tescam agent context

<!-- clean-development-policy:v6 -->
Purpose: multi-camera dashcam footage browser and exporter for macOS, iPhone and iPad (SwiftUI), plus a dependency-light Python CLI. `README.md` has the product overview; `docs/development/runbook.md` covers build and release.

## Commands
- Python CLI: `python3 -m pip install -e .`, then `./tescam-cli`
- Python tests: `python3 -m unittest discover tests` (shared contract only: `python3 -m unittest tests.test_domain_contract`)
- Native tests: `script/test_native.sh`; build and run: `script/build_and_run.sh`
- Regenerate shared fixtures: `python3 script/regen_fixtures.py`
- Check: `git diff --check`. There is no lint, formatter or type-check config.
- Native commands need `TESCAM_BUILD_ENV` or the project-supported local build environment; build output goes to `$CLEAN_DEV_BUILDS` (see `.clean-development.json`).

## Conventions
- `Tescam/` is the shared native engine, platform UI, export, playback and resources; native export is the shipping export implementation. Tests: `TescamTests/`, `TescamUITests/`.
- `tescam_cli/` and `tests/` are the Python CLI; planning is separate from rendering and human-facing output adapters.
- Swift and Python share behaviour through `fixtures/domain/cases/` and `docs/domain-contract.md`; change both sides together.
- Mobile UI uses the `AppState` API. The Xcode project has `Tescam` and `Tescam iPad` targets; source membership is in `Tescam.xcodeproj/project.pbxproj`.
- `_legacy/` and `tescam_legacy_macos.sh` are historical reference only.
- Resource licences are in `Tescam/Resources/LICENSES.md`; release and App Store records are in `docs/development/`.
- URL migration to `https://magrathean.uk/solutions/<slug>/` and `contact+<slug>@magrathean.uk`: `NEXT-RELEASE-URLS.md`.

## Versions
- App: `MARKETING_VERSION` 1.0, build (`CURRENT_PROJECT_VERSION`) 7 in the Xcode project; this is the App Store version. Existing tag `v1` is a lightweight marker (commit 0d1a7b8).
- CLI: `pyproject.toml` version 0.1.0 is a separate number for the Python package. Do not align the two.
- No GitHub Releases. Release tags are annotated `vX.Y.Z` on the shipping commit; only `vX.Y.Z` tags are pushed (public repo).

## Continuity
- Public repo: passover and decisions log live outside git in `~/dev/records/tescam/` (`PASSOVER.md`, `DECISIONS.md`).
