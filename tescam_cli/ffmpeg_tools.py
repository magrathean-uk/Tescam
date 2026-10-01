from __future__ import annotations

import json
import os
import platform
import shutil
from functools import lru_cache
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from .concat_safety import ffconcat_path as _safe_ffconcat_path
from .models import Dimensions, EncoderPlan
from .probe_cache import RunProbeCache
from .process_tools import LimitedProcessTimeout, executable_regular_file, run_limited_process

DEFAULT_DURATION_SECONDS = 60.0
DEFAULT_FPS = 36.027
DEFAULT_FFPROBE_TIMEOUT_SECONDS = 20.0
DEFAULT_TOOL_QUERY_TIMEOUT_SECONDS = 15.0


class ToolResolutionError(RuntimeError):
    pass


# Number of trailing stderr lines preserved in the user-visible error summary.
# ffmpeg/ffprobe stderr is regularly hundreds of lines; only the tail is
# actionable on a real failure.
FFMPEG_ERROR_STDERR_TAIL_LINES = 40


class FfmpegRuntimeError(RuntimeError):
    """Raised when ffmpeg/ffprobe exits non-zero or times out.

    Carries the full structured failure payload as attributes so callers
    that want more than the human-readable summary (tests, log capture,
    future tooling) can inspect each piece. ``str(exc)`` returns the
    summary; the attributes carry the rest.

    Attributes
    ----------
    exit_code:
        Exit status returned by the failing process. ``None`` for
        timeouts / pre-launch errors where no exit code is available.
    command_args:
        The argv used to invoke the process.
    filter_graph:
        The value of the ``-filter_complex`` argument when present;
        ``None`` otherwise. Surfaced as its own labeled section in the
        summary so the failing graph is easy to spot.
    stderr_full:
        The full captured stderr string (already truncated by the
        process-tools byte limit; that's a separate concern from the
        line-tail truncation in the summary).
    stderr_tail:
        The trailing ``FFMPEG_ERROR_STDERR_TAIL_LINES`` lines of stderr
        included in the summary.
    """

    def __init__(
        self,
        message: str,
        *,
        exit_code: Optional[int] = None,
        command_args: Optional[Sequence[str]] = None,
        filter_graph: Optional[str] = None,
        stderr_full: Optional[str] = None,
        stderr_tail: Optional[str] = None,
    ) -> None:
        super().__init__(message)
        self.exit_code = exit_code
        self.command_args = tuple(command_args) if command_args is not None else None
        self.filter_graph = filter_graph
        self.stderr_full = stderr_full
        self.stderr_tail = stderr_tail


class MediaProbe:
    def __init__(
        self,
        probe_cache: Optional[RunProbeCache] = None,
        ffprobe_timeout_seconds: Optional[float] = DEFAULT_FFPROBE_TIMEOUT_SECONDS,
    ) -> None:
        self.probe_cache = probe_cache
        self.ffprobe_timeout_seconds = ffprobe_timeout_seconds

    def duration(self, ffprobe: Path, media_path: Path) -> float:
        return self._with_cache(
            ffprobe,
            media_path,
            "duration",
            lambda: probe_duration(ffprobe, media_path, timeout_seconds=self.ffprobe_timeout_seconds),
        )

    def dimensions(self, ffprobe: Path, media_path: Path) -> Optional[Dimensions]:
        return self._with_cache(
            ffprobe,
            media_path,
            "dimensions",
            lambda: probe_dimensions(ffprobe, media_path, timeout_seconds=self.ffprobe_timeout_seconds),
        )

    def fps(self, ffprobe: Path, media_path: Path) -> float:
        return self._with_cache(
            ffprobe,
            media_path,
            "fps",
            lambda: probe_fps(ffprobe, media_path, timeout_seconds=self.ffprobe_timeout_seconds),
        )

    def has_video_stream(self, ffprobe: Path, media_path: Path) -> bool:
        return self._with_cache(
            ffprobe,
            media_path,
            "has_video_stream",
            lambda: probe_has_video_stream(ffprobe, media_path, timeout_seconds=self.ffprobe_timeout_seconds),
        )

    def choose_encoder(self, ffmpeg: Path, mode: str, x265_preset: str) -> EncoderPlan:
        return choose_encoder(ffmpeg, mode, x265_preset)

    def _with_cache(self, ffprobe: Path, media_path: Path, operation: str, compute):
        if self.probe_cache is None:
            return compute()
        return self.probe_cache.get_or_compute(ffprobe, media_path, operation, compute)


