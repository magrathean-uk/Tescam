from __future__ import annotations

import os
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from tempfile import mkdtemp
from typing import Callable, Dict, Hashable, Iterable, List, Optional, Protocol, Sequence, Tuple, TypeVar, Union

from .concat_safety import ffconcat_path
from .ffmpeg_tools import FfmpegRunner, MediaProbe
from .models import Camera, ClipSet, ComposePlan, Dimensions, MIXED_CAMERA_ORDER, SelectedSet
from .safe_output import atomic_output_target


@dataclass(frozen=True)
class RenderStarted:
    ffmpeg: Path
    ffprobe: Path
    canvas_width: int
    canvas_height: int
    layout: str
    fps: float
    mode: str
    selected_count: int


@dataclass(frozen=True)
class RenderUnreadableClips:
    paths: List[Path]


@dataclass(frozen=True)
class RenderPartStarted:
    index: int
    total: int
    timestamp: str
    trim_start: float
    trim_end: float


@dataclass(frozen=True)
class RenderConcatStarted:
    pass


RenderEvent = Union[RenderStarted, RenderUnreadableClips, RenderPartStarted, RenderConcatStarted]


class RenderReporter(Protocol):
    def handle_render_event(self, event: RenderEvent) -> None:
        ...


# ffprobe is I/O bound (process startup + JSON parse). 4 concurrent workers is
# the knee on a typical laptop without melting the kernel scheduler — the
# probe-cache already prevents re-probing duplicate paths within a run, so the
# workload is essentially "N unique files × ~50–200 ms each". Override via
# the ``TESCAM_PROBE_JOBS`` environment variable when measuring.
_PROBE_MAX_WORKERS_DEFAULT = 4


def _probe_max_workers() -> int:
    raw = os.environ.get("TESCAM_PROBE_JOBS")
    if raw is not None:
        try:
            value = int(raw)
        except ValueError:
            value = _PROBE_MAX_WORKERS_DEFAULT
        if value >= 1:
            return value
    return _PROBE_MAX_WORKERS_DEFAULT


_K = TypeVar("_K", bound=Hashable)
_V = TypeVar("_V")


def _concurrent_probe(
    jobs: Sequence[Tuple[_K, Callable[[], _V]]],
    *,
    max_workers: Optional[int] = None,
) -> Dict[_K, _V]:
    """Run probe callables concurrently; return ``{key: result}`` for each.

    ``jobs`` is a sequence of ``(key, fn)`` pairs. Each ``fn`` is invoked in a
    worker thread; results are gathered into a dict keyed by ``key``. Order is
    irrelevant — callers reduce results into their own collections.

    Sized for I/O-bound workloads (ffprobe subprocesses release the GIL during
    the system call). Falls back to a single-thread pool when only one job
    needs probing so the executor overhead does not dominate.
    """
    if not jobs:
        return {}
    workers = max_workers if max_workers is not None else _probe_max_workers()
    workers = max(1, min(workers, len(jobs)))
    if workers == 1:
        return {key: fn() for key, fn in jobs}
    results: Dict[_K, _V] = {}
    with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="tescam-probe") as pool:
        futures = {pool.submit(fn): key for key, fn in jobs}
        for future in futures:
            key = futures[future]
            results[key] = future.result()
    return results


def clip_set_duration(
    clip_set: ClipSet,
    ffprobe: Path,
    duration_cache: Optional[Dict[Path, float]] = None,
    media_probe: Optional[MediaProbe] = None,
) -> float:
    probe = media_probe or MediaProbe()
    max_duration = 0.0
    for clip_path in clip_set.files.values():
        if not clip_path.exists():
            continue
        duration = duration_cache.get(clip_path) if duration_cache is not None else None
        if duration is None:
            duration = probe.duration(ffprobe, clip_path)
            if duration_cache is not None:
                duration_cache[clip_path] = duration
        max_duration = max(max_duration, duration)
    return max_duration or 60.0


def select_clip_sets(
    clip_sets: Iterable[ClipSet],
    start_time: datetime,
    end_time: datetime,
    ffprobe: Path,
    media_probe: Optional[MediaProbe] = None,
) -> List[SelectedSet]:
    """Select clip-sets overlapping the requested range.

    Probes ``clip_set_duration`` concurrently across clip-sets — that's the
    pre-flight phase on every render. The shared ``duration_cache`` would
    otherwise serialize per-path probes; the cache is still populated as
    each ``clip_set_duration`` call resolves, so subsequent same-path lookups
    inside the per-set walk hit the cache.
    """
    materialized = list(clip_sets)
    if not materialized:
        return []

    duration_cache: Dict[Path, float] = {}
    duration_jobs: List[Tuple[int, Callable[[], float]]] = [
        (
            index,
            (lambda cs=clip_set: clip_set_duration(cs, ffprobe, duration_cache, media_probe)),
        )
        for index, clip_set in enumerate(materialized)
    ]
    durations = _concurrent_probe(duration_jobs)

    selected: List[SelectedSet] = []
    for index, clip_set in enumerate(materialized):
        duration = durations[index]
        clip_end = clip_set.start_time + timedelta(seconds=duration)
        if clip_set.start_time >= end_time or clip_end <= start_time:
            continue
        trim_start = max(0.0, (start_time - clip_set.start_time).total_seconds())
        trim_end = min(duration, (end_time - clip_set.start_time).total_seconds())
        if trim_end - trim_start <= 0.001:
            continue
        selected.append(
            SelectedSet(
                clip_set=clip_set,
                duration=duration,
                trim_start=trim_start,
                trim_end=trim_end,
            )
        )
    return selected



