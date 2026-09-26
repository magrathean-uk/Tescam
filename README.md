# Tescam

Tescam is a TeslaCam footage browser and exporter for macOS, iPhone, and iPad, with a separate Python command line interface for scripted or interactive exports. The native app is the shipping macOS export path. The CLI is a portable, dependency-light ffmpeg workflow for macOS, Linux, and Windows.

The project is maintained by [Magrathean UK](https://magrathean.uk). The app and CLI read TeslaCam clip trees, resolve camera names and duplicate clips, and plan a selected time range for export. The app also provides synchronized playback.

## What it supports

- Native SwiftUI app targets for macOS and iOS/iPadOS, sharing the indexing, playback, telemetry, layout, and native export engine.
- macOS review workspace plus an adaptive iPhone and iPad interface.
- Tesla legacy four-camera and HW4 six-camera layouts. Automatic selection uses the available camera names; missing cameras remain visible as black placeholders.
- Timeline playback, trim range selection, duplicate resolution, codec selection, and native export. The app can engrave timestamp, speed, Autopilot, pedal/brake, steering, heading, and route overlays when telemetry is available.
- Python CLI modes for evidence HEVC, lossless HEVC, review, and share output, plus event listing, event-centered export, dry runs, JSON manifests, output conflict policies, and explicit ffmpeg/ffprobe paths.

The current Xcode targets use native export and do not include FFmpeg in their resource build phases. Native Original passthrough and telemetry engraving are app features. The CLI does not inspect SEI telemetry metadata and does not apply native camera-track cuts.

## Repository map

- `TeslaCam/`: native app source and resources for macOS and iOS/iPadOS.
- `TeslaCamTests/` and `TeslaCamUITests/`: native test targets.
- `teslacam_cli/`: Python CLI package.
- `tests/`: Python unit and integration tests.
- `fixtures/domain/cases/`: shared Swift and Python domain fixtures.
- `script/test_native.sh`: native build and test lane.
- `script/build_and_run.sh`: local macOS build and launch helper.
- `tools/`: local utilities, including the overlay generator.
- `docs/domain-contract.md`: shared scan, layout, selection, output, and telemetry boundaries.
- `_legacy/`: reference-only material.

## Requirements

For the CLI, use Python 3.9 or newer, `ffmpeg`, and `ffprobe`. Evidence and lossless HEVC modes require an ffmpeg build with `libx265`.

For the native app, use Xcode on macOS. The current project targets macOS 26 and iOS/iPadOS 26. The Xcode project is the version and build source of truth. The project currently declares version `1.0`, build `6`; this is not a claim about live App Store availability.

## CLI quick start for authorized maintainers

Authorized maintainers can run the CLI from the repository root:

```sh
./teslacam-cli
```

The compatibility adapters invoke the same Python module:

```sh
python3 teslacam.py
./teslacam.sh
```

The package declares no runtime Python dependencies. An editable install into an active virtual environment is optional for an authorized maintainer who wants the `teslacam-cli` entry point on `PATH`:

```sh
python3 -m pip install -e .
teslacam-cli /path/to/TeslaCam --dry-run-json manifest.json
```

Useful non-interactive examples:

```sh
teslacam-cli /path/to/TeslaCam --start 2026-01-01_12-00-00 --end 2026-01-01_12-05-00 -o export.mp4
teslacam-cli /path/to/TeslaCam --profile sixcam --mode review -o review.mp4
teslacam-cli /path/to/TeslaCam --list-events
teslacam-cli /path/to/TeslaCam --event 1 --pre 30 --post 30 -o event.mp4
```

`--profile` accepts `auto`, `legacy4`, or `sixcam`. `--duplicate-policy` accepts `merge-by-time`, `prefer-newest`, or `keep-all`. `--output-conflict` accepts `unique`, `overwrite`, or `error`. `--dry-run` prints the resolved plan without rendering; `--dry-run-json PATH` writes its schema version 1 manifest to a file, or to standard output when `PATH` is `-`.

The default CLI mode is `evidence-hevc`, which uses x265 CRF 6 when the selected ffmpeg encoder supports it. The other modes are `lossless`, `quality`, `review`, and `share`. The CLI normalizes a non-`.mp4` output path to `.mp4` and appends a numeric suffix under the default `unique` conflict policy.

## Native app development

Use the repository scripts to load the configured build environment and derived-data destination:

```sh
script/test_native.sh
script/build_and_run.sh
```

The native test script resolves `TESLACAM_BUILD_ENV` when set, otherwise uses the local fallback configured in the script. An explicit missing override stops the script. If no compatible build environment is available, it stops before invoking `xcodebuild`. The test lane runs the macOS app build, `TeslaCamTests`, and `TeslaCamUITests`.

The `TeslaCam` and `TeslaCam iPad` schemes are the maintained app schemes. Keep new Swift files registered for both app targets when they are shared. The iOS/iPadOS UI must continue to bind through the existing `AppState` surface.

## Verification

Run the Python suite from the repository root:

```sh
python3 -m unittest discover tests
```

Run the native lane when the Xcode build environment is available:

```sh
script/test_native.sh
```

For whitespace-only hygiene:

```sh
git diff --check
```

There is no dedicated lint, formatter, or Python typecheck configuration in this repository. Shared domain changes must keep `docs/domain-contract.md`, `fixtures/domain/cases/`, the Python tests, and native parity tests aligned.

## Documentation

- [Runbook](RUNBOOK.md): setup, CLI options, native commands, debug flow, and release checks.
- [Domain contract](docs/domain-contract.md): shared camera, duplicate, layout, output, and telemetry behavior.
- [iOS and iPadOS architecture](docs/architecture-deepening/07-ios-ipados-app.md): entry points, adaptive layout, safe areas, and export controls.
- [Support](SUPPORT.md) and [contribution guidance](CONTRIBUTING.md).
- [Recorded App Store metadata](docs/releases/current-asc-platform-version.md) and [release marker](docs/releases/v1.0-app-store.md). These are repository snapshots.
- [Security policy](SECURITY.md): reporting route, scope, and safe-harbor terms.

## License and privacy

Tescam is proprietary software owned by Magrathean UK Ltd. Copyright © 2026 Magrathean UK Ltd. All rights reserved. Read the complete terms in [`LICENSE`](LICENSE). The third-party notice and component inventory is in [`license.md`](license.md), with the app asset at [`TeslaCam/Resources/LICENSES.md`](TeslaCam/Resources/LICENSES.md).

See [TRADEMARKS.md](TRADEMARKS.md) for the existing notices. Tescam is independent of Tesla.

Tescam processes recordings selected by the user. Those recordings can contain personal data, including images or audio of drivers, passengers, pedestrians, or other members of the public. The user is responsible for lawful collection, retention, export, and sharing, including compliance with applicable data protection, surveillance, tenancy, and premises rules.

For licensing enquiries, use [contact@magrathean.uk](mailto:contact@magrathean.uk). For security reports, follow [SECURITY.md](SECURITY.md).