class FfmpegRunner:
    def __init__(self, timeout_seconds: Optional[float] = None) -> None:
        self.timeout_seconds = timeout_seconds

    def run(self, args: Sequence[str], cwd: Optional[Path] = None) -> None:
        run_command(args, cwd=cwd, timeout_seconds=self.timeout_seconds)


@lru_cache(maxsize=8)
def _encoders_text(ffmpeg_path: str, timeout_seconds: Optional[float]) -> str:
    try:
        result = run_limited_process(
            [ffmpeg_path, "-hide_banner", "-encoders"],
            timeout_seconds=timeout_seconds,
            stdout_limit_bytes=4 * 1024 * 1024,
            stderr_limit_bytes=128 * 1024,
        )
    except LimitedProcessTimeout as exc:
        raise FfmpegRuntimeError(str(exc)) from exc
    if result.returncode != 0:
        stderr = (result.stderr or "").strip()
        raise FfmpegRuntimeError(f"Failed to query ffmpeg encoders: {stderr}")
    return result.stdout


@lru_cache(maxsize=256)
def _probe_json(
    ffprobe_path: str,
    media_path: str,
    entries: str,
    timeout_seconds: Optional[float],
) -> Dict[str, object]:
    try:
        result = run_limited_process(
            [
                ffprobe_path,
                "-v",
                "error",
                "-of",
                "json",
                "-show_entries",
                entries,
                media_path,
            ],
            timeout_seconds=timeout_seconds,
            stdout_limit_bytes=1_048_576,
            stderr_limit_bytes=65_536,
        )
    except LimitedProcessTimeout:
        return {}
    if result.returncode != 0 or result.stdout_truncated:
        return {}
    try:
        return json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        return {}


def _candidate_tools(explicit: Optional[str], env_var: str, default_name: str, repo_root: Path) -> Sequence[Path]:
    candidates = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    env_value = os.environ.get(env_var)
    if env_value:
        candidates.append(Path(env_value).expanduser())

    if platform.system() == "Darwin":
        bundled = repo_root / "Tescam" / "Resources" / "ffmpeg_bin" / default_name
        candidates.append(bundled)

    which_path = shutil.which(default_name)
    if which_path:
        candidates.append(Path(which_path))

    if platform.system() == "Windows":
        exe_name = f"{default_name}.exe"
        which_path_exe = shutil.which(exe_name)
        if which_path_exe:
            candidates.append(Path(which_path_exe))

    unique: list[Path] = []
    seen = set()
    for candidate in candidates:
        key = str(candidate.resolve()) if candidate.exists() else str(candidate)
        if key in seen:
            continue
        seen.add(key)
        unique.append(candidate)
    return unique


def _resolve_one_tool(explicit: Optional[str], env_var: str, default_name: str, repo_root: Path) -> Path:
    for candidate in _candidate_tools(explicit, env_var, default_name, repo_root):
        if executable_regular_file(candidate):
            return candidate.resolve()
    searched = ", ".join(str(item) for item in _candidate_tools(explicit, env_var, default_name, repo_root)) or "none"
    raise ToolResolutionError(
        f"Could not resolve {default_name}. Searched: {searched}. Install ffmpeg/ffprobe or pass --{default_name}."
    )


