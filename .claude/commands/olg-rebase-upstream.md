---
description: Rebase the patch series onto a newer upstream eve revision
---

You are bumping olg-eve's pinned upstream commit. Read `CLAUDE.md` first.

**Argument: the new upstream commit SHA (or branch ref like `master`).**
Example: `/olg-rebase-upstream 0aa8e0bcd` or `/olg-rebase-upstream master`.

This is a higher-risk operation than `/olg-patch-add` — upstream changes
can conflict with patches. Walk carefully.

Workflow:

1. **Snapshot the current state**
   - Note the current revision: `grep '^revision:' config.yml`.
   - Note the current patch count: `ls patches/*.patch | wc -l`.

2. **Validate the new revision exists**
   - `git -C eve fetch origin`
   - `git -C eve rev-parse <new>^{commit}` (must resolve).
   - If the new ref is a branch like `master`, resolve to a concrete SHA
     first and pin that SHA, not the branch name (revisions move).

3. **Try the rebase**
   - Update `config.yml` `revision:` to the new SHA.
   - Run `./setup.py --rebase`.
   - One of three outcomes:

     **A. Clean apply.** All patches `git am -3` cleanly. Proceed to
     verify.

     **B. Conflicts.** `git am` halts. Inside `eve/`:
        - Inspect the failing patch: `cat .git/rebase-apply/patch` or
          `git status`.
        - Resolve conflicts in the working tree.
        - `git add <resolved>` then `git am --continue`.
        - Repeat for any further conflicting patches.

     **C. Patch obsoleted by upstream.** The change has already landed
     upstream. Run `git am --skip`. Note which patch was skipped — you
     must drop it from the series before regenerating.

4. **Regenerate patches**
   - `./setup.py --update`
   - The new patch series reflects the resolved state. Count: expect
     equal to or fewer than the previous count (if any patches were
     skipped as obsolete).

5. **Refresh metadata**
   - `./tools/gen-patches-readme.py`
   - Sanity-check the diff in `patches/README.md` — only changed-subject
     rows should differ.

6. **Verify**
   - `./tools/verify.sh` — must pass.
   - `./tools/verify.sh --build pkg/pillar` — additionally validates that
     pillar still compiles against the new upstream. Slow but worth it
     before committing.

7. **Commit on main**
   - The commit should bundle: `config.yml` (revision bump), `patches/`
     (all regenerated), `patches/README.md`.
   - Message: `upstream: rebase to <short-sha> (<date-or-tag>)`.
   - Include in the body: the previous SHA, the new SHA, any patches
     that were dropped because upstream absorbed them.

**Hard rules:**
- Never commit a config.yml that points at a branch ref (`master`,
  `main`). Always a concrete SHA.
- Never push the rebased main without a successful `verify.sh` run.
- If pillar fails to build against the new upstream, do NOT commit; ask
  the user how to proceed.
- If a conflict resolution required non-trivial code judgment (not just
  context fixup), stop and surface it to the user before continuing.

Arguments: $ARGUMENTS
