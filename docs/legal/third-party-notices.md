# Third-party notices

Components and material in Tescam that carry their own licence, separate from the Tescam
source licence.

MAGRATHEAN UK LTD ("Magrathean") owns Tescam and licenses it under GPL-3.0-only
([`LICENSE`](../../LICENSE)); this page does not change that. Third-party components keep their
own licences, as [`NOTICE`](../../NOTICE) states.

## FFmpeg and FFprobe (GPL)

`Tescam/Resources/ffmpeg_bin/ffmpeg` and `ffprobe` are FFmpeg 7.1 binaries: a third-party
static build for Apple silicon, tracked in this repository. Their build configuration
includes `--enable-gpl`, `--enable-libx264` and `--enable-libx265`, so they are licensed under
the GNU General Public License, version 2 or later, which is compatible with Tescam's
GPL-3.0-only. `ffmpeg -version` prints the full configuration.

The command-line tool falls back to these binaries when no other FFmpeg is found. They are
not part of either app target's Resources build phase, so the app does not include them.

Source: the FFmpeg 7.1 release is at <https://ffmpeg.org/releases/ffmpeg-7.1.tar.xz>, and
x264 and x265 are at <https://code.videolan.org/videolan/x264> and
<https://bitbucket.org/multicoreware/x265_git>. For the complete corresponding source of these
exact binaries, including the other libraries in their configuration, write to
[contact@magrathean.uk](mailto:contact@magrathean.uk).

## Reference acknowledgements

The app's own [acknowledgements file](../../Tescam/Resources/LICENSES.md), bundled with
the app, states Tescam's GPL-3.0-only licence and where its source is, and credits two
MIT-licensed reference projects that the native Swift/Metal implementation drew ideas from,
without vendoring their code:

| Reference | Copyright |
| --- | --- |
| [Sentry-Six](https://github.com/ChadR23/Sentry-Six) | Copyright (c) 2025 Chad |
| [tesla-sentry-viewer-frontend](https://github.com/denysvitali/tesla-sentry-viewer-frontend) | Copyright (c) 2025 Denys Vitali |

## Build dependencies

The Xcode project declares no external Swift package or CocoaPods dependencies; the native
app uses only Apple frameworks (including AVFoundation and Metal). The Python package
(`tescam-cli`) declares no runtime dependencies; its build requirements are
`setuptools>=82.0.1` and `wheel>=0.48.0`. Both are MIT-licensed build tools and are not
distributed with the package.

## Names

[`docs/legal/trademarks.md`](trademarks.md) records Tescam's trade-mark notices, including
its independence from Tesla, Inc.