def resolve_tools(repo_root: Path, ffmpeg_arg: Optional[str], ffprobe_arg: Optional[str]) -> tuple[Path, Path]:
    ffmpeg = _resolve_one_tool(ffmpeg_arg, "TESCAM_FFMPEG", "ffmpeg", repo_root)
    ffprobe = _resolve_one_tool(ffprobe_arg, "TESCAM_FFPROBE", "ffprobe", repo_root)
    return ffmpeg, ffprobe


def probe_dimensions(
    ffprobe: Path,
    media_path: Path,
    timeout_seconds: Optional[float] = DEFAULT_FFPROBE_TIMEOUT_SECONDS,
) -> Optional[Dimensions]:
    payload = _probe_json(str(ffprobe), str(media_path), "stream=width,height", timeout_seconds)
    streams = payload.get("streams") if isinstance(payload, dict) else None
    if not isinstance(streams, list) or not streams:
        return None
    stream = streams[0]
    if not isinstance(stream, dict):
        return None
    width = stream.get("width")
    height = stream.get("height")
    if not isinstance(width, int) or not isinstance(height, int):
        return None
    if width <= 0 or height <= 0:
        return None
    return Dimensions(width=width, height=height)


def probe_has_video_stream(
    ffprobe: Path,
    media_path: Path,
    timeout_seconds: Optional[float] = DEFAULT_FFPROBE_TIMEOUT_SECONDS,
) -> bool:
    payload = _probe_json(str(ffprobe), str(media_path), "stream=codec_type,width,height", timeout_seconds)
    streams = payload.get("streams") if isinstance(payload, dict) else None
    if not isinstance(streams, list):
        return False
    for stream in streams:
        if not isinstance(stream, dict):
            continue
        codec_type = stream.get("codec_type")
        width = stream.get("width")
        height = stream.get("height")
        if codec_type == "video":
            if isinstance(width, int) and isinstance(height, int):
                return width > 0 and height > 0
            return True
    return False


def probe_duration(
    ffprobe: Path,
    media_path: Path,
    timeout_seconds: Optional[float] = DEFAULT_FFPROBE_TIMEOUT_SECONDS,
) -> float:
    payload = _probe_json(str(ffprobe), str(media_path), "format=duration", timeout_seconds)
    fmt = payload.get("format") if isinstance(payload, dict) else None
    if not isinstance(fmt, dict):
        return DEFAULT_DURATION_SECONDS
    value = fmt.get("duration")
    try:
        duration = float(value)
    except (TypeError, ValueError):
        return DEFAULT_DURATION_SECONDS
    return duration if duration > 0.0 else DEFAULT_DURATION_SECONDS


def probe_fps(
    ffprobe: Path,
    media_path: Path,
    timeout_seconds: Optional[float] = DEFAULT_FFPROBE_TIMEOUT_SECONDS,
) -> float:
    payload = _probe_json(str(ffprobe), str(media_path), "stream=avg_frame_rate,r_frame_rate", timeout_seconds)
    streams = payload.get("streams") if isinstance(payload, dict) else None
    if not isinstance(streams, list) or not streams:
        return DEFAULT_FPS
    stream = streams[0] if isinstance(streams[0], dict) else {}
    for key in ("avg_frame_rate", "r_frame_rate"):
        value = stream.get(key)
        fps = _parse_rate(value)
        if fps is not None and fps > 0:
            return fps
    return DEFAULT_FPS


def _parse_rate(value: object) -> Optional[float]:
    if not isinstance(value, str) or not value:
        return None
    if "/" in value:
        left, right = value.split("/", 1)
        try:
            numerator = float(left)
            denominator = float(right)
        except ValueError:
            return None
        if denominator == 0:
            return None
        return numerator / denominator
    try:
        return float(value)
    except ValueError:
        return None


