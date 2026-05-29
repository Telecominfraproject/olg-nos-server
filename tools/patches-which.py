#!/usr/bin/env python3
"""Print which patches touch a given file or directory path.

Usage:
    tools/patches-which.py <path>            # e.g. pkg/pillar/cmd/zedagent
    tools/patches-which.py <path1> <path2>   # multiple queries

Paths are matched as prefixes (so "pkg/pillar" matches anything under it).
Exits 0 if any patch matches, 1 otherwise.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from patches import load_series, filter_touching


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    series = load_series()
    any_match = False
    for query in argv[1:]:
        matches = filter_touching(series, query)
        if not matches:
            print(f"# {query}: no patches touch this path")
            continue
        any_match = True
        print(f"# {query}: {len(matches)} patch(es)")
        for p in matches:
            print(f"  {p.filename}")
            for f in p.files:
                if f == query or f.startswith(query.rstrip("/") + "/"):
                    print(f"    ↳ {f}")
    return 0 if any_match else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
