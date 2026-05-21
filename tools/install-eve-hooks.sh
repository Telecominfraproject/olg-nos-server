#!/bin/bash
# Install olg-eve git hooks into the eve/ checkout.
#
# Idempotent. Re-run after a fresh ./setup.py --setup if you want hook
# enforcement on commits made inside eve/.

set -e

cd "$(dirname "$0")/.."
repo_root="$PWD"

if [ ! -d "$repo_root/eve/.git" ]; then
    echo "eve/.git not found — run ./setup.py --setup first" >&2
    exit 1
fi

hooks_dir="$repo_root/eve/.git/hooks"
mkdir -p "$hooks_dir"

# commit-msg: delegate to tools/check-commit-msg.sh in this repo
cat > "$hooks_dir/commit-msg" <<EOF
#!/bin/bash
exec "$repo_root/tools/check-commit-msg.sh" "\$1"
EOF
chmod +x "$hooks_dir/commit-msg"

echo "installed commit-msg hook -> $hooks_dir/commit-msg"
