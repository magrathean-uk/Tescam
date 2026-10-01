from __future__ import annotations

import argparse
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

from .composer import (
    RenderConcatStarted,
    RenderEvent,
    RenderPartStarted,
    RenderReporter,
    RenderStarted,
    RenderUnreadableClips,
    clip_set_duration,
    compose,
    prepare_workdir,
    probe_dimensions_for_selection,
    probe_selection_fps,
    select_clip_sets,
)
from .domain_contract import dry_run_manifest, write_manifest_json
from .events import CamEvent, scan_events
from .ffmpeg_tools import FfmpegRunner, MediaProbe, ToolResolutionError, resolve_tools
from .layouts import PROFILE_LABELS, build_camera_layout_plan, fill_missing_dimensions
from .models import (
    Camera,
    ComposePlan,
    Dimensions,
    DuplicatePolicy,
    EncoderPlan,
    LayoutSpec,
    OutputConflictPolicy,
    ScanResult,
    SelectedSet,
)
from .probe_cache import RunProbeCache
from .scanner import cameras_in_sets, format_clip_timestamp, scan_source


@dataclass(frozen=True)
class RunOptions:
    source_dir: Path
    output_arg: Optional[str]
    start_arg: Optional[str]
    end_arg: Optional[str]
    profile: str
    mode: str
    ffmpeg: Path
    ffprobe: Path
    workdir_arg: Optional[Path]
    keep_workdir: bool
    x265_preset: str
    loglevel: str
    duplicate_policy: DuplicatePolicy
    output_conflict: OutputConflictPolicy


@dataclass(frozen=True)
class RunPlan:
    source_dir: Path
    output_file: Path
    start_time: datetime
    end_time: datetime
    profile: str
    mode: str
    ffmpeg: Path
    ffprobe: Path
    workdir_arg: Optional[Path]
    keep_workdir: bool
    x265_preset: str
    loglevel: str
    duplicate_policy: DuplicatePolicy
    output_conflict: OutputConflictPolicy
    scan_result: ScanResult
    selected_sets: list[SelectedSet]
    layout: LayoutSpec
    dimensions: dict[Camera, Dimensions]
    fps: float
    encoder: EncoderPlan

    def to_compose_plan(
        self,
        workdir: Path,
        media_probe: MediaProbe,
        ffmpeg_runner: Optional[FfmpegRunner] = None,
        render_reporter: Optional[RenderReporter] = None,
    ) -> ComposePlan:
        return ComposePlan(
            source_dir=self.source_dir,
            output_file=self.output_file,
            ffmpeg=self.ffmpeg,
            ffprobe=self.ffprobe,
            layout=self.layout,
            fps=self.fps,
            encoder=self.encoder,
            selected_sets=self.selected_sets,
            dimensions_by_camera=self.dimensions,
            workdir=workdir,
            keep_workdir=self.keep_workdir,
            loglevel=self.loglevel,
            media_probe=media_probe,
            ffmpeg_runner=ffmpeg_runner,
            render_reporter=render_reporter,
        )

    def dry_run_manifest(self) -> dict:
        return dry_run_manifest(
            source_dir=self.source_dir,
            output_file=self.output_file,
            start_time=self.start_time,
            end_time=self.end_time,
            profile=self.profile,
            mode=self.mode,
            duplicate_policy=self.duplicate_policy,
            output_conflict=self.output_conflict,
            scan_result=self.scan_result,
            selected_sets=self.selected_sets,
            layout=self.layout,
            dimensions=self.dimensions,
            fps=self.fps,
            encoder_label=self.encoder.label,
        )