def choose_encoder(
    ffmpeg: Path,
    mode: str,
    x265_preset: str,
    timeout_seconds: Optional[float] = DEFAULT_TOOL_QUERY_TIMEOUT_SECONDS,
) -> EncoderPlan:
    encoders = _encoders_text(str(ffmpeg), timeout_seconds)
    have_x265 = "libx265" in encoders
    if mode in _DELIVERY_MODES:
        return _delivery_encoder(mode, x265_preset, encoders)
    if not have_x265:
        raise ToolResolutionError(
            "This ffmpeg build does not include libx265. Lossless/near-lossless HEVC requires libx265."
        )

    if mode == "lossless":
        return EncoderPlan(
            mode="lossless",
            label="hevc_lossless",
            output_extension="mp4",
            args=[
                "-c:v",
                "libx265",
                "-preset",
                x265_preset,
                "-x265-params",
                "lossless=1:repeat-headers=1:log-level=error",
                "-tag:v",
                "hvc1",
                "-pix_fmt",
                "yuv420p",
                "-threads",
                "0",
            ],
        )
    if mode in {"quality", "evidence-hevc"}:
        return EncoderPlan(
            mode=mode,
            label="hevc_evidence" if mode == "evidence-hevc" else "hevc_quality",
            output_extension="mp4",
            args=[
                "-c:v",
                "libx265",
                "-preset",
                x265_preset,
                "-crf",
                "6",
                "-x265-params",
                "log-level=error",
                "-tag:v",
                "hvc1",
                "-pix_fmt",
                "yuv420p",
                "-threads",
                "0",
            ],
        )
    raise ValueError(f"Unsupported encoder mode: {mode}")


# Practical delivery presets sized for review/sharing rather than archival.
# ``review`` keeps near-source fidelity at a fraction of lossless size;
# ``share`` trades a little more quality for small, messageable files.
# Each maps to a hardware (VideoToolbox) quality target when available and a
# libx265 CRF fallback otherwise — so these modes do NOT hard-require libx265.
_DELIVERY_MODES = {
    # mode -> (libx265 CRF, VideoToolbox -q:v target)
    "review": (23, 60),
    "share": (28, 45),
}


def _delivery_encoder(mode: str, x265_preset: str, encoders: str) -> EncoderPlan:
    crf, vt_quality = _DELIVERY_MODES[mode]
    have_videotoolbox = "hevc_videotoolbox" in encoders
    have_x265 = "libx265" in encoders
    label = f"hevc_{mode}"
    if have_videotoolbox:
        return EncoderPlan(
            mode=mode,
            label=label,
            output_extension="mp4",
            args=[
                "-c:v",
                "hevc_videotoolbox",
                "-q:v",
                str(vt_quality),
                "-tag:v",
                "hvc1",
                "-pix_fmt",
                "yuv420p",
            ],
        )
    if have_x265:
        return EncoderPlan(
            mode=mode,
            label=label,
            output_extension="mp4",
            args=[
                "-c:v",
                "libx265",
                "-preset",
                x265_preset,
                "-crf",
                str(crf),
                "-x265-params",
                "log-level=error",
                "-tag:v",
                "hvc1",
                "-pix_fmt",
                "yuv420p",
                "-threads",
                "0",
            ],
        )
    raise ToolResolutionError(
        f"The '{mode}' mode needs an HEVC encoder. This ffmpeg build has neither "
        "hevc_videotoolbox nor libx265."
    )


def extract_filter_complex(args: Sequence[str]) -> Optional[str]:
    """Return the value of the first ``-filter_complex`` argument, if any.

    ffmpeg accepts both ``-filter_complex GRAPH`` and the long form
    ``-filter_complex_script PATH``; only the inline form is extracted
    here because that's what the CLI emits.
    """
    items = list(args)
    for index, token in enumerate(items[:-1]):
        if str(token) == "-filter_complex":
            return str(items[index + 1])
    return None


def _strip_filter_complex(args: Sequence[str]) -> List[str]:
    """Return ``args`` with ``-filter_complex GRAPH`` collapsed to a placeholder.

    Keeps the surrounding arguments visible in the failure summary
    without dragging the (very long) graph into the args line — the
    graph is shown separately in its own labeled section.
    """
    items = list(args)
    out: List[str] = []
    skip_next = False
    for index, token in enumerate(items):
        if skip_next:
            skip_next = False
            continue
        if str(token) == "-filter_complex":
            out.append("-filter_complex")
            out.append("<see filter graph below>")
            skip_next = True
            continue
        out.append(str(token))
    return out


