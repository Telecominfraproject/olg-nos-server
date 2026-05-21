# CLAUDE.md — olg-eve

Context for any AI agent invoked in this repo. Read this first.

## What this repo is

A **patches-on-upstream fork** of [`lf-edge/eve`](https://github.com/lf-edge/eve)
pinned at `bf6e6e259f18a3d87efa0493fbbbddcdd31e4359`. The repo itself is
small (~30 tracked files). At build time, `setup.py` clones upstream EVE
into a gitignored `eve/` directory and applies the patches in `patches/`
with `git am -3`. Modeled on wlan-ap's workflow.

The upstream pin lives in `config.yml`.

## Three things to keep straight

1. **`patches/` is derived. Don't hand-edit `.patch` files.** Make changes
   in the `eve/` checkout, commit them as proper git commits, then run
   `./setup.py --update` from the repo root to regenerate `patches/`.

2. **`profiles/` lives on `main`, not in patches.** `ms-01.yml` and
   `qemu.yml` are editable repo content. `setup.py` symlinks them into
   `eve/profiles` after applying patches. Never include `profiles/` changes
   inside a patch — they'd conflict with the symlink.

3. **`eve/` is gitignored.** It's a fresh upstream clone + patches, not
   your work. Anything you do there only persists by either landing as a
   patch (via `--update`) or being lost on the next `--rebase`.

## The dev loop

| Goal | Steps |
|---|---|
| Add a new patch | `cd eve` → edit + commit with `<scope>: <subject>` message → `cd .. && ./setup.py --update` → review `patches/` diff → commit on `main` |
| Edit existing patch N | `cd eve` → `git rebase -i bf6e6e259f18a3d87efa0493fbbbddcdd31e4359` → mark patch N `edit` → amend → continue → `cd .. && ./setup.py --update` |
| Reorder / drop patches | Same as above, reorder or `drop` lines in interactive rebase |
| Bump upstream eve | Edit `config.yml` `revision:` → `./setup.py --rebase` → resolve any `git am -3` conflicts in `eve/` → `./setup.py --update` |
| Edit profile YAMLs | Edit `profiles/*.yml` directly on `main`. No setup needed; `eve/profiles` is a symlink to it. |

## Verification

Before opening a PR on `main`:

```sh
./tools/verify.sh           # fresh setup + clean apply of all patches
```

This runs `setup.py --setup` in a sandbox directory and confirms every
patch applies with `git am -3` against a clean upstream clone. Catches
the most common breakage (patch conflicts with itself, dependency on
prior patch removed, etc.). Wired into CI on every PR.

For build validation:
- `cd eve && make pkg/<name>` — partial build of a single package (~5GB, fast)
- `./build.sh ms-01` — full installer build (~30GB, slow)

## Patch series introspection

```sh
./tools/patches-which.py <path>      # "which patches touch this file?"
./tools/gen-patches-readme.py        # regenerate patches/README.md table
```

`patches/README.md` is auto-generated. Don't hand-edit it; run the
generator.

## Commit message convention

Patches use `<scope>: <subject>` where scope is a short tag matching the
area of code (`zedagent`, `gen-loc-config`, `pkg/lps`, `Makefile`,
`build.sh`, `downloader`, `dpcmanager`, etc.). Subject is a single line,
≤ 72 chars, imperative-ish.

A `commit-msg` hook can be installed into the `eve/` checkout via
`./tools/install-eve-hooks.sh`. CI also enforces the convention on
new patches.

## File map

```
config.yml             # pins lf-edge/eve revision
setup.py               # --setup / --rebase / --update orchestrator
build.sh               # full build entry (target-patches → setup → eve build)
dock-run.sh            # docker wrapper (setup-only; no docker socket)
docker/Dockerfile      # toolchain image (Ubuntu 22.04 + Go + Docker CLI)
Makefile               # ./dock-run.sh ./build.sh $(TARGET)
cache-setup.sh         # per-revision dist cache symlink

patches/*.patch        # numbered patch series applied to upstream eve
patches/README.md      # auto-generated table; regenerate via tools/gen-patches-readme.py
profiles/*.yml         # per-target profile YAMLs; symlinked into eve/profiles

tools/patches.py            # patch-series parsing library
tools/patches-which.py      # CLI: "which patches touch path X?"
tools/gen-patches-readme.py # regenerate patches/README.md
tools/check-commit-msg.sh   # validates <scope>: <subject> format
tools/install-eve-hooks.sh  # installs commit-msg hook into eve/.git/hooks/
tools/verify.sh             # fresh setup + clean apply check

.github/workflows/verify.yml  # CI: runs tools/verify.sh on PRs
.claude/commands/             # slash-command skills for common patch ops
```

## Hard rules

- **Never `--no-verify` commits** — let the commit-msg hook do its job.
- **Never edit `patches/*.patch` by hand** — use `--update`.
- **Never put `profiles/` changes inside a patch** — they live on `main`.
- **Never push to `origin`** without running `tools/verify.sh` first.
- **Never bump the upstream pin without testing** — `--rebase` + a smoke
  build before committing the new `revision:` to `main`.

## Tone / strategic context

See `STRATEGIC.md` (gitignored) for the project's confidential strategy
notes. Public-facing text (commit messages, README, CI output) should
read project-neutral: "OLG customizations layered on upstream lf-edge/eve".
