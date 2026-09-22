# Tescam Domain Contract

This contract pins the behavior that must stay aligned between the native macOS app and the Python CLI. The app remains the shipping macOS export path. The CLI remains portable and dependency-light.

## Camera vocabulary

The canonical camera values, in canonical render order, are:

```text
front, back, left_repeater, right_repeater, left, right, left_pillar, right_pillar
```

Camera tokens parsed from filenames are lowercased, hyphens converted to underscores, repeated underscores collapsed, and trailing numeric suffixes removed. After normalization, accepted aliases are: `fwd` / `forward` → `front`; `rear` / `rear_camera` → `back`; `left_rear` → `left_repeater`; `right_rear` → `right_repeater`. Tokens containing both a side word and `pillar` map to the pillar camera on that side; tokens containing both a side word and `repeat` map to the repeater on that side. Tokens that do not normalize to one of the canonical values are ignored.

## Clip file discovery

Source inputs are treated as untrusted media trees. Recursive scans consider regular `.mp4` and `.mov` files whose basename matches:

```text
YYYY-MM-DD_HH-MM-SS-CAMERA.(mp4|mov)
```

The timestamp is parsed with `yyyy-MM-dd_HH-mm-ss` / `%Y-%m-%d_%H-%M-%S` in the local timezone used by the process. The `CAMERA` token is normalized using the rules in **Camera vocabulary** above. Files with malformed timestamps, unknown camera tokens, unsupported extensions, or hidden path components are ignored. Hidden path components are any relative path segment beginning with `.`.

## Duplicate policy

A duplicate file is a file with the same timestamp and normalized camera as another indexed file.

`merge-by-time` / `mergeByTime` produces one clip set per timestamp and keeps the lexicographically earliest path for duplicate timestamp-camera pairs.

`prefer-newest` / `preferNewest` produces one clip set per timestamp and keeps the file with the greatest modification time for duplicate timestamp-camera pairs. Modification-time ties fall back to the lexicographically earliest path.

`keep-all` / `keepAll` keeps the first timestamp set as the primary set. If a later file has a camera that is missing from the primary set, it is added to the primary set. If a later file duplicates an existing timestamp-camera pair, it creates an additional one-camera clip set for that duplicate file.

Duplicate timestamp count is the number of timestamps with at least one duplicate timestamp-camera pair, not the number of duplicate files.

## Clip grouping and sort order

Clip sets are sorted by start time, then timestamp string, then deterministic file paths. A clip set duration is the maximum duration among its cameras. If media probing cannot establish a duration, the app uses its native fallback and the CLI uses the scan-only manifest without probing.

## Layout selection

Layouts use the canonical camera order from **Camera vocabulary**. The three profiles are:

`legacy4` / forced 4-camera uses `front, back, left_repeater, right_repeater` in a two-by-two layout.

`sixcam` / forced 6-camera uses `front, back, left, right, left_pillar, right_pillar` in a two-by-three layout.

`auto` chooses the 6-camera layout when any of `left`, `right`, `left_pillar`, or `right_pillar` are present. Otherwise it chooses the 4-camera layout.

Layout plans expose a requested profile, expected cameras, render order, hidden cameras, canvas size, and cell rectangles. Missing expected cameras render as black placeholders. Present cameras outside the selected profile are listed as hidden cameras instead of silently changing the grid. For mixed HW3/HW4 inputs, `auto` uses the 6-camera layout and records classic repeater cameras as hidden.

Native preview/export can layer camera-track cuts over this base layout. A camera-track cut is a timeline second plus camera id; during native export, the latest cut at or before the render second focuses that camera full-frame. Without cuts, export uses the base grid layout above. The portable CLI does not currently apply camera-track cuts.

Native export presets are intent labels over native codecs: Original passthrough, Evidence HEVC, Fast Review HEVC, Social 25 MB HEVC, Proxy HEVC, and Master ProRes. The portable CLI exposes `evidence-hevc` as the app-style default plus its existing ffmpeg adapters (`lossless`, `quality`, `review`, `share`) unless a fixture explicitly expands the shared contract. Original passthrough muxing is native-only.