def _tail_lines(text: str, max_lines: int) -> tuple[str, int, int]:
    """Return ``(tail_text, kept_lines, total_lines)`` for the last ``max_lines`` of ``text``."""
    if not text:
        return "", 0, 0
    # Preserve trailing-newline semantics; ffmpeg stderr is line-based.
    lines = text.splitlines()
    total = len(lines)
    if total <= max_lines:
        return text.rstrip("\n"), total, total
    tail = lines[-max_lines:]
    return "\n".join(tail), max_lines, total


def format_ffmpeg_failure(
    returncode: int,
    args: Sequence[str],
    stderr: str,
    stderr_truncated_by_byte_limit: bool,
    *,
    stderr_tail_lines: int = FFMPEG_ERROR_STDERR_TAIL_LINES,
) -> Dict[str, Any]:
    """Build the structured payload for a failed ffmpeg/ffprobe invocation.

    Pure function so callers can unit-test the formatting independently
    of subprocess.

    Returns a dict with keys::

        message: str          # human-readable summary
        filter_graph: str|None
        stderr_tail: str
        stderr_full: str
        kept_lines: int
        total_lines: int
    """
    base_args = _strip_filter_complex(args)
    joined_args = " ".join(base_args)
    filter_graph = extract_filter_complex(args)
    tail_text, kept_lines, total_lines = _tail_lines(stderr or "", stderr_tail_lines)
    truncated_by_lines = total_lines > kept_lines

    parts: List[str] = [f"ffmpeg/ffprobe exited with code {returncode}: {joined_args}"]
    if filter_graph is not None:
        parts.append("Filter graph:")
        parts.append(f"  {filter_graph}")

    if total_lines == 0 and stderr_truncated_by_byte_limit:
        parts.append("stderr: <captured but exceeded byte limit; nothing decoded>")
    elif total_lines == 0:
        parts.append("stderr: <empty>")
    else:
        if truncated_by_lines and stderr_truncated_by_byte_limit:
            parts.append(
                f"stderr (last {kept_lines} of {total_lines} lines; output also exceeded byte limit):"
            )
        elif truncated_by_lines:
            parts.append(f"stderr (last {kept_lines} of {total_lines} lines):")
        elif stderr_truncated_by_byte_limit:
            parts.append("stderr (output exceeded byte limit; line-tail unaffected):")
        else:
            parts.append("stderr:")
        for line in tail_text.split("\n"):
            parts.append(f"  {line}")

    return {
        "message": "\n".join(parts),
        "filter_graph": filter_graph,
        "stderr_tail": tail_text,
        "stderr_full": stderr or "",
        "kept_lines": kept_lines,
        "total_lines": total_lines,
    }


def run_command(args: Sequence[str], cwd: Optional[Path] = None, timeout_seconds: Optional[float] = None) -> None:
    try:
        result = run_limited_process(
            list(args),
            cwd=cwd,
            timeout_seconds=timeout_seconds,
            stdout_limit_bytes=65_536,
            stderr_limit_bytes=262_144,
        )
    except LimitedProcessTimeout as exc:
        raise FfmpegRuntimeError(str(exc), command_args=tuple(str(item) for item in args)) from exc
    if result.returncode != 0:
        argv = tuple(str(item) for item in args)
        payload = format_ffmpeg_failure(
            returncode=result.returncode,
            args=argv,
            stderr=result.stderr or "",
            stderr_truncated_by_byte_limit=result.stderr_truncated,
        )
        raise FfmpegRuntimeError(
            payload["message"],
            exit_code=result.returncode,
            command_args=argv,
            filter_graph=payload["filter_graph"],
            stderr_full=payload["stderr_full"],
            stderr_tail=payload["stderr_tail"],
        )


def ffconcat_path(path: Path) -> str:
    return _safe_ffconcat_path(path)
