# Tescam — Current App Store Connect Release

This is the maintained handoff for the 1.1 train (1.0.1 is live on iOS, `READY_FOR_SALE`, build 8; macOS
1.0.1 was withdrawn from review and replaced by 1.1). Read the identifiers back from ASC before any
future mutation because version, build, localization, screenshot-set, and review-submission IDs are
environment-specific.

## Release summary

Tescam 1.1 adds Evidence files: an export option that writes, next to each export, a manifest with
SHA-256 fingerprints of the source clips and the exported video, plus telemetry as CSV and GPX when the
recording has it. Shipped directly to App Store Connect with no TestFlight (G, 25 Nov 2026). Store
assets carry forward from 1.0 and are under `marketing/screenshots/asc_out/` (five iPhone, five iPad,
four Mac screenshots).

## Live release records

- App: `Tescam`; App Store app ID `6787877132`
- Bundle ID, both platforms: `com.magrathean.teslacam`
- Version `1.1`, build `9`, archived from the commit tagged `v1.1.0`
- Copyright: `2026 MAGRATHEAN UK LTD`
- Release mode: `AFTER_APPROVAL` (automatic)
- Export compliance: `usesNonExemptEncryption = false` on both builds (set with `asc builds update`)
- Submitted 26 Nov 2026 07:31 (iOS) and 07:32 GMT (macOS); both versions `WAITING_FOR_REVIEW`

| | iOS and iPadOS | macOS |
| --- | --- | --- |
| Version ID | `1facd222-3521-4c51-9868-37c822905189` | `2ffb985d-5e23-43e4-98ed-93f979e19ac7` |
| Build ID (state `VALID`) | `7758673c-fa71-4066-8c53-cd80a3cbc619` | `370a2af8-9b72-4c13-a986-c944d917fc8f` |
| Localization ID (`en-GB`) | `0a41ac9e-04dd-431c-98dd-77f672b28fde` | `ef2458ff-ae45-4f4a-a3c6-c91121a317bd` |
| Review detail ID | `d4d1ed0d-bac1-43d4-9727-a65b9c6f7b67` | `94905552-6855-4bda-a08d-ca3e3d4855e2` |
| Review submission ID | `a4c29f72-7948-4322-8542-21c8a59a750f` | `81a441aa-caac-4b5b-994b-18bb7fce9d04` |

macOS: the pending 1.0.1 review submission (`13fef9bc-6c13-42b5-aff0-9cc9df83db8e`, version
`2ffb985d-...`) was withdrawn (state `DEVELOPER_REJECTED`, then `PREPARE_FOR_SUBMISSION`), the same
version's string was changed to `1.1`, build 9 attached and resubmitted. The 1.0.1 macOS build 8
(`c8f3f561-6da6-4c51-96bf-a3f552839c7f`) was never released.

1.0.1 records (iOS, live): version `9bf33eac-9941-4bd6-944b-ea9701e09cc3`, build 8
`0f6fa10d-ce57-4f88-88a9-6d4cfab5de8f`, submission `33ecd619-d6e5-4a83-bf7d-9654643bf231`.
1.0 records: iOS version `1c9b09c1-b884-44f1-a59c-4478cfec2fac`, build 7
`2020ba75-a2e3-4e7f-8326-44da86df8754`; macOS version `e2e1a2f1-2fb5-4774-a05a-c982d511769d`, build 7
`76ee58c0-b679-4ac3-b55a-3455dc148307`. Empty `READY_FOR_REVIEW` draft submissions
(`42e15b24-2f04-48b5-a77d-d181be283188`, `3fb157af-fd3e-4f83-bfab-c1718c005b2a` iOS,
`d08baf0d-9dd2-481a-bedd-a64eeacc322a` macOS) were left alone.

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
- What's New (1.1): `New: Evidence files. Turn it on in export options to save, next to each export, a manifest with SHA-256 fingerprints of the source clips and the exported video, plus the telemetry as CSV and GPX when the recording has it. Useful when you hand footage to an insurer or the police.`

## Store copy

### iPhone and iPad

Promotional text:

```text
Review multi-camera dashcam footage, trim the useful range and export evidence clips locally on iPhone and iPad.
```

Description:

```text
Tescam is a local viewer and exporter for multi-camera car dashcam recordings on iPhone and iPad. Choose a recordings folder, review up to six synchronised camera angles on one timeline, trim the useful range, pick the cameras you need, and export clear evidence clips in H.265 (HEVC) or H.264.

Built for local review: timeline scrubbing, synchronised playback, camera selection, precise export ranges, duplicate-aware scanning, and optional telemetry engraving when the recording contains it. Optional evidence files add SHA-256 fingerprints and telemetry CSV/GPX to each export.

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

Built for local review: timeline scrubbing, synchronised playback, camera selection, precise export ranges, duplicate-aware scanning, and optional telemetry engraving when the recording contains it. Optional evidence files add SHA-256 fingerprints and telemetry CSV/GPX to each export.

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
VERSION=1.1

/opt/homebrew/bin/asc builds list --app "$APP_ID" --version "$VERSION" --build-number 9 --processing-state all
/opt/homebrew/bin/asc versions view --version-id 1facd222-3521-4c51-9868-37c822905189 --include-build --include-submission
/opt/homebrew/bin/asc versions view --version-id 2ffb985d-5e23-43e4-98ed-93f979e19ac7 --include-build --include-submission
/opt/homebrew/bin/asc localizations list --version 1facd222-3521-4c51-9868-37c822905189 --include appScreenshotSets
/opt/homebrew/bin/asc localizations list --version 2ffb985d-5e23-43e4-98ed-93f979e19ac7 --include appScreenshotSets
/opt/homebrew/bin/asc review submissions-list --app "$APP_ID"
```

Do not release from this handoff. Both 1.1 versions are already submitted and
waiting for review. The canonical ASC validation reported zero blocking errors;
it retained only keyword warnings and the App Privacy publication check that
the public API cannot verify. App Privacy publication remains a manual ASC
check because the public API does not expose its publish state.
