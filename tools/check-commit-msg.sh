#!/bin/bash
# Validate that an olg-eve patch commit message follows `<scope>: <subject>`.
#
# Invoked two ways:
#   1. As a git commit-msg hook inside eve/.git/hooks/ — passed $1 = path to message file
#   2. Standalone with a path argument — same contract
#
# Exits 0 on success, 1 with explanation on failure.

set -e

msg_file="$1"
if [ -z "$msg_file" ] || [ ! -f "$msg_file" ]; then
    echo "usage: $(basename "$0") <commit-msg-file>" >&2
    exit 2
fi

# First non-comment, non-empty line is the subject.
subject="$(grep -m1 -E '^[^#]' "$msg_file" || true)"
subject="${subject%$'\r'}"  # strip trailing CR if present

if [ -z "$subject" ]; then
    echo "commit-msg: empty subject" >&2
    exit 1
fi

len=${#subject}
if [ "$len" -gt 72 ]; then
    echo "commit-msg: subject is $len chars (>72): $subject" >&2
    exit 1
fi

# Match: <scope>: <one-or-more chars>
# Scope = alphanumerics, _ . / - (matches existing patch scopes like pkg/lps, build.sh)
if ! [[ "$subject" =~ ^[A-Za-z0-9_./-]+:\ .+$ ]]; then
    cat >&2 <<EOF
commit-msg: subject must be "<scope>: <subject>"
  got: $subject
  examples:
    zedagent: fix nil panic in parseEdgeNodeInfo for LOC configs
    pkg/lps: introduce Local Profile Server package
    build.sh: Add script to build ms-01 installer
EOF
    exit 1
fi

# Common merge/revert/fixup prefixes — allow without scope check.
# (Git generates these automatically; refusing them just irritates the user.)
case "$subject" in
    "Merge "* | "Revert "* | "fixup! "* | "squash! "* | "amend! "*)
        exit 0
        ;;
esac

exit 0
