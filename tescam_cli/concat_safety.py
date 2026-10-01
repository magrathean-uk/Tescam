from __future__ import annotations

from pathlib import Path


class UnsafeConcatPath(RuntimeError):
    pass


def validate_ffconcat_path(path: Path) -> None:
    text = str(path)
    if "\n" in text or "\r" in text:
        raise UnsafeConcatPath("Media paths containing newlines are not supported for ffmpeg concat lists.")


def ffconcat_path(path: Path) -> str:
    validate_ffconcat_path(path)
    text = str(path.resolve()).replace("\\", "/")
    # The path is written wrapped in single quotes (``file '...'``) by the
    # concat-list writer, so a literal single quote must be emitted as the
    # four-character sequence ``'\''`` (close-quote, escaped-quote, reopen).
    # NOTE: this must NOT be a raw string — ``r"'\\''"`` yields a *doubled*
    # backslash (``'\\''``) which ffmpeg mis-parses, corrupting any path that
    # contains an apostrophe (e.g. a ``/Users/O'Brien`` home directory).
    return text.replace("'", "'\\''")
