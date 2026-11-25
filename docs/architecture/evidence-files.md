# Evidence files

An opt-in export option, "Evidence files" (macOS, iPhone and iPad). It is saved in user defaults (`tescam.exportEvidenceFiles`) and is off by default. With it off, the export is unchanged. It is not applied to preview samples.

When on, each export also writes these files next to the video, named after it (`clip.mp4` gives `clip.manifest.json`, `clip.telemetry.csv`, `clip.gpx`). Code: `Tescam/EvidenceFiles.swift`; the step runs in `NativeExportController.completeExport` after the video is final.

## Where the files go
- macOS: the same folder as the video. Reveal in Finder selects the video and the evidence files.
- iPhone/iPad: the same export scratch folder; the share sheet ("Reveal") offers the video and the evidence files together, so the user saves them wherever they like. There is no Photos save in the current flow.

## `<name>.manifest.json`
Sorted keys, two-space indent, trailing newline. Only `exported_at` differs between two exports of the same inputs. Times are UTC ISO 8601.

| Key | Content |
| --- | --- |
| `manifest_version` | `1` |
| `app` | `name`, `version`, `build` |
| `exported_at` | export time, whole seconds |
| `range` | `start_utc`, `end_utc`, `duration_seconds`, `trim_start_seconds`, `trim_end_seconds`, `description` |
| `cameras` | enabled cameras, sorted |
| `export` | `preset`, `preset_name`, `codec` (`hevc`, `h264`, `prores_422_hq`, `passthrough`), `layout`, `six_camera_grid`, `canvas` (`width`, `height`), `camera_cuts`, `overlays` (HUD, route map, privacy mask, report, screenshot) |
| `source_clips` | per clip used (enabled cameras only), sorted by path: `path` relative to the chosen recordings folder (the bare file name if it is outside every chosen folder), `camera`, `clip_start_utc`, `bytes`, `sha256` |
| `output` | `name`, `bytes`, `sha256` of the video |
| `companion_files` | `kind` (`telemetry_csv`, `gpx`), `name`, `bytes`, `sha256` of each file written; the manifest itself is not listed |

## `<name>.telemetry.csv`
Written only when the exported range has telemetry. UTF-8, CRLF line endings, header row, RFC 4180 quoting, `.` as the decimal separator whatever the locale, an empty cell for a missing or non-finite value. One row per telemetry sample in the range:

`timestamp_utc, speed_kmh, autopilot_state, accelerator_pedal_percent, brake_applied, steering_angle_deg, heading_deg, latitude, longitude`

`autopilot_state` is `none`, `self_driving`, `autosteer` or `tacc`; `brake_applied` is `1` or `0`. Latitude and longitude are empty when the position is unusable (null island, out of range, NaN).

## `<name>.gpx`
Written only when at least one sample has a usable position. GPX 1.1, one track and segment, one `trkpt` per positioned sample with `time`. Speed (m/s) and heading are in the Garmin TrackPointExtension v1 (`gpxtpx:speed`, `gpxtpx:course`), since GPX 1.1 itself has no speed element.

## Behaviour
- Source clips and the video are hashed by streaming (SHA-256, 1 MiB chunks) on the export thread; nothing large is held in memory. Progress runs from 98% to 100% under "Writing evidence files".
- Privacy mode or the privacy mask on: the manifest is still written, but no CSV or GPX, so no position or telemetry leaves the app.
- Failure: the video is kept. Evidence files already written by that run are removed, and the job completes with a message naming the failed file (shown in the export status). Cancelling during this step keeps the video and removes the evidence files.
