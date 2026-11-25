# Tescam — Current App Store Connect Release

This is the maintained handoff for the 1.0.1 train (1.0 is live, `READY_FOR_SALE`, build 7). Read
the identifiers back from ASC before any future mutation because version, build,
localization, screenshot-set, and review-submission IDs are environment-specific.

## Release summary

Tescam 1.0.1 is a maintenance release: updated website, support and privacy links, the frozen
FFmpeg binaries removed from the repository, and no change in app behaviour. Shipped directly to
App Store Connect with no TestFlight (G, 25 Nov 2026). Store assets carry forward from 1.0 and are
under `marketing/screenshots/asc_out/` (five iPhone, five iPad, four Mac screenshots).

## Live release records

- App: `Tescam`; App Store app ID `6787877132`
- Bundle ID, both platforms: `com.magrathean.teslacam`
- Version `1.0.1`, build `8`, archived from the commit tagged `v1.0.1`
- Copyright: `2026 MAGRATHEAN UK LTD`
- Release mode: `AFTER_APPROVAL` (automatic)
- Export compliance: `usesNonExemptEncryption = false` on both builds
- Submitted 25 Nov 2026 19:40 GMT; both versions `WAITING_FOR_REVIEW`

| | iOS and iPadOS | macOS |
| --- | --- | --- |
| Version ID | `9bf33eac-9941-4bd6-944b-ea9701e09cc3` | `2ffb985d-5e23-43e4-98ed-93f979e19ac7` |
| Build ID (state `VALID`) | `0f6fa10d-ce57-4f88-88a9-6d4cfab5de8f` | `c8f3f561-6da6-4c51-96bf-a3f552839c7f` |
| Localization ID (`en-GB`) | `d0bd3183-3255-4c37-baac-c383f88586a7` | `ef2458ff-ae45-4f4a-a3c6-c91121a317bd` |
| Review detail ID | `a2c6b82a-56d0-45e9-b693-7c0580b6fd67` | `94905552-6855-4bda-a08d-ca3e3d4855e2` |
| Review submission ID | `33ecd619-d6e5-4a83-bf7d-9654643bf231` | `13fef9bc-6c13-42b5-aff0-9cc9df83db8e` |

1.0 records (for reference): iOS version `9bf33eac-9941-4bd6-944b-ea9701e09cc3`, build 7
`2020ba75-a2e3-4e7f-8326-44da86df8754`; macOS version `2ffb985d-5e23-43e4-98ed-93f979e19ac7`,
build 7 `76ee58c0-b679-4ac3-b55a-3455dc148307`. Two empty `READY_FOR_REVIEW` draft submissions
(`42e15b24-2f04-48b5-a77d-d181be283188` iOS, `d08baf0d-9dd2-481a-bedd-a64eeacc322a` macOS) predate
1.0.1 and were left alone.

### Shared App Info

- App Info localization ID (`en-GB`): `5fbbaa15-3dca-4bdb-8f7b-11d9f2e4ef17`
- Name `Tescam`; subtitle `Local dashcam video editor`
- Age-rating declaration unchanged from 1.0

## Signing and upload

Team `NPSQV9WYS5`, automatic signing with the ASC API key (`-allowProvisioningUpdates`), Apple
Distribution and Mac Installer identities already on the Mac. Archive with `-jobs 4`, export with
`method app-store-connect`, upload with `xcrun altool --upload-app`. Run the macOS archive and
export under `umask 022`: with `umask 077` the pkg holds root-only files and ASC rejects it
(error 90255). Signing material and the API key stay outside the repository.

## Live URLs

- Marketing: `https://magrathean.uk/solutions/tescam/`
- Support: `https://magrathean.uk/solutions/tescam/` (no `/support/` page exists; it returns 404)
- Privacy policy: `https://magrathean.uk/solutions/tescam/privacy/` (shared App Info localization)
- Terms: `https://magrathean.uk/solutions/tescam/terms/`
- Review contact: `contact+tescam@magrathean.uk`
- What's New: `Updated website and support links, plus maintenance improvements.`

## Store copy

### iPhone and iPad

Promotional text:

