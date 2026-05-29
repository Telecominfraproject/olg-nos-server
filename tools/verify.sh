#!/bin/bash
# Verify the patch series applies cleanly against the pinned upstream.
#
# What it does (cheap, no docker, no build):
#   1. Clone or reuse a sandbox eve checkout at ./.verify-eve
#   2. Reset to the pinned revision from config.yml
#   3. Apply every patches/*.patch via `git am -3`
#   4. Confirm patches/README.md is up to date (gen-patches-readme.py --check)
#   5. Confirm no patch touches profiles/ (those live on main, not in patches)
#
# Use --reset to nuke the sandbox first (slower; full re-clone).
# Use --build pkg/<name> to additionally compile a package in the sandbox.

set -e

cd "$(dirname "$0")/.."
repo_root="$PWD"
sandbox="$repo_root/.verify-eve"
do_reset=0
build_target=""

while [ $# -gt 0 ]; do
    case "$1" in
        --reset) do_reset=1; shift ;;
        --build) build_target="$2"; shift 2 ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ "$do_reset" -eq 1 ] && [ -d "$sandbox" ]; then
    echo "[verify] resetting sandbox: $sandbox"
    rm -rf "$sandbox"
fi

revision=$(grep -E '^revision:' config.yml | awk '{print $2}')
if [ -z "$revision" ]; then
    echo "[verify] no revision: in config.yml" >&2
    exit 1
fi

echo "[verify] sandbox: $sandbox"
echo "[verify] pinned revision: $revision"

# Use setup.py against the sandbox dir. setup.py respects -d/--directory.
if [ ! -f "$sandbox/Makefile" ]; then
    echo "[verify] cloning upstream into sandbox (slow, one-time)"
    python3 setup.py --setup -d "$sandbox"
else
    echo "[verify] sandbox exists — running --rebase"
    python3 setup.py --rebase -d "$sandbox"
fi

# Sanity: count applied patches matches patches/ count
applied=$(git -C "$sandbox" log --oneline "$revision"..HEAD | wc -l)
expected=$(ls patches/*.patch 2>/dev/null | wc -l)
if [ "$applied" -ne "$expected" ]; then
    echo "[verify] FAIL: $applied commits applied, expected $expected patches" >&2
    exit 1
fi
echo "[verify] $applied/$expected patches applied cleanly"

# Sanity: patches/README.md is current
if ! python3 tools/gen-patches-readme.py --check; then
    echo "[verify] FAIL: patches/README.md stale — run tools/gen-patches-readme.py" >&2
    exit 1
fi
echo "[verify] patches/README.md is current"

# Sanity: no patch touches profiles/ (they live on main, symlinked in)
if grep -l '^diff --git a/profiles/' patches/*.patch >/dev/null 2>&1; then
    echo "[verify] FAIL: patch(es) modify profiles/ — profiles live on main, not in patches:" >&2
    grep -l '^diff --git a/profiles/' patches/*.patch >&2
    exit 1
fi
echo "[verify] no patch touches profiles/"

# Optional partial build
if [ -n "$build_target" ]; then
    echo "[verify] building $build_target in sandbox"
    (cd "$sandbox" && make "$build_target")
    echo "[verify] $build_target built OK"
fi

echo "[verify] OK"