def first_existing_clip(
    clip_set: ClipSet,
    ffprobe: Optional[Path] = None,
    media_probe: Optional[MediaProbe] = None,
) -> Optional[Path]:
    probe = media_probe or MediaProbe()
    for camera in MIXED_CAMERA_ORDER:
        candidate = clip_set.files.get(camera)
        if not candidate or not candidate.exists():
            continue
        if ffprobe is not None and not probe.has_video_stream(ffprobe, candidate):
            continue
        return candidate
    return None



def probe_dimensions_for_selection(
    ffprobe: Path,
    selected_sets: Iterable[SelectedSet],
    media_probe: Optional[MediaProbe] = None,
) -> Dict[Camera, Dimensions]:
    """Probe per-camera dimensions across the selection in parallel.

    The first-encountered path wins per camera (matches the previous
    sequential behavior). All candidate paths are probed concurrently;
    serial reduction picks the first non-``None`` per camera.
    """
    probe = media_probe or MediaProbe()
    seen_per_camera: Dict[Camera, Path] = {}
    candidates: List[Tuple[Camera, Path]] = []
    for selected in selected_sets:
        for camera, clip_path in selected.clip_set.files.items():
            if camera in seen_per_camera:
                continue
            seen_per_camera[camera] = clip_path
            candidates.append((camera, clip_path))
    if not candidates:
        return {}
    jobs: List[Tuple[Camera, Callable[[], Optional[Dimensions]]]] = [
        (camera, (lambda p=path: probe.dimensions(ffprobe, p)))
        for camera, path in candidates
    ]
    probed = _concurrent_probe(jobs)
    dimensions: Dict[Camera, Dimensions] = {}
    for camera, _path in candidates:
        result = probed.get(camera)
        if result is not None:
            dimensions[camera] = result
    return dimensions



def probe_selection_fps(
    ffprobe: Path,
    selected_sets: Iterable[SelectedSet],
    media_probe: Optional[MediaProbe] = None,
) -> float:
    probe = media_probe or MediaProbe()
    for selected in selected_sets:
        source = first_existing_clip(selected.clip_set, ffprobe=ffprobe, media_probe=probe)
        if source is not None:
            return probe.fps(ffprobe, source)
    return 36.027



def prepare_workdir(workdir: Optional[Path]) -> tuple[Path, bool]:
    if workdir is None:
        created = Path(mkdtemp(prefix="tescam_cli_"))
        return created, False
    workdir.mkdir(parents=True, exist_ok=True)
    return workdir.resolve(), True



def compose(plan: ComposePlan) -> Path:
    media_probe = plan.media_probe or MediaProbe()
    runner = plan.ffmpeg_runner or FfmpegRunner()
    reporter = plan.render_reporter
    parts_dir = plan.workdir / "parts"
    parts_dir.mkdir(parents=True, exist_ok=True)
    concat_file = plan.workdir / "concat.txt"
    part_paths: List[Path] = []
    clip_readability = collect_clip_readability(plan.ffprobe, plan.selected_sets, media_probe=media_probe)
    unreadable_paths = sorted(path for path, readable in clip_readability.items() if not readable)

    emit_render_event(
        reporter,
        RenderStarted(
            ffmpeg=plan.ffmpeg,
            ffprobe=plan.ffprobe,
            canvas_width=plan.layout.canvas_width,
            canvas_height=plan.layout.canvas_height,
            layout=plan.layout.kind.value,
            fps=plan.fps,
            mode=plan.encoder.label,
            selected_count=len(plan.selected_sets),
        ),
    )
    if unreadable_paths:
        emit_render_event(reporter, RenderUnreadableClips(paths=unreadable_paths))

    for index, selected in enumerate(plan.selected_sets, start=1):
        part_path = parts_dir / f"{index:06d}_{selected.clip_set.timestamp}.{plan.encoder.output_extension}"
        emit_render_event(
            reporter,
            RenderPartStarted(
                index=index,
                total=len(plan.selected_sets),
                timestamp=selected.clip_set.timestamp,
                trim_start=selected.trim_start,
                trim_end=selected.trim_end,
            ),
        )
        command = build_part_command(plan, selected, part_path, clip_readability)
        runner.run(command)
        part_paths.append(part_path)

    with concat_file.open("w", encoding="utf-8", newline="\n") as handle:
        for part_path in part_paths:
            handle.write(f"file '{ffconcat_path(part_path)}'\n")

    plan.output_file.parent.mkdir(parents=True, exist_ok=True)
    with atomic_output_target(plan.output_file, suffix=plan.output_file.suffix or ".tmp") as temp_output_file:
        concat_command = [
            str(plan.ffmpeg),
            "-y",
            "-hide_banner",
            "-loglevel",
            plan.loglevel,
            "-nostdin",
            "-f",
            "concat",
            "-safe",
            "0",
            "-i",
            str(concat_file),
            "-c",
            "copy",
            "-movflags",
            "+faststart",
            str(temp_output_file),
        ]
        emit_render_event(reporter, RenderConcatStarted())
        runner.run(concat_command)
    return plan.output_file