```text
Review multi-camera dashcam footage, trim the useful range and export evidence clips locally on iPhone and iPad.
```

Description:

```text
Tescam is a local viewer and exporter for multi-camera car dashcam recordings on iPhone and iPad. Choose a recordings folder, review up to six synchronised camera angles on one timeline, trim the useful range, pick the cameras you need, and export clear evidence clips in H.265 (HEVC) or H.264.

Built for local review: timeline scrubbing, synchronised playback, camera selection, precise export ranges, duplicate-aware scanning, and optional telemetry engraving when the recording contains it.

Tescam processes only the recordings you select, on your device. It does not sign in to any account, connect to or control a vehicle, or upload footage. You stay responsible for collecting, retaining and sharing footage lawfully.

Tescam is an independent app by MAGRATHEAN UK LTD and is not affiliated with or endorsed by any vehicle manufacturer.

Terms of use: https://magrathean.uk/solutions/tescam/terms/
```

### Mac

Promotional text:

```text
Review multi-camera dashcam footage, trim the useful range and export evidence clips locally on your Mac.
```

Description:

```text
Tescam is a local viewer and exporter for multi-camera car dashcam recordings on Mac. Choose a recordings folder, review up to six synchronised camera angles on one timeline, trim the useful range, pick the cameras you need, and export clear evidence clips in H.265 (HEVC) or H.264.

Built for local review: timeline scrubbing, synchronised playback, camera selection, precise export ranges, duplicate-aware scanning, and optional telemetry engraving when the recording contains it.

Tescam processes only the recordings you select, on your Mac. It does not sign in to any account, connect to or control a vehicle, or upload footage. You stay responsible for collecting, retaining and sharing footage lawfully.

Tescam is an independent app by MAGRATHEAN UK LTD and is not affiliated with or endorsed by any vehicle manufacturer.

Terms of use: https://magrathean.uk/solutions/tescam/terms/
```

Keywords on both platforms:

```text
dash cam,car camera,driving recorder,export,evidence,hevc,h264,timeline,multi camera,trim,clips
```

## Screenshots

The checked-in upload assets are under `marketing/screenshots/asc_out/` and
contain five distinct images for each mobile family and four for Mac. The iPhone
set was regenerated on 1 October 2026 so that its first caption names no brand:

- iPhone: `marketing/screenshots/asc_out/iphone/`, `APP_IPHONE_67`, 1320 × 2868
- iPad: `marketing/screenshots/asc_out/ipad/`, `APP_IPAD_PRO_3GEN_129`, 2064 × 2752
- Mac: `marketing/screenshots/asc_out/mac/`, `APP_DESKTOP`, 2880 × 1800

The 14 uploaded assets passed `asc screenshots validate` with zero errors and
zero warnings. Their upload state was `COMPLETE` when this handoff was
refreshed. A fifth Mac capture was retained locally but not uploaded because
its decoded pixels duplicated another Mac screenshot.

## Build and metadata checks

```sh
APP_ID=6787877132
VERSION=1.0.1

/opt/homebrew/bin/asc builds list --app "$APP_ID" --version "$VERSION" --build-number 8 --processing-state all
/opt/homebrew/bin/asc versions view --version-id 9bf33eac-9941-4bd6-944b-ea9701e09cc3 --include-build --include-submission
/opt/homebrew/bin/asc versions view --version-id 2ffb985d-5e23-43e4-98ed-93f979e19ac7 --include-build --include-submission
/opt/homebrew/bin/asc localizations list --version 9bf33eac-9941-4bd6-944b-ea9701e09cc3 --include appScreenshotSets
/opt/homebrew/bin/asc localizations list --version 2ffb985d-5e23-43e4-98ed-93f979e19ac7 --include appScreenshotSets
/opt/homebrew/bin/asc review submissions-list --app "$APP_ID"
```

Do not release from this handoff. Both versions are already submitted and
waiting for review. The canonical ASC validation reported zero blocking errors;
it retained only keyword warnings and the App Privacy publication check that
the public API cannot verify. App Privacy publication remains a manual ASC
check because the public API does not expose its publish state.
