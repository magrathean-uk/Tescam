# Licensing and third-party notices

## Tescam source

Tescam is proprietary software owned by Magrathean UK Ltd. Copyright © 2026 Magrathean UK Ltd. All rights reserved.

[LICENSE](LICENSE) contains the controlling terms. Public repository access permits inspection as described there; it does not grant general rights to clone, modify or redistribute the source. This overview adds no licence grant and changes no existing rights. App Store binary use has the separate terms described in section 6 of LICENSE.

Licensing enquiries: [contact@magrathean.uk](mailto:contact@magrathean.uk).

## Reference acknowledgements

The existing [app acknowledgements](TeslaCam/Resources/LICENSES.md) identify these MIT-licensed references and describe the native Swift/Metal implementation:

| Reference | Existing attribution |
| --- | --- |
| [Sentry-Six](https://github.com/ChadR23/Sentry-Six) | Copyright (c) 2025 Chad |
| [tesla-sentry-viewer-frontend](https://github.com/denysvitali/tesla-sentry-viewer-frontend) | Copyright (c) 2025 Denys Vitali |

Those acknowledgements are preserved. They are not a complete audit of source provenance or of a distributed binary's licence obligations.

## Components and distribution

The current Xcode project declares no external Swift package or CocoaPods dependencies. The native app uses Apple frameworks, including AVFoundation and Metal, and exports through its native engine.

The Python package declares no runtime Python dependencies. Its build requirements are `setuptools>=68` and `wheel`. CLI rendering uses separately supplied FFmpeg and FFprobe; HEVC modes require `libx265` support. The licences and obligations for those tools depend on the actual build and components supplied.

The repository also contains FFmpeg and FFprobe binaries under `TeslaCam/Resources/ffmpeg_bin/` and older shell helpers. They are not listed in the current app targets' resource build phases. Their presence still needs to be considered when distributing repository contents. The existing reference acknowledgements do not document those binaries' exact provenance, configuration or complete licence notices. Verify those facts for the exact artefacts before redistribution; this document does not certify compliance.

Third-party components retain their own rights and terms, as stated in section 5 of LICENSE. Do not replace their terms with Tescam's proprietary licence.

## Names and user material

[TRADEMARKS.md](TRADEMARKS.md) records the project's trade-mark notices. Tescam is independent of Tesla. User-supplied recordings remain subject to the responsibilities in LICENSE and the [published privacy notice](https://teslacam.eu/privacy/).

The root notice inventory is tracked as `license.md`. The existing legal text refers to it as `LICENSE.md`; links in this documentation use the tracked filename.
