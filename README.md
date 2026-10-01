<p align="center">
  <img src="https://raw.githubusercontent.com/magrathean-uk/magrathean-uk/main/assets/icons/teslacam.png" width="96" height="96" alt="">
</p>

<h1 align="center">Tescam</h1>

<p align="center">A TeslaCam and Sentry Mode footage browser and exporter for macOS, iPhone and iPad, with a portable Python CLI.</p>

<p align="center">
  <a href="https://magrathean.uk/solutions/tescam/">Website</a> ·
  <a href="docs/index.md">Documentation</a> ·
  <a href="https://magrathean.uk/solutions/tescam/privacy/">Privacy</a>
</p>

## Overview

Tescam is maintained by Magrathean. The native SwiftUI app and the Python CLI both read
TeslaCam clip trees, resolve camera names and duplicate clips, and plan a selected time
range for export. The app is the shipping macOS, iPhone and iPad export path and adds
synchronized playback; the CLI is a portable, dependency-light ffmpeg workflow for macOS,
Linux and Windows. The App Store release is under review; the CLI ships from this
repository's source.

## Features

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
- `docs/architecture/domain-contract.md`: shared scan, layout, selection, output, and telemetry boundaries.
- `_legacy/`: reference-only material.

## Requirements

For the CLI, use Python 3.9 or newer, `ffmpeg`, and `ffprobe`. The CLI test suite and package build are verified with Python 3.14.7. Evidence and lossless HEVC modes require an ffmpeg build with `libx265`.

For the native app, use Xcode on macOS. The current project targets macOS 26 and iOS/iPadOS 26. The Xcode project is the version and build source of truth. The project currently declares version `1.0`, build `6`; this is not a claim about live App Store availability.

## CLI quick start

Run the CLI from the repository root:

```sh
./teslacam-cli
```

The compatibility adapters invoke the same Python module:

```sh
python3 teslacam.py
./teslacam.sh
```

The package declares no runtime Python dependencies. An editable install into an active virtual environment is optional if you want the `teslacam-cli` entry point on `PATH`:

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

The native test script resolves `TESLACAM_BUILD_ENV` when set, otherwise uses the local fallback configured in the script (`build-env.sh` under `BOLYKI_SOURCE_ROOT`, default `~/dev/source`). An explicit missing override stops the script. If no compatible build environment is available, or it does not route `XCODE_DERIVED_DATA_PATH`, it stops before invoking `xcodebuild`. The test lane runs the macOS app build, `TeslaCamTests`, and `TeslaCamUITests`.

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

- [Documentation index](docs/index.md)
- [Runbook](docs/development/runbook.md): setup, CLI options, native commands, debug flow, and release checks.
- [Domain contract](docs/architecture/domain-contract.md): shared camera, duplicate, layout, output, and telemetry behavior.
- [iOS and iPadOS architecture](docs/architecture/ios-ipados-app.md): entry points, adaptive layout, safe areas, and export controls.
- [Support](.github/SUPPORT.md) and [contribution guidance](.github/CONTRIBUTING.md).
- [Recorded App Store metadata](docs/development/current-asc-platform-version.md), a repository snapshot.
- [Security policy](.github/SECURITY.md): reporting route, scope, and safe-harbor terms.

## Licence

Tescam is free software under the [GNU General Public License, version 3](LICENSE)
(GPL-3.0-only). Copyright © 2026 MAGRATHEAN UK LTD. You may use, study, change and share it
on the terms of that licence. [NOTICE](NOTICE) lists the bundled FFmpeg build and where its
source is; the full third-party inventory is in
[docs/legal/third-party-notices.md](docs/legal/third-party-notices.md). The licence covers the
code, not the Tescam name or icon: see [docs/legal/trademarks.md](docs/legal/trademarks.md).
App Store distribution and your responsibility for recordings are in
[docs/legal/overview.md](docs/legal/overview.md). Contributions: see
[CONTRIBUTING](.github/CONTRIBUTING.md). Tescam is independent. It is not affiliated with,
endorsed by or supported by Tesla, Inc.

Questions: [contact@magrathean.uk](mailto:contact@magrathean.uk). Security reports: [.github/SECURITY.md](.github/SECURITY.md).

<sub>© 2026 MAGRATHEAN UK LTD · GPL-3.0-only · <a href="https://github.com/magrathean-uk/.github/blob/main/LEGAL.md">Legal</a></sub>
