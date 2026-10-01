from __future__ import annotations

import os
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator
from uuid import uuid4


@contextmanager
def atomic_output_target(final_path: Path, suffix: str = ".tmp") -> Iterator[Path]:
    final_path = final_path.resolve()
    final_path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = final_path.parent / f".{final_path.name}.tescam-{uuid4().hex}{suffix}"
    promoted = False
    try:
        yield temp_path
        os.replace(temp_path, final_path)
        promoted = True
    finally:
        if not promoted:
            try:
                if temp_path.exists() or temp_path.is_symlink():
                    temp_path.unlink()
            except OSError:
                pass
