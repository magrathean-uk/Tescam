# Development runbook

These instructions are for maintainers authorised to work on Tescam under the [repository licence](LICENSE). Run commands from the repository root. Product usage is in [README.md](README.md).

## Python CLI

Use Python 3.9 or newer. The package declares no runtime Python dependencies. Install into an active virtual environment when package installation is needed:

```sh
python3 -m pip install -e .
```

The repository entry point is `./teslacam-cli`; `python3 teslacam.py` and `./teslacam.sh` call the same module. The installed command is `teslacam-cli`.

Rendering needs `ffmpeg` and `ffprobe` on `PATH`, or explicit `--ffmpeg` and `--ffprobe` paths. HEVC modes need an FFmpeg build with `libx265`.

```sh
./teslacam-cli /path/to/TeslaCam --dry-run-json manifest.json
```

This scans and writes a plan without rendering. The CLI defaults to `evidence-hevc`. Native Original passthrough, camera-track cuts and telemetry engraving remain app features.

## Validation

Choose checks for the changed boundary:

| Change | Check |
| --- | --- |
| Shared scan, layout, selection or output rules | `python3 -m unittest tests.test_domain_contract` |
| Python CLI or rendering | `python3 -m unittest discover tests` |
| FFmpeg integration | `python3 -m unittest tests.test_integration` |
| Native app | `script/test_native.sh` |
| Whitespace | `git diff --check` |

Integration tests require FFmpeg and FFprobe; tests with missing tools can be skipped. Real-footage tests have additional source and render opt-ins described in `tests/test_integration.py`. Check the test output before claiming that a lane passed.

There is no dedicated lint, formatter or Python typecheck configuration. Use the existing checks instead of inventing a canonical lint command.

Shared changes must update [the domain contract](docs/domain-contract.md), fixtures in `fixtures/domain/cases/`, and Python and Swift coverage. Regenerate fixture expectations with:

```sh
python3 script/regen_fixtures.py
python3 -m unittest tests.test_domain_contract
```

Inspect the resulting fixture changes. Fixture parity, native tests and a successful build do not establish ordinary-user or device acceptance.

## Native app

Use Xcode on macOS. Both native scripts source a build environment before invoking Xcode. Set `TESLACAM_BUILD_ENV` to a compatible environment script; they also recognise the maintainer's existing fallback configured in the scripts. A missing environment is a setup blocker, not a reason to bypass the scripts with ad hoc build commands.

```sh
script/test_native.sh
script/build_and_run.sh
```

The test script builds for testing, runs `TeslaCamTests`, then runs `TeslaCamUITests`. The run script stops an existing Tescam process, builds the macOS app and launches it. `.codex/environments/environment.toml` uses that run script.

The project contains `TeslaCam` and `TeslaCam iPad` schemes. The local scripts above target macOS. For mobile UI boundaries and source registration, see [the iOS/iPadOS guide](docs/architecture-deepening/07-ios-ipados-app.md).

Native export is the app's shipping export path. Keep export plans, preflight, preview layouts and camera controls aligned. The 4-camera grid has two columns and two rows; the 6-camera grid has three columns and two rows. Missing cameras use black placeholders.

## Debugging and acceptance

Debug builds accept `TESLACAM_DEBUG_SOURCE` for a local source folder. `TESLACAM_UI_TEST_MODE=blank` exercises onboarding; `TESLACAM_UI_TEST_MODE=sample` supplies the sample timeline. Keep diagnostics local and use the app's Show Log action after a failed or cancelled export.

For playback, layout or export changes, verify the affected flow with representative footage: source selection, gaps and duplicates, camera selection, range selection, export, cancellation and output conflicts. Mobile UI changes also need checks in portrait and landscape with safe areas intact. Keep the manual codec picker and Engrave telemetry control.

## Existing CI

The Python workflow runs the full unittest suite on Python 3.10 and 3.12 after installing FFmpeg and the package. The native workflow builds on `macos-26` with signing disabled and runs `TeslaCamTests`. It does not run the local UI test lane.

These descriptions refer to [.github/workflows/python-tests.yml](.github/workflows/python-tests.yml) and [.github/workflows/native-tests.yml](.github/workflows/native-tests.yml). Do not treat a workflow description as evidence of a current green run.

## Releases

Keep release records in [docs/releases/](docs/releases/). Compare the Xcode project's version and build with those records before authorised release work. Store status in those files is a recorded snapshot, not a live App Store query.

Signing, uploads, publication and production access require their existing authority. Keep platform bundle identifiers, screenshots and App Store Connect operations separate. Do not replace owner holds with historical instructions.

## Optional local hook

`script/pre-commit.example.sh` offers a Python test lane, staged whitespace check and a DerivedData cache tripwire. Hook installation is opt-in. It does not replace the native lane and is not installed automatically by the project.