class RunPlanBuilder:
    def __init__(self, media_probe: Optional[MediaProbe] = None) -> None:
        self.media_probe = media_probe or MediaProbe()

    def build(self, options: RunOptions) -> RunPlan:
        scan_result = scan_source(options.source_dir, duplicate_policy=options.duplicate_policy)
        start_default, end_default = dataset_range(scan_result.clip_sets, options.ffprobe, self.media_probe)
        start_time = parse_user_datetime(options.start_arg) if options.start_arg else start_default
        end_time = parse_user_datetime(options.end_arg) if options.end_arg else end_default
        if end_time <= start_time:
            raise RuntimeError("End time must be after start time.")

        output_file = resolve_output_path(
            options.source_dir,
            options.output_arg,
            options.mode,
            start_time,
            end_time,
            output_conflict=options.output_conflict,
        )
        selected_sets = select_clip_sets(
            scan_result.clip_sets,
            start_time,
            end_time,
            options.ffprobe,
            media_probe=self.media_probe,
        )
        if not selected_sets:
            raise RuntimeError("No clips overlap the requested time range.")

        available_cameras = cameras_in_sets(selected_sets_to_clip_sets(selected_sets))
        probed_dimensions = probe_dimensions_for_selection(
            options.ffprobe,
            selected_sets,
            media_probe=self.media_probe,
        )
        layout = build_camera_layout_plan(options.profile, available_cameras, probed_dimensions)
        dimensions = fill_missing_dimensions(layout.kind, probed_dimensions)
        fps = probe_selection_fps(options.ffprobe, selected_sets, media_probe=self.media_probe)
        encoder = self.media_probe.choose_encoder(options.ffmpeg, options.mode, options.x265_preset)

        return RunPlan(
            source_dir=options.source_dir,
            output_file=output_file,
            start_time=start_time,
            end_time=end_time,
            profile=options.profile,
            mode=options.mode,
            ffmpeg=options.ffmpeg,
            ffprobe=options.ffprobe,
            workdir_arg=options.workdir_arg,
            keep_workdir=options.keep_workdir or options.workdir_arg is not None,
            x265_preset=options.x265_preset,
            loglevel=options.loglevel,
            duplicate_policy=options.duplicate_policy,
            output_conflict=options.output_conflict,
            scan_result=scan_result,
            selected_sets=selected_sets,
            layout=layout,
            dimensions=dimensions,
            fps=fps,
            encoder=encoder,
        )


