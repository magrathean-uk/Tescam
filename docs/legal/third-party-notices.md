# Third-party notices

Components and material in Tescam that carry their own licence, separate from the Tescam
source licence.

MAGRATHEAN UK LTD ("Magrathean") owns Tescam. [`LICENSE`](../../LICENSE) is the controlling
licence for the repository; this page does not change it. Third-party components keep their
own licences, as `LICENSE` and [`NOTICE`](../../NOTICE) state.

## FFmpeg and FFprobe (GPL)

`TeslaCam/Resources/ffmpeg_bin/ffmpeg` and `ffprobe` are FFmpeg project binaries tracked in
this public repository. They report `--enable-gpl`, `--enable-libx264` and
`--enable-libx265` in their build configuration, which makes them a GPL build of FFmpeg
(FFmpeg without `--enable-gpl` is LGPL; with it, and with `libx264`/`libx265` enabled, the
build is GPL-licensed). They are not part of either app target's Resources build phase, so
they are not currently included in the built app; the binaries themselves are present in the
public repository.

Distributing software that includes a GPL-licensed component requires giving recipients the
GPL licence text and the corresponding source for that component. [`NOTICE`](../../NOTICE)
carries the component entry; the licence text and the exact FFmpeg/x264/x265 source
corresponding to these built binaries are not yet attached in this repository.

## Reference acknowledgements

The app's own [acknowledgements file](../../TeslaCam/Resources/LICENSES.md) credits two
MIT-licensed reference projects that the native Swift/Metal implementation drew ideas from,
without vendoring their code:

| Reference | Copyright |
| --- | --- |
| [Sentry-Six](https://github.com/ChadR23/Sentry-Six) | Copyright (c) 2025 Chad |
| [tesla-sentry-viewer-frontend](https://github.com/denysvitali/tesla-sentry-viewer-frontend) | Copyright (c) 2025 Denys Vitali |

## Build dependencies

The Xcode project declares no external Swift package or CocoaPods dependencies; the native
app uses only Apple frameworks (including AVFoundation and Metal). The Python package
(`teslacam-cli`) declares no runtime dependencies; its build requirements are
`setuptools>=68` and `wheel`.

## Names

[`docs/legal/trademarks.md`](trademarks.md) records Tescam's trade-mark notices, including
its independence from Tesla, Inc.
