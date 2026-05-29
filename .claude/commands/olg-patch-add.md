---
description: Add a new patch to the olg-eve patch series
---

You are adding a new patch to the olg-eve patch-on-upstream series. Read
`CLAUDE.md` first for context.

**The arguments to this command describe the change being added.** Treat
them as the *intent* of the new patch (e.g., "fix dpcmanager leak when
ethX disappears" or "add cloud-init support to gen-loc-config").

Workflow (follow exactly):

1. **Confirm preconditions**
   - `cd` to the olg-eve repo root (look for `config.yml`).
   - Verify `eve/` exists and is at the expected state: run
     `git -C eve log --oneline | head -3` — top of log should be a
     recent patch from `patches/`. If `eve/` is missing, run
     `./setup.py --setup` first.
   - Verify the working tree on `main` is clean: `git status -s` empty.

2. **Find the right scope**
   - Look at existing patch scopes via `head -1 patches/README.md ; head
     -30 patches/README.md | tail -20`.
   - If unclear which scope fits, ask the user. Don't invent a new scope
     casually.
   - Use `./tools/patches-which.py <relevant-path>` to see which patches
     already touch that area — your new patch might belong as an
     amendment to an existing one rather than a new commit (in which case,
     use `/olg-patch-edit` instead).

3. **Make the change in `eve/`**
   - All edits happen inside the `eve/` checkout. Never edit `patches/*.patch` by hand.
   - Implement the change. Build the affected package locally to confirm
     it compiles: `cd eve && make pkg/<name>`.

4. **Commit in `eve/`**
   - `cd eve && git add -A && git commit -m "<scope>: <subject>"`
   - Subject must follow the format. The `commit-msg` hook (if installed
     via `tools/install-eve-hooks.sh`) will enforce it.
   - If the change is non-obvious, include a body explaining *why*, not
     *what*.

5. **Regenerate the patch series**
   - `cd .. && ./setup.py --update`
   - This wipes `patches/` and re-runs `git format-patch` over the eve
     checkout. Your new commit becomes the last numbered `.patch` file.

6. **Update the README**
   - `./tools/gen-patches-readme.py` — regenerates `patches/README.md`.

7. **Verify**
   - `./tools/verify.sh` — fresh-applies the whole series in a sandbox.
     Must pass.

8. **Commit on main**
   - `git add patches/ && git commit -m "<scope>: <subject>"` (same
     message as the patch commit).
   - Show the user `git log -1 --stat` so they can see exactly what
     lands.

**Hard rules:**
- Never use `git commit --no-verify`.
- Never hand-edit `patches/*.patch` files.
- Never touch `profiles/` in a patch — those live on `main`.
- Never push to `origin` without the user explicitly asking.

If any step fails (build, hook, verify), stop and surface the failure.
Don't paper over it.

Arguments: $ARGUMENTS
