from __future__ import annotations

import os
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Sequence


@dataclass(frozen=True)
class LimitedProcessResult:
    args: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str
    stdout_truncated: bool
    stderr_truncated: bool


class LimitedProcessTimeout(RuntimeError):
    pass


def run_limited_process(
    args: Sequence[str],
    *,
    timeout_seconds: Optional[float],
    stdout_limit_bytes: int = 1_048_576,
    stderr_limit_bytes: int = 65_536,
    cwd: Optional[Path] = None,
) -> LimitedProcessResult:
    argv = tuple(str(item) for item in args)
    with tempfile.TemporaryFile() as stdout_file, tempfile.TemporaryFile() as stderr_file:
        process = subprocess.Popen(
            argv,
            cwd=str(cwd) if cwd else None,
            stdin=subprocess.DEVNULL,
            stdout=stdout_file,
            stderr=stderr_file,
            close_fds=os.name != "nt",
        )
        try:
            returncode = process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired as exc:
            process.kill()
            process.wait()
            raise LimitedProcessTimeout(f"Timed out after {timeout_seconds:.1f}s: {_safe_command(argv)}") from exc

        stdout, stdout_truncated = _read_limited_text(stdout_file, stdout_limit_bytes)
        stderr, stderr_truncated = _read_limited_text(stderr_file, stderr_limit_bytes)
        return LimitedProcessResult(
            args=argv,
            returncode=returncode,
            stdout=stdout,
            stderr=stderr,
            stdout_truncated=stdout_truncated,
            stderr_truncated=stderr_truncated,
        )


def _read_limited_text(handle, limit: int) -> tuple[str, bool]:
    handle.seek(0, os.SEEK_END)
    size = handle.tell()
    handle.seek(0)
    raw = handle.read(max(0, limit))
    text = raw.decode("utf-8", errors="replace")
    text = "".join(ch if ch >= " " or ch in "\n\t" else "?" for ch in text)
    return text, size > limit


def _safe_command(argv: Sequence[str], max_chars: int = 300) -> str:
    text = " ".join(str(part) for part in argv)
    text = "".join(ch if ch >= " " and ch != "\x7f" else "?" for ch in text)
    if len(text) > max_chars:
        return text[:max_chars] + "..."
    return text


def executable_regular_file(path: Path) -> bool:
    try:
        return path.is_file() and os.access(path, os.X_OK)
    except OSError:
        return False
