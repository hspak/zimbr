"""Identify prepared executables and refuse changed artifacts during reuse."""
import hashlib
from pathlib import Path

from .errors import ZrctError


def fingerprint(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def executable_identity(path):
    path = Path(path).absolute()
    return dict(path=str(path), sha256=fingerprint(path))


def verify_executable(path, expected):
    try:
        observed = fingerprint(path)
    except OSError as error:
        raise ZrctError(f"Prepared executable is unavailable: {path}", expected=expected) from error
    if observed != expected:
        raise ZrctError("Prepared executable changed; rebuild and start a new run",
                        path=str(path), expected=expected, observed=observed)
