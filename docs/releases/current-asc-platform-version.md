# Tescam — Current App Store Connect Release

This is the maintained handoff for the live App Store Connect 1.0 train. Read
the identifiers back from ASC before any future mutation because version,
build, localization, screenshot-set, and review-submission IDs are
environment-specific.

## Live release records

- App: `Tescam`
- App Store app ID: `6787877132`
- Bundle ID, both platforms: `com.magrathean.teslacam`
- Version: `1.0`
- Build: `6`
- Copyright: `2026 Magrathean UK Ltd.`
- Release mode: manual; both platform submissions are waiting for review

### iOS and iPadOS

- Version ID: `1c9b09c1-b884-44f1-a59c-4478cfec2fac`
- Version localization ID (`en-GB`): `0366f1e5-30f8-40ee-aff0-b30adb73c320`
- Build ID: `1c78a2d9-1d6e-4480-9608-43b636ed078c`
- Processing state: `VALID`
- Version state: `WAITING_FOR_REVIEW`
- Review submission ID: `c1ebf203-c395-49d4-8176-23a51101297f`

### macOS

- Version ID: `e2e1a2f1-2fb5-4774-a05a-c982d511769d`
- Version localization ID (`en-GB`): `74075979-ed03-4bd6-a50f-8e0209bf2980`
- Build ID: `e8f0627d-dc3a-47bd-95cf-c3a469fb7f6c`
- Processing state: `VALID`
- Version state: `WAITING_FOR_REVIEW`
- Review submission ID: `be6e0fd2-844b-4627-9457-2c5dcce9882f`
- Review detail ID: `c98e7890-eb7a-4995-b39f-41d92d2f0bdc`

### Shared App Info

- App Info localization ID (`en-GB`): `5fbbaa15-3dca-4bdb-8f7b-11d9f2e4ef17`
- Name: `Tescam`
- Subtitle: `Review TeslaCam footage`
- Age-rating declaration: `socialMedia = false` and
  `socialMediaAgeRestricted = false`; all other stored answers remain the
  existing no-objectionable-content values

## Review response and submission

The build 5 iOS submission `6f62d392-3197-4ee4-9883-f2c074bb64de` and macOS
submission `96b9ef23-e543-44ac-9654-07ebd2988654` were cancelled so the same
1.0 versions could be attached to renamed build 6. The new submissions are
both `WAITING_FOR_REVIEW`.

The App Review notes for both platforms now explain that Tescam is an
independent local file utility, contains no Tesla-owned artwork or media, does
not access Tesla accounts or APIs, and uses “TeslaCam” only as a compatibility
reference. They link to the public source and support site, state that no Tesla
authorization or licence is claimed, and ask App Review to identify any exact
metadata or asset it considers misleading.

## Live URLs

- Marketing: `https://teslacam.eu/`
- Support: `https://teslacam.eu/#support`
- Privacy policy: `https://teslacam.eu/privacy/`
- Terms: `https://teslacam.eu/terms/`
- EULA: Apple standard EULA; no custom ASC EULA is configured

The marketing and support URLs are stored on both platform localizations. The
privacy-policy URL is stored on the shared App Info localization. ASC has no
separate terms-URL field when the standard Apple EULA is used.

The matching website is live from Magrathean `main` at commit `6f611fd9`, with
iPhone, iPad, and Mac routes and platform-specific screenshot assets. Cloudflare
deployment run `34770584560` completed successfully.

## Store copy

### iPhone and iPad

Promotional text:

```text
Review TeslaCam footage, trim the useful range, and export evidence clips locally on iPhone and iPad.
```

Description:

```text
Tescam helps Tesla owners review TeslaCam and Sentry Mode footage on iPhone and iPad. Load a camera folder, inspect the six-camera timeline, trim the useful range, choose the cameras you need, and export clear evidence clips with native HEVC.

The app is built for local review workflows: timeline scrubbing, camera selection, export range controls, duplicate-aware scanning, and telemetry engraving options where supported by the source footage.

Tescam processes user-selected recordings on device. You stay responsible for collecting, retaining, and sharing footage lawfully.
```

### Mac

Promotional text:

```text
Review TeslaCam footage, trim the useful range, and export evidence clips locally on your Mac.
```

Description:

```text
Tescam helps Tesla owners review TeslaCam and Sentry Mode footage on Mac. Load a camera folder, inspect the six-camera timeline, trim the useful range, choose the cameras you need, and export clear evidence clips with native HEVC.

The app is built for local review workflows: timeline scrubbing, synchronized camera playback, camera selection, export range controls, duplicate-aware scanning, and telemetry engraving options where supported by the source footage.

Tescam processes user-selected recordings on your Mac. You stay responsible for collecting, retaining, and sharing footage lawfully.
```

Keywords on both platforms:

```text
tescam,dashcam,tesla,sentry,video,export,evidence,hevc,car,camera
```

## Screenshots

The checked-in upload assets are under `marketing/screenshots/asc_out/` and
contain five distinct images for each mobile family and four for Mac:

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
