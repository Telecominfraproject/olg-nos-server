"""Parsing and introspection for the olg-eve patch series.

A patch in `patches/` is the output of `git format-patch`: an mbox-style
file with email headers, a body, then one or more `diff --git` blocks.
This module parses what an agent or tool typically needs without invoking
git: subject, scope, files-touched.

Usage:
    from patches import load_series, Patch
    series = load_series()  # auto-finds repo root
    for p in series:
        print(p.number, p.scope, p.subject, p.files)
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable


def repo_root(start: Path | None = None) -> Path:
    """Walk up from `start` (default cwd) until we find config.yml + patches/."""
    p = (start or Path.cwd()).resolve()
    for cand in [p] + list(p.parents):
        if (cand / "config.yml").is_file() and (cand / "patches").is_dir():
            return cand
    raise RuntimeError("Not inside an olg-eve checkout (no config.yml + patches/)")


@dataclass
class Patch:
    number: int           # parsed from filename prefix (0001 -> 1)
    filename: str         # e.g. "0007-zedagent-fix-nil-panic-...patch"
    path: Path            # absolute path to the patch file
    subject: str          # full subject line after stripping [PATCH N/M] prefix
    scope: str            # leading "<scope>:" tag if present, else ""
    summary: str          # subject text after "<scope>: " (or full subject if no scope)
    files: list[str] = field(default_factory=list)  # paths from `diff --git a/X b/X`

    def touches(self, path: str) -> bool:
        """True if this patch modifies / creates / deletes `path` or anything under it."""
        path = path.rstrip("/")
        for f in self.files:
            if f == path or f.startswith(path + "/"):
                return True
        return False


_SUBJECT_PREFIX_RE = re.compile(r"^\[PATCH(?:\s+\d+/\d+)?\]\s*")
_SCOPE_RE = re.compile(r"^([A-Za-z0-9_./-]+):\s+(.*)$")
_FILENAME_NUM_RE = re.compile(r"^(\d+)-")


def parse_patch(path: Path) -> Patch:
    """Parse a single .patch file into a Patch object."""
    text = path.read_text(encoding="utf-8", errors="replace")
    # mbox style: headers, blank line, body. Subject may continue on
    # indented continuation lines.
    head, _, rest = text.partition("\n\n")
    subject_lines: list[str] = []
    in_subject = False
    for line in head.splitlines():
        if line.startswith("Subject:"):
            subject_lines = [line[len("Subject:"):].strip()]
            in_subject = True
        elif in_subject and line.startswith(" "):
            subject_lines.append(line.strip())
        elif in_subject:
            in_subject = False
    subject = " ".join(subject_lines)
    subject = _SUBJECT_PREFIX_RE.sub("", subject).strip()

    scope = ""
    summary = subject
    m = _SCOPE_RE.match(subject)
    if m:
        scope, summary = m.group(1), m.group(2)

    files: list[str] = []
    seen: set[str] = set()
    for line in text.splitlines():
        if line.startswith("diff --git "):
            # Format: diff --git a/<old> b/<new>
            parts = line.split(" ", 4)
            if len(parts) >= 4 and parts[2].startswith("a/"):
                f = parts[2][2:]
                if f not in seen:
                    seen.add(f)
                    files.append(f)

    num_m = _FILENAME_NUM_RE.match(path.name)
    number = int(num_m.group(1)) if num_m else 0

    return Patch(
        number=number,
        filename=path.name,
        path=path,
        subject=subject,
        scope=scope,
        summary=summary,
        files=files,
    )


def load_series(patches_dir: Path | None = None) -> list[Patch]:
    """Load all patches from `patches/`, sorted by filename (numeric prefix)."""
    if patches_dir is None:
        patches_dir = repo_root() / "patches"
    patches = sorted(patches_dir.glob("*.patch"), key=lambda p: p.name)
    return [parse_patch(p) for p in patches]


def filter_touching(series: Iterable[Patch], path: str) -> list[Patch]:
    return [p for p in series if p.touches(path)]


if __name__ == "__main__":
    # Smoke test: dump the series.
    for p in load_series():
        print(f"{p.number:04d}  {p.scope:20s}  {p.summary}  [{len(p.files)} files]")
