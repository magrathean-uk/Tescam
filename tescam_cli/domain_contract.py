from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterable, Mapping, Optional

from .models import (
    Camera,
    Dimensions,
    DuplicatePolicy,
    LayoutSpec,
    OutputConflictPolicy,
    ScanResult,
    SelectedSet,
)

SCHEMA_VERSION = 1

CONTRACT_CAMERA_ORDER = [
    Camera.FRONT,
    Camera.BACK,
    Camera.LEFT_REPEATER,
    Camera.RIGHT_REPEATER,
    Camera.LEFT,
    Camera.RIGHT,
    Camera.LEFT_PILLAR,
    Camera.RIGHT_PILLAR,
]

_CAMERA_SORT = {camera: index for index, camera in enumerate(CONTRACT_CAMERA_ORDER)}


def camera_values(cameras: Iterable[Camera]) -> list[str]:
    return [camera.value for camera in sorted(cameras, key=lambda item: (_CAMERA_SORT.get(item, 999), item.value))]


def path_for_manifest(path: Path, root: Optional[Path] = None) -> str:
    resolved = path
    if root is not None:
        try:
            resolved = path.resolve().relative_to(root.resolve())
        except ValueError:
            resolved = path.resolve()
        except FileNotFoundError:
            try:
                resolved = path.relative_to(root)
            except ValueError:
                resolved = path
    return resolved.as_posix()


def datetime_for_manifest(value: datetime) -> str:
    return value.isoformat(timespec="seconds")


def scan_manifest(scan_result: ScanResult, source_dir: Path) -> Dict[str, Any]:
    clip_sets: list[Dict[str, Any]] = []
    for clip_set in scan_result.clip_sets:
        ordered_cameras = sorted(clip_set.files, key=lambda item: (_CAMERA_SORT.get(item, 999), item.value))
        files = {
            camera.value: path_for_manifest(clip_set.files[camera], source_dir)
            for camera in ordered_cameras
        }
        clip_sets.append(
            {
                "timestamp": clip_set.timestamp,
                "start_time": datetime_for_manifest(clip_set.start_time),
                "cameras": [camera.value for camera in ordered_cameras],
                "files": files,
            }
        )

    return {
        "schema_version": SCHEMA_VERSION,
        "type": "tescam.scan",
        "clip_set_count": len(scan_result.clip_sets),
        "duplicate_file_count": scan_result.duplicate_file_count,
        "duplicate_timestamp_count": scan_result.duplicate_timestamp_count,
        "cameras": camera_values(scan_result.cameras),
        "clip_sets": clip_sets,
    }


def selected_sets_manifest(selected_sets: Iterable[SelectedSet], source_dir: Path) -> Dict[str, Any]:
    items: list[Dict[str, Any]] = []
    total_rendered_duration = 0.0
    for selected in selected_sets:
        total_rendered_duration += selected.rendered_duration
        clip_set = selected.clip_set
        ordered_cameras = sorted(clip_set.files, key=lambda item: (_CAMERA_SORT.get(item, 999), item.value))
        items.append(
            {
                "timestamp": clip_set.timestamp,
                "start_time": datetime_for_manifest(clip_set.start_time),
                "duration": round(selected.duration, 6),
                "trim_start": round(selected.trim_start, 6),
                "trim_end": round(selected.trim_end, 6),
                "rendered_duration": round(selected.rendered_duration, 6),
                "cameras": [camera.value for camera in ordered_cameras],
                "files": {
                    camera.value: path_for_manifest(clip_set.files[camera], source_dir)
                    for camera in ordered_cameras
                },
            }
        )
    return {
        "clip_set_count": len(items),
        "rendered_duration": round(total_rendered_duration, 6),
        "clip_sets": items,
    }


def dimensions_manifest(dimensions: Mapping[Camera, Dimensions]) -> Dict[str, Dict[str, int]]:
    ordered = sorted(dimensions, key=lambda item: (_CAMERA_SORT.get(item, 999), item.value))
    return {
        camera.value: {"width": dimensions[camera].width, "height": dimensions[camera].height}
        for camera in ordered
    }


def layout_manifest(layout: LayoutSpec) -> Dict[str, Any]:
    cells: Dict[str, Dict[str, int]] = {}
    for camera in layout.cameras:
        cell = layout.cell_by_camera[camera]
        cells[camera.value] = {
            "width": cell.width,
            "height": cell.height,
            "x": cell.x,
            "y": cell.y,
        }
    return {
        "profile": layout.profile,
        "kind": layout.kind.value,
        "expected_cameras": [camera.value for camera in (layout.expected_cameras or layout.cameras)],
        "render_order": [camera.value for camera in layout.cameras],
        "hidden_cameras": [camera.value for camera in (layout.hidden_cameras or [])],
        "canvas": {"width": layout.canvas_width, "height": layout.canvas_height},
        "cells": cells,
    }


def dry_run_manifest(
    *,
    source_dir: Path,
    output_file: Path,
    start_time: datetime,
    end_time: datetime,
    profile: str,
    mode: str,
    duplicate_policy: DuplicatePolicy,
    output_conflict: OutputConflictPolicy,
    scan_result: ScanResult,
    selected_sets: Iterable[SelectedSet],
    layout: LayoutSpec,
    dimensions: Mapping[Camera, Dimensions],
    fps: float,
    encoder_label: str,
) -> Dict[str, Any]:
    selected_sets_list = list(selected_sets)
    return {
        "schema_version": SCHEMA_VERSION,
        "type": "tescam.dry-run",
        "source_dir": str(source_dir),
        "output_file": str(output_file),
        "range": {
            "start": datetime_for_manifest(start_time),
            "end": datetime_for_manifest(end_time),
        },
        "profile": profile,
        "mode": mode,
        "encoder": encoder_label,
        "fps": round(fps, 6),
        "duplicate_policy": duplicate_policy.value,
        "output_conflict": output_conflict.value,
        "telemetry": {
            "sei_inspection": "not_performed",
            "cli_render_overlay": False,
            "native_export_overlay": True,
            "speed_units": ["km/h", "mph"],
            "hud_modes": ["minimal", "detailed"],
        },
        "scan": scan_manifest(scan_result, source_dir),
        "selection": selected_sets_manifest(selected_sets_list, source_dir),
        "layout": layout_manifest(layout),
        "dimensions": dimensions_manifest(dimensions),
    }


def manifest_json(manifest: Mapping[str, Any]) -> str:
    return json.dumps(manifest, indent=2, sort_keys=True) + "\n"


def write_manifest_json(manifest: Mapping[str, Any], target: str) -> None:
    payload = manifest_json(manifest)
    if target == "-":
        print(payload, end="")
        return
    path = Path(target).expanduser().resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(payload, encoding="utf-8")
