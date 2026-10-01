from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, TypeVar

T = TypeVar("T")


@dataclass(frozen=True)
class MediaFileSignature:
    path: str
    size: int
    mtime_ns: int

    @staticmethod
    def from_path(path: Path) -> "MediaFileSignature":
        stat = path.stat()
        return MediaFileSignature(
            path=str(path.resolve()),
            size=stat.st_size,
            mtime_ns=stat.st_mtime_ns,
        )


@dataclass(frozen=True)
class ProbeKey:
    ffprobe: str
    media: MediaFileSignature
    operation: str


class RunProbeCache:
    def __init__(self) -> None:
        self._values: Dict[ProbeKey, object] = {}

    def get_or_compute(self, ffprobe: Path, media_path: Path, operation: str, compute: Callable[[], T]) -> T:
        key = ProbeKey(
            str(ffprobe.resolve()) if ffprobe.exists() else str(ffprobe),
            MediaFileSignature.from_path(media_path),
            operation,
        )
        if key in self._values:
            return self._values[key]  # type: ignore[return-value]
        value = compute()
        self._values[key] = value
        return value

    def clear(self) -> None:
        self._values.clear()

    @property
    def size(self) -> int:
        return len(self._values)
