# Tescam

Tescam ships two developer surfaces from one repo:

Built by [Magrathean UK](https://magrathean.uk).

- a native app for browsing and exporting TeslaCam footage on macOS, iPhone, and iPad
- a separate cross-platform Python CLI for scripted or interactive exports on macOS, Linux, and Windows

The native app runs on Apple Silicon Macs, iPhone, and iPad from one codebase — the same engine behind a desktop workspace on macOS and an adaptive, portrait-first touch UI on iOS/iPadOS. It uses the shipping Swift export path. The CLI keeps the portable ffmpeg-based workflow.

## Canonical docs

- [Agent guide](./AGENTS.md)
- [Runbook](./RUNBOOK.md)
- [Domain contract](./docs/domain-contract.md)
- [Current iOS/iPadOS architecture](./docs/architecture-deepening/07-ios-ipados-app.md)
- [Current ASC platform metadata](./docs/releases/current-asc-platform-version.md)
- [1.0 release marker](./docs/releases/v1.0-app-store.md)

Current App Store train: `1.0` (`6`) for macOS and iOS/iPadOS. The Xcode project is the version/build source of truth.

## Repo map

- `TeslaCam/` - native app source (macOS + iOS/iPadOS), native export, playback, telemetry, and resources. `Main.swift` is the macOS entry, `IPadMain.swift` the iOS/iPadOS entry; `ContentView.swift` + `PortraitComponents.swift` hold the shared and adaptive-touch UI.
- `TeslaCamTests/` and `TeslaCamUITests/` - native test coverage
- `teslacam_cli/` - Python CLI package
- `tests/` - CLI unit and integration tests
- `script/test_native.sh` - native build-and-test lane
- `tools/TeslaCamOverlayGenerator.swift` - local utility built on the app parser
- `_legacy/` - old path, kept as reference only
- `TeslaCam/Resources/LICENSES.md` - kept third-party license asset

## Requirements

- Python 3.9+
- `ffmpeg` and `ffprobe`
- `libx265` support for lossless or CRF 6 HEVC CLI export
- Xcode on macOS for the native app (macOS, iOS, and iPadOS 26+ deployment targets)

## Quick start

Primary CLI:

```sh
./teslacam-cli
```

Compatibility adapters to the same Python module:

```sh
python3 teslacam.py
./teslacam.sh
```

## Verification quick reference

Use the runbook for details, but these are the repo-backed checks:

```sh
python3 -m unittest discover tests
script/test_native.sh
git diff --check
```

`tests.test_integration` and real CLI rendering require working `ffmpeg` and
`ffprobe`. No dedicated lint, format, or Python typecheck config is present.
Swift compile/typecheck coverage comes from the native Xcode build/test lane.
Set `TESLACAM_BUILD_ENV=/absolute/path/to/build-env.sh` for that lane; the local
shell file must define the Xcode cache paths used by the scripts and must remain
outside the repository.

## Domain parity and dry runs

The app and CLI share a fixture-backed domain contract for timestamp parsing, camera normalization, duplicate handling, layout selection, and output conflict naming. See `docs/domain-contract.md`. Shared fixtures live under `fixtures/domain/cases`.

The CLI can emit a machine-readable dry-run manifest without rendering:

```sh
teslacam-cli /path/to/TeslaCam --dry-run-json manifest.json
teslacam-cli /path/to/TeslaCam --dry-run-json -
```

Dry-run JSON states telemetry capability explicitly. The CLI keeps rendering ffmpeg-only and does not inspect SEI metadata; native app exports can burn timestamp, speed, AP, pedal/brake, steering, heading, and route overlays.

CLI exports default to `--mode evidence-hevc`, matching the app's Evidence HEVC intent. Native Original passthrough muxing remains app-only because it uses AVFoundation composition rather than the portable ffmpeg grid renderer.

## Architecture

- Domain behavior is fixture-backed and documented in `docs/domain-contract.md`.
- The CLI builds a pure run plan, then hands rendering and user output to adapters.
- The native app builds a validated export plan, runs preflight, and keeps export status observable.
- Camera layout is a shared contract: index, preview, native export, and CLI dry runs must agree.
- App state is split around timeline, export, playback, and UI-facing state so tests can cover logic without driving the full app.
- The iOS/iPadOS app reuses the same engine behind a native adaptive touch UI (portrait-first, Dynamic-Island-safe); see [`docs/architecture-deepening/07-ios-ipados-app.md`](./docs/architecture-deepening/07-ios-ipados-app.md).

## Notes

- The App Store app does not bundle `ffmpeg`.
- Native export is the shipping app path.
- `./teslacam-cli` is the primary CLI command; wrappers are compatibility adapters.
- `_legacy/` is non-canonical and should not drive new work.

## Legal

Copyright © 2026 Magrathean UK Ltd. All rights reserved.

Tescam is proprietary software. See [`LICENSE`](./LICENSE) for the full licence text. Third-party components and their licences are listed in [`license.md`](./license.md) and `TeslaCam/Resources/LICENSES.md`. Public availability of this repository does not grant any right to copy, modify, redistribute, or use the software outside the licence terms.

### User-supplied recordings and privacy

Tescam processes video and audio recordings from your Tesla's TeslaCam and Sentry Mode storage. **You are solely responsible for the lawful collection, retention, export, and onward sharing of those recordings**, which may contain personal data of identifiable individuals (drivers, passengers, pedestrians, neighbours, members of the public). Compliance with the **UK GDPR**, the **Data Protection Act 2018**, applicable surveillance and broadcast laws, and any tenancy or premises rules around camera placement is your responsibility. Magrathean UK Ltd. accepts no responsibility for how recordings processed by Tescam are used.

### Trademarks and disclaimers

Tesla, the Tesla logo, TeslaCam, and Sentry Mode are trademarks or registered trademarks of Tesla, Inc. FFmpeg is a trademark of the FFmpeg developers. Apple, the Apple logo, iOS, macOS, and Swift are trademarks of Apple Inc.

Tescam is **not affiliated with, endorsed by, sponsored by, or in any way officially connected to** Tesla, Inc., the FFmpeg project, or Apple Inc. References to these names exist solely for descriptive interoperability. All trademarks remain the property of their respective owners.

For licensing or commercial enquiries, email <contact@magrathean.uk>.

---

Magrathean UK Ltd. is a company registered in England and Wales (Company No. 16955343) with registered office at 16 Caledonian Court West Street, Watford, England, WD17 1RY.