class CliPresenter:
    def print_plan(self, plan: RunPlan) -> None:
        print_summary(
            source_dir=plan.source_dir,
            output_file=plan.output_file,
            start_time=plan.start_time,
            end_time=plan.end_time,
            layout=plan.layout.kind.value,
            mode=plan.encoder.label,
            camera_dimensions=plan.dimensions,
            sets=len(plan.selected_sets),
            duplicate_policy=plan.duplicate_policy,
            duplicate_file_count=plan.scan_result.duplicate_file_count,
            duplicate_timestamp_count=plan.scan_result.duplicate_timestamp_count,
        )

    def print_done(self, output: Path, workdir: Path, keep_workdir: bool) -> None:
        print(f"Done: {output}")
        if keep_workdir:
            print(f"Workdir kept: {workdir}")

    def handle_render_event(self, event: RenderEvent) -> None:
        if isinstance(event, RenderStarted):
            print(f"Using ffmpeg: {event.ffmpeg}")
            print(f"Using ffprobe: {event.ffprobe}")
            print(
                f"Canvas: {event.canvas_width}x{event.canvas_height} | "
                f"Layout: {event.layout} | FPS: {event.fps:.3f} | Mode: {event.mode}"
            )
            print(f"Clip sets selected: {event.selected_count}")
        elif isinstance(event, RenderUnreadableClips):
            print(f"Warning: {len(event.paths)} unreadable or missing clip(s) will render as black placeholders.")
            for clip_path in event.paths[:5]:
                print(f"  - {clip_path}")
            if len(event.paths) > 5:
                print(f"  ... {len(event.paths) - 5} more")
        elif isinstance(event, RenderPartStarted):
            print(
                f"[{event.index}/{event.total}] {event.timestamp} "
                f"trim {event.trim_start:.3f}s -> {event.trim_end:.3f}s"
            )
        elif isinstance(event, RenderConcatStarted):
            print("Concatenating final MP4...")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="tescam-cli",
        description="Cross-platform Tescam CLI composer. Default output: Evidence HEVC MP4.",
    )
    parser.add_argument("source", nargs="?", help="Tescam source folder")
    parser.add_argument("-o", "--output", help="Output MP4 path or output directory")
    parser.add_argument("--start", help="Start time. Accepts DD/MM/YYYY-HH:MM:SS, YYYY-MM-DD HH:MM:SS, YYYY-MM-DD_HH-MM-SS")
    parser.add_argument("--end", help="End time. Accepts DD/MM/YYYY-HH:MM:SS, YYYY-MM-DD HH:MM:SS, YYYY-MM-DD_HH-MM-SS")
    parser.add_argument(
        "--profile",
        choices=sorted(PROFILE_LABELS.keys()),
        default="auto",
        help="Car/layout profile. Auto uses clip detection. legacy4 forces 4-camera. sixcam forces 6-camera.",
    )
    parser.add_argument(
        "--mode",
        choices=["evidence-hevc", "lossless", "quality", "review", "share"],
        default="evidence-hevc",
        help=(
            "evidence-hevc = app-style evidence export, x265 CRF 6. "
            "lossless = x265 lossless HEVC (archival, very large). "
            "quality = legacy alias for evidence-hevc. "
            "review = near-source quality at a fraction of the size "
            "(VideoToolbox or x265 CRF 23). "
            "share = small, messageable files (VideoToolbox or x265 CRF 28)."
        ),
    )
    parser.add_argument(
        "--duplicate-policy",
        choices=[policy.value for policy in DuplicatePolicy],
        default=DuplicatePolicy.MERGE_BY_TIME.value,
        help="How to handle duplicate clips that share the same timestamp and camera.",
    )
    parser.add_argument(
        "--output-conflict",
        choices=[policy.value for policy in OutputConflictPolicy],
        default=OutputConflictPolicy.UNIQUE.value,
        help="How to handle an output file that already exists.",
    )
    parser.add_argument("--x265-preset", default="medium", help="x265 preset for encode speed/compression ratio")
    parser.add_argument("--ffmpeg", help="Path to ffmpeg")
    parser.add_argument("--ffprobe", help="Path to ffprobe")
    parser.add_argument("--workdir", help="Working directory for intermediate parts")
    parser.add_argument("--keep-workdir", action="store_true", help="Keep intermediate files")
    parser.add_argument("--loglevel", default="info", help="ffmpeg loglevel (default: info)")
    parser.add_argument("--interactive", action="store_true", help="Force prompt mode even when arguments are supplied")
    parser.add_argument(
        "--list-events",
        action="store_true",
        help="List Sentry/Saved events (from event.json) and exit, without rendering.",
    )
    parser.add_argument(
        "--event",
        type=int,
        metavar="N",
        help="Export the Nth event from --list-events, as a window centred on its trigger moment.",
    )
    parser.add_argument(
        "--pre",
        type=float,
        default=30.0,
        help="Seconds of footage before the trigger moment when using --event (default: 30).",
    )
    parser.add_argument(
        "--post",
        type=float,
        default=30.0,
        help="Seconds of footage after the trigger moment when using --event (default: 30).",
    )
    parser.add_argument("--dry-run", action="store_true", help="Scan and print resolved plan without rendering")
    parser.add_argument(
        "--dry-run-json",
        nargs="?",
        const="-",
        metavar="PATH",
        help="Scan and emit the resolved dry-run manifest as JSON to stdout or PATH without rendering.",
    )
    return parser



