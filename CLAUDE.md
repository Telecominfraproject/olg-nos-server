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

   Note: `grep profiles/ patches/*.patch` will hit two patches (`0002`
   code comment, `0010` Makefile variable). Those are intentional string
   mentions of the path resolved at runtime through the symlink, not
   diff-header file changes. The "no patch touches `profiles/`" rule
   means **no diff header for a `profiles/` path**, not literal grep
   absence.

3. **`eve/` is gitignored.** It's a fresh upstream clone + patches, not
   your work. Anything you do there only persists by either landing as a
   patch (via `--update`) or being lost on the next `--rebase`.

## Host prerequisites

The build and run-under-QEMU loop assumes these are on the host:

- `docker` (daemon running, user in `docker` group)
- `qemu-system-x86_64`, `qemu-utils`
- `swtpm`, `swtpm-tools` — required by `make run-live` for the EVE vTPM
- `ovmf` — UEFI firmware
- `socat` — QMP / Unix socket talk-to during tests
- `python3` + `python3-yaml`
- `git` (with `git-lfs` filter configured)

If something is missing, **ask the user** — do not autonomously
`apt install` / `brew install` / etc. See the no-install hard rule below.

## Hidden build input: the VyOS qcow2

`pkg/lps/Dockerfile` copies `pkg/lps/images/*.qcow2` into
`/usr/share/lps/images/` on the built EVE image; LPS then seeds them to
`/persist/lps/images/` on first boot. The qcow2 is tracked with git-lfs
in upstream.

**Foot-gun:** a fresh `setup.py --setup` does not pull LFS objects, so
the build silently produces an LPS package without VyOS. The QEMU live
image still boots and EVE comes up, but `eve app list` will show VyOS
in a launching loop (or just absent) because LPS has nothing to serve.

Before any test that needs VyOS to actually start, drop the qcow2 into
`eve/pkg/lps/images/` and confirm its sha256 matches what the relevant
profile (`profiles/qemu.yml` etc.) declares — then rebuild
`make pkg/lps` and the image target. A copy may already be cached
on the dev box under `/home/vm/rebase/eve/pkg/lps/images/`.

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
- `./build.sh <profile>` — full image build

Image kind is picked per profile by `build.sh`:

| Profile | Make target | Output filename |
|---|---|---|
| `qemu` | `live` | `eve/dist/amd64/snapshot/live.{raw,qcow2}` |
| anything else | `installer` | `eve/dist/amd64/snapshot/installer.raw` |

The `qemu` profile is meant to boot directly under QEMU; hardware
targets ship as an installer image that lays EVE down on the target's
disk.

`dock-run.sh`'s wrapper container **does not mount `/var/run/docker.sock`**,
so `./build.sh` invoked via `make TARGET=…` cannot drive the eve
linuxkit build inside. Use native `./build.sh <profile>` for full image
builds; the Docker wrapper is good for the setup-only path only.

## Booting EVE under QEMU

After `./build.sh qemu`, eve's upstream Makefile has the run target wired up:

```sh
cd eve && make run-live           # boots live.qcow2 with KVM + swtpm
                                  # serial on stdio, hostfwd 2222 → guest 22,
                                  # QMP socket at eve/qmp.sock
```

Headless / log-capture pattern used under `.qemu-runs/`:

```sh
ts=$(date +%Y%m%d-%H%M%S)
mkdir -p ../.qemu-runs/$ts
make run-live </dev/null >../.qemu-runs/$ts/serial.log 2>&1 &
```

EVE's kernel serial output goes quiet once linuxkit finishes onboot and
services attach to containerd. From that point onwards introspect via
SSH / pubsub files rather than the serial log — see next section.

## Inspecting a running EVE / guest VMs

SSH into EVE host:

```sh
ssh -p 2222 -i ~/.ssh/id_ed25519 root@localhost
# key comes from profiles/<target>.yml ssh_key field, deployed by LPS
```

EVE CLI (inside the host):

```sh
eve app list            # guest VMs: DisplayName / UUID / Type / Status
eve status              # service-level RUNNING/PAUSED for pillar/lps/...
eve hv                  # hypervisor mode (kvm/xen)
eve app console         # list available app consoles
eve app console <id>    # attach to a guest VM's serial console (interactive)
```

Pubsub state for a guest VM (more detail than `eve app list`):

```
/run/domainmgr/DomainStatus/<uuid>.json    # State=115 means RUNNING, plus VifList, errors
/run/domainmgr/DomainMetric/<uuid>.json    # live CPU/memory metrics
/run/domainmgr/cloudinit/<uuid>.cidata     # ISO9660 cloud-init image (mount -o loop,ro to inspect)
/persist/lps/images/                       # LPS-seeded guest disk images
```

