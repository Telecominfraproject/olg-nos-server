---
description: Amend an existing patch in the olg-eve series
---

You are amending an existing patch in the olg-eve series. Read
`CLAUDE.md` first.

**Arguments describe which patch to edit and what to change.** Argument
form: a patch number (`0007`), a subject substring (`nil panic`), or a
file path (`pkg/pillar/cmd/zedagent/parseedgenodeinfo.go`). The first
argument identifies the patch; the rest describe the change.

Workflow:

1. **Identify the patch**
   - If the user gave a number: `ls patches/<NNNN>-*.patch`.
   - If a substring: `grep -l <substring> patches/*.patch` and confirm
     one match.
   - If a path: `./tools/patches-which.py <path>` — if multiple, ask the
     user which one to amend.
   - Show the patch's full subject and file list before proceeding.

2. **Preconditions**
   - `git -C eve status -s` clean.
   - `git -C eve log --oneline bf6e6e259f18a3d87efa0493fbbbddcdd31e4359..HEAD | wc -l`
     should equal the count of `patches/*.patch`.

3. **Interactive rebase to the target patch**
   - In `eve/`, run an interactive rebase off the upstream base:
     `git rebase -i bf6e6e259f18a3d87efa0493fbbbddcdd31e4359`
   - But you can't run interactive rebase non-interactively. Instead,
     use `GIT_SEQUENCE_EDITOR` to script the pick→edit transformation,
     OR use `git rebase --onto` with cherry-picks. The cleanest
     non-interactive approach:

     ```
     N=<patch number, e.g. 7>
     # find commit SHA at depth (total - N + 1) from upstream-base, on the
     # currently-applied series. Equivalent: the N-th commit reachable
     # from upstream-base.
     target=$(git -C eve rev-list --reverse bf6e6e259f18a3d87efa0493fbbbddcdd31e4359..HEAD | sed -n "${N}p")
     git -C eve checkout "$target"  # detached
     ```

   - Now `HEAD` is at the patch to amend; ancestors of it remain applied.
     Descendants are not in the working tree yet; they'll be replayed via
     cherry-pick after the amend.

4. **Make the change & amend**
   - Edit the files inside `eve/`. Build the affected package to confirm
     compilation.
   - `git -C eve add -A && git -C eve commit --amend --no-edit` (or
     `--edit` if changing the subject — but then update the scope tag if
     applicable).

5. **Replay descendants**
   - Cherry-pick every commit that was on top of the original target:
     ```
     for c in $(git -C eve rev-list --reverse "$target..main-prev"); do
         git -C eve cherry-pick "$c"
     done
     ```
   - If a conflict occurs, surface it. The user must resolve.

6. **Regenerate patches & verify**
   - `./setup.py --update`
   - `./tools/gen-patches-readme.py`
   - `./tools/verify.sh`

7. **Commit on main**
   - `git diff patches/` should show only the patches that genuinely
     changed (the amended one, plus any whose context lines shifted).
   - Commit: `git commit -am "<scope>: <amend reason>"` or a separate
     message describing the amendment.

**Hard rules:**
- If multiple patches need to change to express the user's intent, do
  them one at a time. Don't batch.
- Never hand-edit `patches/*.patch`.
- If the amend changes the subject, update `patches/README.md` via the
  generator.

Arguments: $ARGUMENTS