def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        repo_root = Path(__file__).resolve().parent.parent
        interactive = args.interactive or args.source is None
        presenter = CliPresenter()
        media_probe = MediaProbe(probe_cache=RunProbeCache())
        ffmpeg, ffprobe = resolve_tools(repo_root, args.ffmpeg, args.ffprobe)
        duplicate_policy = DuplicatePolicy(args.duplicate_policy)
        output_conflict = OutputConflictPolicy(args.output_conflict)

        if args.list_events or args.event is not None:
            if args.source is None:
                raise RuntimeError("--list-events / --event require a source folder.")
            source_dir = Path(args.source).expanduser().resolve()
            events = scan_events(source_dir)
            if args.list_events:
                print_events_table(events)
                return 0
            event_start, event_end = resolve_event_window(events, args.event, args.pre, args.post)
            args.start = format_clip_timestamp(event_start)
            args.end = format_clip_timestamp(event_end)
            interactive = False

        if interactive:
            options = prompt_run_options(
                ffmpeg=ffmpeg,
                ffprobe=ffprobe,
                duplicate_policy=duplicate_policy,
                output_conflict=output_conflict,
                media_probe=media_probe,
            )
        else:
            options = RunOptions(
                source_dir=Path(args.source).expanduser().resolve(),
                output_arg=args.output,
                start_arg=args.start,
                end_arg=args.end,
                profile=args.profile,
                mode=args.mode,
                ffmpeg=ffmpeg,
                ffprobe=ffprobe,
                workdir_arg=Path(args.workdir).expanduser().resolve() if args.workdir else None,
                keep_workdir=args.keep_workdir,
                x265_preset=args.x265_preset,
                loglevel=args.loglevel,
                duplicate_policy=duplicate_policy,
                output_conflict=output_conflict,
            )

        plan = RunPlanBuilder(media_probe=media_probe).build(options)

        if args.dry_run_json is None:
            presenter.print_plan(plan)

        if args.dry_run or args.dry_run_json is not None:
            if args.dry_run_json is not None:
                manifest = plan.dry_run_manifest()
                write_manifest_json(manifest, args.dry_run_json)
            return 0

        workdir, _workdir_was_explicit = prepare_workdir(plan.workdir_arg)
        compose_plan = plan.to_compose_plan(workdir, media_probe, render_reporter=presenter)
        output = compose(compose_plan)
        presenter.print_done(output, workdir, plan.keep_workdir)
        if not plan.keep_workdir and workdir.exists():
            shutil.rmtree(workdir, ignore_errors=True)
        return 0
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130
    except (RuntimeError, FileNotFoundError, ToolResolutionError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1



def selected_sets_to_clip_sets(selected_sets):
    for selected in selected_sets:
        yield selected.clip_set


def print_events_table(events: list[CamEvent]) -> None:
    if not events:
        print("No Sentry/Saved events found (no event.json under SentryClips/ or SavedClips/).")
        return
    print(f"{len(events)} event(s):")
    print(f"  {'#':>3}  {'When':19}  {'Kind':6}  {'Reason':32}  Location")
    for index, event in enumerate(events, start=1):
        when = event.timestamp.strftime("%Y-%m-%d %H:%M:%S") if event.timestamp else "(no timestamp)"
        kind = "sentry" if event.category == "SentryClips" else "saved"
        reason = event.reason or "-"
        print(f"  {index:>3}  {when:19}  {kind:6}  {reason:32.32}  {event.location}")
    print("\nExport one with: tescam-cli <source> --event N -o <out.mp4>")


def resolve_event_window(
    events: list[CamEvent],
    index: int,
    pre_seconds: float,
    post_seconds: float,
) -> tuple[datetime, datetime]:
    """Resolve a 1-based --event index to a (start, end) window around its trigger."""
    if not events:
        raise RuntimeError("No Sentry/Saved events found to export.")
    if index < 1 or index > len(events):
        raise RuntimeError(f"--event {index} is out of range (1..{len(events)}). Use --list-events to see them.")
    event = events[index - 1]
    if event.timestamp is None:
        raise RuntimeError(
            f"Event {index} ({event.folder.name}) has no parseable trigger timestamp; cannot centre a window on it."
        )
    pre = max(0.0, pre_seconds)
    post = max(0.0, post_seconds)
    if pre + post <= 0.0:
        raise RuntimeError("--pre and --post cannot both be zero.")
    return (
        event.timestamp - timedelta(seconds=pre),
        event.timestamp + timedelta(seconds=post),
    )



def parse_user_datetime(value: str) -> datetime:
    candidates = [
        "%d/%m/%Y-%H:%M:%S",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d_%H-%M-%S",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M",
        "%Y-%m-%d %H:%M",
        "%d/%m/%Y-%H:%M",
    ]
    last_error = None
    for fmt in candidates:
        try:
            return datetime.strptime(value.strip(), fmt)
        except ValueError as exc:
            last_error = exc
    raise RuntimeError(
        "Could not parse datetime. Use DD/MM/YYYY-HH:MM:SS, YYYY-MM-DD HH:MM:SS, or YYYY-MM-DD_HH-MM-SS."
    ) from last_error



def dataset_range(
    clip_sets,
    ffprobe: Path,
    media_probe: Optional[MediaProbe] = None,
) -> tuple[datetime, datetime]:
    first = clip_sets[0]
    last = clip_sets[-1]
    last_duration = clip_set_duration(last, ffprobe, media_probe=media_probe)
    return first.start_time, last.start_time + timedelta(seconds=last_duration)



def default_output_filename(mode: str, start_time: datetime, end_time: datetime) -> str:
    start_label = format_clip_timestamp(start_time)
    end_label = format_clip_timestamp(end_time)
    return f"tescam_{mode}_{start_label}_to_{end_label}.mp4"



def resolve_output_path(
    source_dir: Path,
    output_arg: Optional[str],
    mode: str,
    start_time: datetime,
    end_time: datetime,
    output_conflict: OutputConflictPolicy = OutputConflictPolicy.UNIQUE,
) -> Path:
    if output_arg:
        raw_path = Path(output_arg).expanduser().resolve()
        if raw_path.exists() and raw_path.is_dir():
            path = raw_path / default_output_filename(mode, start_time, end_time)
        else:
            path = raw_path
        if path.suffix.lower() != ".mp4":
            path = path.with_suffix(".mp4")
        return apply_output_conflict_policy(path, output_conflict)
    output_dir = source_dir / "output"
    path = (output_dir / default_output_filename(mode, start_time, end_time)).resolve()
    return apply_output_conflict_policy(path, output_conflict)



def apply_output_conflict_policy(path: Path, policy: OutputConflictPolicy) -> Path:
    if not path.exists() or policy == OutputConflictPolicy.OVERWRITE:
        return path
    if policy == OutputConflictPolicy.ERROR:
        raise RuntimeError(f"Output file already exists: {path}")
    return unique_output_path(path)



def unique_output_path(path: Path) -> Path:
    if not path.exists():
        return path
    parent = path.parent
    stem = path.stem
    suffix = path.suffix
    for counter in range(2, 10_000):
        candidate = parent / f"{stem}-{counter}{suffix}"
        if not candidate.exists():
            return candidate
    raise RuntimeError(f"Could not find an available output filename next to: {path}")



def prompt_run_options(
    ffmpeg: Path,
    ffprobe: Path,
    duplicate_policy: DuplicatePolicy,
    output_conflict: OutputConflictPolicy,
    media_probe: MediaProbe,
) -> RunOptions:
    while True:
        raw_source = input("Tescam source folder: ").strip()
        if raw_source:
            source_dir = Path(raw_source).expanduser().resolve()
            if source_dir.exists() and source_dir.is_dir():
                break
        print("Invalid folder.")

    scan_result = scan_source(source_dir, duplicate_policy=duplicate_policy)
    clip_sets = scan_result.clip_sets
    start_default, end_default = dataset_range(clip_sets, ffprobe, media_probe)
    cameras = cameras_in_sets(clip_sets)
    print(
        f"Found {len(clip_sets)} clip sets | "
        f"Range: {start_default} -> {end_default} | "
        f"Cameras: {', '.join(camera.display_name for camera in sorted(cameras, key=lambda item: item.value))}"
    )
    if scan_result.has_conflicts:
        print(
            "Duplicates: "
            f"{scan_result.duplicate_file_count} file(s), "
            f"{scan_result.duplicate_timestamp_count} timestamp collision(s) | "
            f"Policy: {duplicate_policy.display_name}"
        )

    print("Car/layout profile:")
    print("  1) auto    - Auto-detect from clips")
    print("  2) legacy4 - Tesla legacy 4-camera layout")
    print("  3) sixcam  - Tesla 6-camera layout")
    profile = prompt_choice("Profile [auto]: ", default="auto", allowed={"auto", "legacy4", "sixcam", "1", "2", "3"})
    profile = {"1": "auto", "2": "legacy4", "3": "sixcam"}.get(profile, profile)

    start_time = prompt_datetime(
        prompt=f"Start [{start_default.strftime('%d/%m/%Y-%H:%M:%S')}]: ",
        default=start_default,
    )
    end_time = prompt_datetime(
        prompt=f"End   [{end_default.strftime('%d/%m/%Y-%H:%M:%S')}]: ",
        default=end_default,
    )

    print("Output mode:")
    print("  1) evidence-hevc - App-style Evidence HEVC, x265 CRF 6")
    print("  2) lossless      - H.265 MP4, x265 lossless, very large files")
    print("  3) review        - near-source quality, much smaller (VideoToolbox/x265 CRF 23)")
    print("  4) share         - small, messageable files (VideoToolbox/x265 CRF 28)")
    mode = prompt_choice(
        "Mode [evidence-hevc]: ",
        default="evidence-hevc",
        allowed={"evidence-hevc", "lossless", "quality", "review", "share", "1", "2", "3", "4"},
    )
    mode = {"1": "evidence-hevc", "2": "lossless", "3": "review", "4": "share"}.get(mode, mode)

    default_output = resolve_output_path(
        source_dir,
        None,
        mode,
        start_time,
        end_time,
        output_conflict=output_conflict,
    )
    raw_output = input(f"Output MP4 [{default_output}]: ").strip()
    output_file = resolve_output_path(
        source_dir,
        raw_output if raw_output else str(default_output),
        mode,
        start_time,
        end_time,
        output_conflict=output_conflict,
    )

    raw_workdir = input("Workdir [temporary]: ").strip()
    workdir_arg = Path(raw_workdir).expanduser().resolve() if raw_workdir else None

    raw_keep = input("Keep intermediate files? [N]: ").strip().lower()
    keep_workdir = workdir_arg is not None or raw_keep in {"y", "yes"}

    raw_preset = input("x265 preset [medium]: ").strip() or "medium"

    return RunOptions(
        source_dir=source_dir,
        output_arg=str(output_file),
        start_arg=start_time.strftime("%Y-%m-%d %H:%M:%S"),
        end_arg=end_time.strftime("%Y-%m-%d %H:%M:%S"),
        profile=profile,
        mode=mode,
        ffmpeg=ffmpeg,
        ffprobe=ffprobe,
        workdir_arg=workdir_arg,
        keep_workdir=keep_workdir,
        x265_preset=raw_preset,
        loglevel="info",
        duplicate_policy=duplicate_policy,
        output_conflict=output_conflict,
    )



def prompt_datetime(prompt: str, default: datetime) -> datetime:
    while True:
        value = input(prompt).strip()
        if not value:
            return default
        try:
            return parse_user_datetime(value)
        except RuntimeError as exc:
            print(exc)



def prompt_choice(prompt: str, default: str, allowed: set[str]) -> str:
    while True:
        value = input(prompt).strip().lower()
        if not value:
            return default
        if value in allowed:
            return value
        print(f"Allowed: {', '.join(sorted(allowed))}")



def print_summary(
    source_dir: Path,
    output_file: Path,
    start_time: datetime,
    end_time: datetime,
    layout: str,
    mode: str,
    camera_dimensions: dict[Camera, object],
    sets: int,
    duplicate_policy: DuplicatePolicy,
    duplicate_file_count: int,
    duplicate_timestamp_count: int,
) -> None:
    dimension_text = ", ".join(
        f"{camera.value}={dims.width}x{dims.height}"
        for camera, dims in sorted(camera_dimensions.items(), key=lambda item: item[0].value)
    )
    print("Plan:")
    print(f"  Source: {source_dir}")
    print(f"  Output: {output_file}")
    print(f"  Range:  {start_time} -> {end_time}")
    print(f"  Layout: {layout} | Sets: {sets}")
    print(f"  Mode:   {mode}")
    print(f"  Cells:  {dimension_text}")
    print(f"  Dups:   {duplicate_policy.display_name} | Files: {duplicate_file_count} | Timestamps: {duplicate_timestamp_count}")


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