## Output naming and conflicts

Default CLI output names use:

```text
teslacam_MODE_START_to_END.mp4
```

where `START` and `END` are contract timestamps. A directory output argument receives the default filename. A non-`.mp4` CLI output path is normalized to `.mp4`.

Output conflicts are handled by policy:

`unique` appends `-2`, `-3`, and so on before the extension.

`overwrite` uses the requested path and lets the export path replace the file.

`error` fails before export work starts.

## Dry-run manifest

Dry-run manifests are JSON objects with `schema_version: 1`. They are intended for fixture parity checks and user-visible preflight output. They include scan summary, duplicate counts, selected range, selected clip sets, layout, dimensions, output path, duplicate policy, output conflict policy, and telemetry capability notes.

Telemetry notes are explicit because the app and CLI intentionally differ here: the native app can burn timestamp, speed, AP, pedal/brake, steering, heading, and route overlays into exports, while the dependency-light CLI does not inspect SEI metadata or render telemetry overlays.

Both Swift and Python implementations must keep the fixture cases under `fixtures/domain/cases` passing before domain behavior changes are accepted.

## Maintaining fixtures

Fixtures under `fixtures/domain/cases/*.json` are the source of truth.
Each fixture carries four expected blocks:

- `expected_scan` — keyed by every duplicate policy
  (`merge-by-time`, `prefer-newest`, `keep-all`); locks `scan_manifest`
  output minus the `schema_version` / `type` envelope
- `expected_layout` — keyed by every profile (`auto`, `legacy4`,
  `sixcam`); locks `layout_manifest` output for that profile
- `expected_selection` — keyed by every duplicate policy; locks
  `selected_sets_manifest` after running `select_clip_sets` over the
  scanned clip-sets with a stub probe (every clip = 60 s)
- `expected_output` — locks `apply_output_conflict_policy` against the
  default filename derived from the fixture's natural clip range:
  the three-step `unique` cascade, the `overwrite` resolution, and the
  typed `RuntimeError` raised by the `error` policy

Authoring a new fixture only requires a minimal skeleton:

```json
{
  "name": "my_fixture",
  "description": "...",
  "schema_version": 1,
  "files": [
    {"path": "SavedClips/2026-01-01_00-00-00-front.mp4"}
  ]
}
```

Drop it under `fixtures/domain/cases/` and run:

```bash
source .cache/build-env.sh && source .cache/venv/bin/activate
python3 script/regen_fixtures.py
python3 -m unittest tests.test_domain_contract
```

`script/regen_fixtures.py` is idempotent — running it on existing
fixtures produces no diff. Re-run it whenever the contract surfaces
change (`scan_manifest`, `layout_manifest`, `selected_sets_manifest`,
or `apply_output_conflict_policy`), then commit the regenerated
fixtures.

The matching parity tests are:

- `test_shared_scan_fixtures_match_python_manifest_for_all_duplicate_policies`
- `test_shared_layout_fixtures_round_trip_through_scan_then_layout_for_all_profiles`
- `test_shared_selection_fixtures_round_trip_through_select_clip_sets_for_all_duplicate_policies`
- `test_shared_output_fixtures_match_apply_output_conflict_policy_for_all_policies`

Native parity (Swift) currently covers scan and layout via
`sharedDomainFixturesMatchNativeScanManifestsForAllDuplicatePolicies`
and `sharedLayoutFixturesMatchNativeLayoutPlan`. Selection and output
Swift parity tests are unblocked by the `expected_selection` /
`expected_output` blocks; see plan note 01 step 3.

## Implementation ownership

Python owns the portable CLI scan, plan, and ffmpeg render adapters. Swift owns the native app scan, timeline, preview, preflight, and native export path. Shared fixtures are the source of truth when behavior overlaps.
