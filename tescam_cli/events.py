from __future__ import annotations

"""Sentry / Saved event metadata (``event.json``) for the CLI.

Tesla writes an ``event.json`` next to the clips in each ``SentryClips`` and
``SavedClips`` event folder, recording the trigger moment, reason, and an
approximate location. The app already parses this; this module gives the CLI
the same view so it can list events and export a window centred on the actual
trigger rather than the folder start.

Pure: this module only reads ``event.json`` files (no clip probing, no
rendering), so it stays on the planning side of the CLI's I/O boundary.
"""

import json
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import List, Optional

# Folders Tesla groups discrete events under. RecentClips is a continuous
# ring buffer with no per-event metadata, so it is intentionally excluded.
EVENT_CATEGORIES = ("SentryClips", "SavedClips")

_EVENT_TIMESTAMP_FORMATS = (
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d_%H-%M-%S",
    "%Y-%m-%dT%H:%M",
)


@dataclass(frozen=True)
class CamEvent:
    """One Sentry/Saved event, sourced from a folder's ``event.json``."""

    folder: Path
    category: str  # "SentryClips" | "SavedClips"
    timestamp: Optional[datetime]
    reason: Optional[str]
    city: Optional[str]
    street: Optional[str]
    latitude: Optional[float]
    longitude: Optional[float]

    @property
    def location(self) -> str:
        parts = [part for part in (self.city, self.street) if part]
        return ", ".join(parts)


def _parse_event_timestamp(raw: object) -> Optional[datetime]:
    if not isinstance(raw, str) or not raw.strip():
        return None
    value = raw.strip()
    for fmt in _EVENT_TIMESTAMP_FORMATS:
        try:
            return datetime.strptime(value, fmt)
        except ValueError:
            continue
    return None


def _parse_float(raw: object) -> Optional[float]:
    if raw is None:
        return None
    try:
        return float(raw)
    except (TypeError, ValueError):
        return None


def _read_event_json(folder: Path, category: str) -> Optional[CamEvent]:
    event_file = folder / "event.json"
    if not event_file.is_file():
        return None
    try:
        payload = json.loads(event_file.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None

    def _text(key: str) -> Optional[str]:
        value = payload.get(key)
        return value.strip() if isinstance(value, str) and value.strip() else None

    return CamEvent(
        folder=folder,
        category=category,
        timestamp=_parse_event_timestamp(payload.get("timestamp")),
        reason=_text("reason"),
        city=_text("city"),
        street=_text("street"),
        latitude=_parse_float(payload.get("est_lat")),
        longitude=_parse_float(payload.get("est_lon")),
    )


def scan_events(source_dir: Path) -> List[CamEvent]:
    """Return all Sentry/Saved events under ``source_dir``, sorted by time.

    Folders without a readable ``event.json`` are skipped. Events without a
    parseable timestamp sort last (their folder name is used as a tiebreaker).
    """
    events: List[CamEvent] = []
    for category in EVENT_CATEGORIES:
        category_dir = source_dir / category
        if not category_dir.is_dir():
            continue
        for folder in sorted(p for p in category_dir.iterdir() if p.is_dir()):
            event = _read_event_json(folder, category)
            if event is not None:
                events.append(event)
    events.sort(
        key=lambda e: (
            e.timestamp is None,
            e.timestamp or datetime.max,
            e.folder.name,
        )
    )
    return events