SSH into an inner guest VM (VyOS in the qemu profile), via EVE as
jump host:

```sh
ssh -J root@localhost:2222 admin@<vyos-wan-ip>
# default vyos-wan-ip on qemu profile: 192.168.2.11 (QEMU dhcpstart on EVE eth1)
# password from profile vyos.commands ('yourpassword' in the current qemu profile)
```

To capture EVE serial events into a Monitor while a run is in flight,
grep for boot/service/failure markers — silence is not success, include
crash signatures:

```
EVE is alive|systemd|reached target|login:|pillar|lps|domainmgr|launch.*domain|
kernel panic|Oops|Killed|no space left
```

## Patch series introspection

```sh
./tools/patches-which.py <path>      # "which patches touch this file?"
./tools/gen-patches-readme.py        # regenerate patches/README.md table
```

`patches/README.md` is auto-generated. Don't hand-edit it; run the
generator.

## Cache / dist layout

`setup.py --setup` invokes `cache-setup.sh <revision>` during
`reset_tree`, which symlinks `eve/dist` → `../cache/<revision>/dist`.
Build artifacts therefore survive `rm -rf eve/` and are reused across
re-clones at the same upstream pin.

To force a clean rebuild of a specific artifact, delete from the cache,
not from the (symlinked) `eve/dist`:

```sh
rm -f cache/<rev>/dist/amd64/snapshot/live.*    # or installer.*, target.img, etc.
./build.sh <profile>
```

BuildKit prunes redundant layers automatically during builds — disk
usage often drops mid-build, don't be surprised.

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
cache-setup.sh         # per-revision dist cache symlink (eve/dist -> ../cache/<rev>/dist)

patches/*.patch        # numbered patch series applied to upstream eve
patches/README.md      # auto-generated table; regenerate via tools/gen-patches-readme.py
profiles/*.yml         # per-target profile YAMLs; symlinked into eve/profiles
.qemu-runs/<ts>/       # per-run serial logs / disks from booting under QEMU (gitignored)

tools/patches.py            # patch-series parsing library
tools/patches-which.py      # CLI: "which patches touch path X?"
tools/gen-patches-readme.py # regenerate patches/README.md
tools/check-commit-msg.sh   # validates <scope>: <subject> format
tools/install-eve-hooks.sh  # installs commit-msg hook into eve/.git/hooks/
tools/verify.sh             # fresh setup + clean apply check
tools/qemu/boot.sh          # boot installer.raw under qemu with serial capture

.github/workflows/verify.yml  # CI: runs tools/verify.sh on PRs
.claude/commands/             # slash-command skills for common patch ops
```

## Known qemu-profile gaps (TODO)

These are known shortcomings in the `qemu` profile / `gen-loc-config`
output, not breakages in build or boot. Fix them in dedicated patches
when prioritized:

- **VyOS LAN bridge stays link-down.** cloud-init only sets `hw-id` on
  `eth0`; nothing brings the port up. `br0` (`192.168.1.1/24`) is
  configured but `linkdown`, so the VyOS DHCP server can't bind.
  Fix lives in `pkg/pillar/cmd/gen-loc-config` VyOS cloud-init template
  — add a `set interfaces ethernet eth0 description …` (or similar)
  to mark the interface administratively up.
- **Profile `ssh_key` is EVE-only.** The `ssh_key` field in
  `profiles/<target>.yml` is honored by LPS for SSH into EVE host but is
  not propagated to the VyOS cloud-init template. Only the
  `admin / yourpassword` credential set up by `vyos.commands` works for
  SSH into VyOS. Either drop `ssh_key` from `qemu.yml` to remove the
  confusion or thread it through into the cloud-init `user-data`.

## Hard rules

- **Never `--no-verify` commits** — let the commit-msg hook do its job.
- **Never edit `patches/*.patch` by hand** — use `--update`.
- **Never put `profiles/` changes inside a patch** — they live on `main`.
- **Never push to `origin`** without running `tools/verify.sh` first.
- **Never bump the upstream pin without testing** — `--rebase` + a smoke
  build before committing the new `revision:` to `main`.
- **Never autonomously install host packages.** If a build/test needs a
  missing tool (`swtpm`, `socat`, `paramiko`, …) stop and ask the user
  to install it. No `sudo apt`, no `pip install`, no `brew install`.

## Tone / strategic context

See `STRATEGIC.md` (gitignored) for the project's confidential strategy
notes. Public-facing text (commit messages, README, CI output) should
read project-neutral: "OLG customizations layered on upstream lf-edge/eve".
