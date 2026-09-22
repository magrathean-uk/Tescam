# License — Tescam

## This Project

Tescam is **proprietary software** owned by Magrathean UK Ltd.

> See [`LICENSE`](./LICENSE) for the full proprietary licence text.
> Copyright © 2026 Magrathean UK Ltd. All rights reserved.

This file (`LICENSE.md`) is the **third-party notice and component inventory** for Tescam, supplemented by `TeslaCam/Resources/LICENSES.md`. The Tescam source itself is governed exclusively by [`LICENSE`](./LICENSE).

---

## Third-Party Dependencies

### Swift application — `TeslaCam.xcodeproj`

No external Swift Package Manager or CocoaPods dependencies are declared. The app
uses Apple system frameworks only (AVFoundation, Metal, CoreLocation, etc.) under
the Apple SDK licence agreement.

Tescam acknowledges two MIT-licensed reference projects whose ideas were studied
but whose code was **not** copied — they are reimplemented natively in Swift/Metal.
This acknowledgement is recorded in `TeslaCam/Resources/LICENSES.md`.

| Reference project | License | Acknowledgement file |
|-------------------|---------|----------------------|
| [Sentry-Six](https://github.com/ChadR23/Sentry-Six) — Copyright © 2025 Chad | MIT | `TeslaCam/Resources/LICENSES.md` |
| [tesla-sentry-viewer-frontend](https://github.com/denysvitali/tesla-sentry-viewer-frontend) — Copyright © 2025 Denys Vitali | MIT | `TeslaCam/Resources/LICENSES.md` |

### Python CLI — `pyproject.toml` / `teslacam_cli/`

The Python CLI has **no runtime dependencies** (pure stdlib). Build tooling only:

| Package | License | Declared in |
|---------|---------|-------------|
| `setuptools` *(build)* | MIT | `pyproject.toml` |
| `wheel` *(build)* | MIT | `pyproject.toml` |

### Legacy Swift package — `_legacy/Package.swift`

The legacy macOS target (`TeslaCamPro`) has no external package dependencies.

---

## License Obligations Summary

| License | Action required on redistribution |
|---------|-----------------------------------|
| MIT (reference only) | No code copied; acknowledgement in `TeslaCam/Resources/LICENSES.md` already satisfies attribution expectations. |
| MIT (build tools) | Retain copyright notice and licence text for any redistributed build artefacts. |
