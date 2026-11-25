# Evidence files

An opt-in export option, "Evidence files" (macOS, iPhone and iPad). It is saved in user defaults (`tescam.exportEvidenceFiles`) and is off by default. With it off, the export is unchanged. It is not applied to preview samples.

When on, each export also writes these files next to the video, named after the full video file name (`clip.mp4` gives `clip.mp4.manifest.json`, `clip.mp4.telemetry.csv`, `clip.mp4.gpx`), so `clip.mov` and `clip.mp4` never share companions. Code: `Tescam/EvidenceFiles.swift`; the step runs in `NativeExportController.completeExport` after the video is final.

## Where the files go
- macOS: the sandbox grants only the URL the save panel returns, so with Evidence files on the panel ("Save Export Folder") names an export folder instead. The app creates that folder and writes the video and its evidence files inside it. With the option off the panel and flow are unchanged. Reveal in Finder selects the video and the evidence files.
- iPhone/iPad: the same export scratch folder; the share sheet ("Reveal") offers the video and the evidence files together, so the user saves them wherever they like. There is no Photos save in the current flow.

## `<name>.manifest.json`
Sorted keys, two-space indent, trailing newline. Only `exported_at` differs between two exports of the same inputs. Times are UTC ISO 8601.

| Key | Content |
| --- | --- |
| `manifest_version` | `1` |
| `app` | `name`, `version`, `build` |
| `exported_at` | export time, whole seconds |
| `time_basis` | `assumed_time_zone` (identifier), `utc_offset_at_range_start`, `source`. Dashcam file names hold local wall-clock time, so every UTC value is derived from the assumed zone (the Mac's zone when the footage was indexed), not recorded by the camera |
| `range` | `start_utc`, `end_utc`, `start_local`, `end_local` (with offset), `duration_seconds`, `trim_start_seconds`, `trim_end_seconds`, `description` |
| `cameras` | cameras enabled for the export, sorted |
| `export` | `preset`, `preset_name`, `codec` (`hevc`, `h264`, `prores_422_hq`, `passthrough`), `layout`, `six_camera_grid`, `canvas` (`width`, `height`), `camera_cuts`, `overlays` (HUD, route map, privacy mask, report, screenshot) |
| `source_clips` | per clip the export actually read or inserted (recorded by the renderer and the muxer, not taken from the request: a clip skipped by the trim is absent, an extra muxed track is present), sorted by path: `path` relative to the chosen recordings folder (the bare file name if it is outside every chosen folder), `camera`, `clip_start_utc`, `clip_start_local`, `bytes`, `sha256` |
| `telemetry` | `samples`, `estimated_time_samples`, `timing` (`none`, `exact`, `estimated`, `mixed`), `source_clips` (same fields as above) for the clips the telemetry was read from, which may be outside the exported cameras (for example front-camera SEI on a rear-only export) |
| `output` | `name`, `bytes`, `sha256` of the video |
| `companion_files` | `kind` (`telemetry_csv`, `gpx`), `name`, `bytes`, `sha256` of each file written; the manifest itself is not listed |

## `<name>.telemetry.csv`
Written only when the exported range has telemetry. UTF-8, CRLF line endings, header row, RFC 4180 quoting, `.` as the decimal separator whatever the locale, an empty cell for a missing or non-finite value. One row per telemetry sample in the range:

`timestamp_utc, speed_kmh, autopilot_state, accelerator_pedal_percent, brake_applied, steering_angle_deg, heading_deg, latitude, longitude, timestamp_local, time_estimated`

`timestamp_utc` is derived from the assumed time zone in the manifest; `timestamp_local` is the same instant with that zone's offset. `time_estimated` is `1` when the clip had no per-sample timing and the parser spaced samples at a nominal frame interval, so the time is an estimate (clips with a normal sample table give real per-sample times, `0`).

`autopilot_state` is `none`, `self_driving`, `autosteer` or `tacc`; `brake_applied` is `1` or `0`. Latitude and longitude are empty when the position is unusable (null island, out of range, NaN).

## `<name>.gpx`
Written only when at least one sample has a usable position. GPX 1.1, one track and segment, one `trkpt` per positioned sample with `time`. Speed (m/s) and heading are in the Garmin TrackPointExtension v2 (`gpxtpx:speed`, `gpxtpx:course`; namespace and schema declared), since GPX 1.1 itself has no speed element and those elements first appear in v2. Latitude is clamped to [-90, 90] and longitude to [-180, 180); 180 is written as -180 (the same meridian), as GPX requires.

## Behaviour
- Before rendering starts, every candidate source clip (enabled cameras, plus the clips telemetry is read from) is hashed once by streaming (SHA-256, 1 MiB chunks) under "Fingerprinting source clips", and its size and modification date are recorded. After the export the video is hashed and the clips are re-checked: if any used clip's size or modification date changed, the evidence step fails with a clear error and the video is kept. Clips are not hashed twice.
- The CSV and GPX are streamed row by row (one clip's samples in memory at a time) to hidden temp files next to the final names, hashed as they are written. Temp files move into place only after the sources check and a cancellation check, the manifest last, so a failed run never deletes or half-replaces an earlier run's files. Progress runs from 98% to 100% under "Writing evidence files".
- Privacy mode or the privacy mask on: the manifest is still written, but no CSV or GPX, so no position or telemetry leaves the app.
- Failure: the video is kept. Evidence files already written by that run are removed, and the job completes with a message naming the failed file (shown in the export status). Cancelling during this step, including after the manifest is written, keeps the video, removes this run's evidence files and posts a cancelled state.
