# Tescam — Current App Store Connect Release

This is the maintained handoff for the live App Store Connect 1.0 train. Read
the identifiers back from ASC before any future mutation because version,
build, localization, screenshot-set, and review-submission IDs are
environment-specific.

## Release summary

Tescam 1.0 is the first App Store release. It provides local multi-camera dashcam
review, synchronized multi-camera playback, timeline range selection, camera selection,
telemetry-aware workflows, and native evidence export on iPhone, iPad, and Mac. Store assets
are under `marketing/screenshots/asc_out/`: five iPhone screenshots, five iPad screenshots,
and four distinct Mac screenshots (a fifth Mac capture duplicated another and was not
uploaded). The upload and review manifests are `marketing/screenshots/asc_out/asc_upload.json`
and `asc_review.json`.

## Live release records

- App: `Tescam`
- App Store app ID: `6787877132`
- Bundle ID, both platforms: `com.magrathean.teslacam`
- Version: `1.0`
- Build: `7`
- Copyright: `2026 MAGRATHEAN UK LTD`
- Release mode: manual; build 7 resubmitted on both platforms on 1 October 2026

### iOS and iPadOS

- Version ID: `1c9b09c1-b884-44f1-a59c-4478cfec2fac`
- Version localization ID (`en-GB`): `0366f1e5-30f8-40ee-aff0-b30adb73c320`
- Build ID: `2020ba75-a2e3-4e7f-8326-44da86df8754`
- Processing state: `VALID`
- Review detail ID: `3d6e2284-a5b7-423f-9446-a54c10b257d0`
- Review submission ID: `c1ebf203-c395-49d4-8176-23a51101297f`
- Resolution Center thread: `159347d8-7928-3fd1-8c75-524661924e32`

### macOS

- Version ID: `e2e1a2f1-2fb5-4774-a05a-c982d511769d`
- Version localization ID (`en-GB`): `74075979-ed03-4bd6-a50f-8e0209bf2980`
- Build ID: `76ee58c0-b679-4ac3-b55a-3455dc148307`
- Processing state: `VALID`
- Review submission ID: `be6e0fd2-844b-4627-9457-2c5dcce9882f`
- Resolution Center thread: `5e6b24f0-e1fa-3d1f-bb66-0a1d332a0d4b`
- Review detail ID: `c98e7890-eb7a-4995-b39f-41d92d2f0bdc`

### Shared App Info

- App Info localization ID (`en-GB`): `5fbbaa15-3dca-4bdb-8f7b-11d9f2e4ef17`
- Name: `Tescam`
- Subtitle: `Local dashcam video editor`
- Age-rating declaration: `socialMedia = false` and
  `socialMediaAgeRestricted = false`; all other stored answers remain the
  existing no-objectionable-content values

## Review response and submission

Build 6 was rejected on both platforms over Tesla branding. On macOS, Guideline
4.1(c) cited the subtitle. On iOS, 4.1(a) and then 5.2.1 cited the metadata and
the app's content. Build 7 removes third-party brand and feature names from
user-visible app text: onboarding, folder picker, telemetry and export overlays,
and document type name. Telemetry assist states now read Off, Self-driving,
Steering and Cruise. Build 7 also removes them from all store metadata and
screenshots on both platforms. Store copy, keywords and screenshots must not
name a vehicle maker or its features. Compatibility can be explained only in
the private App Review notes.

Build 7 is signed with team `NPSQV9WYS5` using the Apple Distribution
certificate `U86DTAL3L2`, the Mac Installer certificate `HK9WGD3A83`, and the
`Tescam 20261001 IOS_APP_STORE` and `Tescam 20261001 MAC_APP_STORE` profiles,
all created on 1 October 2026. Signing material stays outside the repository.
Both build 7 records declare `usesNonExemptEncryption = false`.

## Live URLs

- Marketing: `https://magrathean.uk/solutions/tescam/`
- Support: `https://magrathean.uk/solutions/tescam/`
- Privacy policy: `https://magrathean.uk/solutions/tescam/privacy/`
- Terms: `https://magrathean.uk/solutions/tescam/terms/`
- Review contact: `contact+tescam@magrathean.uk`
- EULA: Apple standard EULA; no custom ASC EULA is configured

The marketing and support URLs are stored on both platform localizations. The
privacy-policy URL is stored on the shared App Info localization. ASC has no
separate terms-URL field when the standard Apple EULA is used.

The matching website is live from Magrathean `main` at commit `d68e6440`, with
iPhone, iPad, and Mac routes and platform-specific screenshot assets. Cloudflare
deployment run `35693409557` completed successfully.

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
VERSION=1.0

/opt/homebrew/bin/asc builds list --app "$APP_ID" --version "$VERSION" --build-number 6 --processing-state all
/opt/homebrew/bin/asc versions view --version-id 1c9b09c1-b884-44f1-a59c-4478cfec2fac --include-build --include-submission
/opt/homebrew/bin/asc versions view --version-id e2e1a2f1-2fb5-4774-a05a-c982d511769d --include-build --include-submission
/opt/homebrew/bin/asc localizations list --version 1c9b09c1-b884-44f1-a59c-4478cfec2fac --include appScreenshotSets
/opt/homebrew/bin/asc localizations list --version e2e1a2f1-2fb5-4774-a05a-c982d511769d --include appScreenshotSets
/opt/homebrew/bin/asc review submissions-list --app "$APP_ID"
```

Do not release from this handoff. Both versions are already submitted and
waiting for review. The canonical ASC validation reported zero blocking errors;
it retained only keyword warnings and the App Privacy publication check that
the public API cannot verify. App Privacy publication remains a manual ASC
check because the public API does not expose its publish state.