def emit_render_event(reporter: Optional[RenderReporter], event: RenderEvent) -> None:
    if reporter is not None:
        reporter.handle_render_event(event)



def build_part_command(
    plan: ComposePlan,
    selected: SelectedSet,
    part_path: Path,
    clip_readability: Optional[Dict[Path, bool]] = None,
) -> List[str]:
    input_args: List[str] = []
    filter_parts: List[str] = []
    labels: List[str] = []
    fps_text = _fmt_float(plan.fps)
    trim_start = _fmt_float(selected.trim_start)
    trim_end = _fmt_float(selected.trim_end)

    for input_index, camera in enumerate(plan.layout.cameras):
        clip_path = selected.clip_set.files.get(camera)
        cell = plan.layout.cell_by_camera[camera]
        clip_is_usable = bool(
            clip_path
            and clip_path.exists()
            and (clip_readability.get(clip_path, True) if clip_readability is not None else True)
        )
        if clip_is_usable and clip_path is not None:
            input_args.extend(["-i", str(clip_path)])
        else:
            input_args.extend(
                [
                    "-f",
                    "lavfi",
                    "-t",
                    _fmt_float(selected.duration),
                    "-r",
                    fps_text,
                    "-i",
                    f"color=size={cell.width}x{cell.height}:rate={fps_text}:color=black",
                ]
            )
        label = f"v{input_index}"
        labels.append(f"[{label}]")
        filter_parts.append(
            "[{}:v]trim=start={}:end={},setpts=PTS-STARTPTS,".format(input_index, trim_start, trim_end)
            + "scale={}:{}:flags=lanczos:force_original_aspect_ratio=decrease,".format(cell.width, cell.height)
            + "pad={}:{}:(ow-iw)/2:(oh-ih)/2:black,setsar=1[{}]".format(cell.width, cell.height, label)
        )

    layout_tokens = []
    for camera in plan.layout.cameras:
        cell = plan.layout.cell_by_camera[camera]
        layout_tokens.append(f"{cell.x}_{cell.y}")
    filter_parts.append(
        "{}xstack=inputs={}:layout={}:fill=black,format=yuv420p[vout]".format(
            "".join(labels),
            len(labels),
            "|".join(layout_tokens),
        )
    )

    return [
        str(plan.ffmpeg),
        "-y",
        "-hide_banner",
        "-loglevel",
        plan.loglevel,
        "-nostdin",
        *input_args,
        "-filter_complex",
        ";".join(filter_parts),
        "-map",
        "[vout]",
        "-an",
        "-r",
        fps_text,
        *plan.encoder.args,
        str(part_path),
    ]


def collect_clip_readability(
    ffprobe: Path,
    selected_sets: Iterable[SelectedSet],
    media_probe: Optional[MediaProbe] = None,
) -> Dict[Path, bool]:
    """Return ``{path: True/False}`` for every unique clip path in the selection.

    Existence and ``has_video_stream`` checks for each unique path run
    concurrently. ``False`` is recorded for missing files without invoking
    ffprobe (matches the sequential semantics).
    """
    probe = media_probe or MediaProbe()
    unique_paths: Dict[Path, bool] = {}
    order: List[Path] = []
    for selected in selected_sets:
        for clip_path in selected.clip_set.files.values():
            if clip_path in unique_paths:
                continue
            order.append(clip_path)
            unique_paths[clip_path] = False  # placeholder; resolved below

    if not order:
        return {}

    jobs: List[Tuple[Path, Callable[[], bool]]] = []
    for clip_path in order:
        if not clip_path.exists():
            unique_paths[clip_path] = False
            continue
        jobs.append((clip_path, (lambda p=clip_path: probe.has_video_stream(ffprobe, p))))

    if jobs:
        probed = _concurrent_probe(jobs)
        for clip_path, value in probed.items():
            unique_paths[clip_path] = bool(value)

    return unique_paths



def _fmt_float(value: float) -> str:
    text = f"{value:.6f}"
    text = text.rstrip("0").rstrip(".")
    return text or "0"
