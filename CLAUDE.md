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

To get a valid qcow2 in place before `./build.sh qemu`:

- **From scratch** — `./build-vyos.sh --install` clones the vyos-build
  upstream pinned in `services/vyos/config.yml`, applies the patches in
  `services/vyos/patches/`, runs the build in a `--privileged` Docker
  container, and drops the resulting qcow2 into `eve/pkg/lps/images/`.
  Then rebuild: `cd eve && make pkg/lps && cd .. && ./build.sh qemu`.
- **From a pre-built copy** — drop the qcow2 directly under
  `eve/pkg/lps/images/` and confirm its sha256 matches what
  `profiles/qemu.yml` declares.

The vyos-build pipeline lives entirely under `build-vyos.sh` (root) +
`services/vyos/`. It's separate from the EVE build and the `vyos-build/`
checkout is gitignored. See the script's `--help` for flags.

### Swapping the bundled VyOS qcow2

Every rebuild of the VyOS image produces a different byte-for-byte
artifact. LPS validates `image.sha256` and `image.size` in the profile
against what it serves, so the profile and the bundled file must move
together. The full round-trip when the qcow2 changes:

```sh
new=/path/to/new/small-vyos-ssh-nat.qcow2

# 1. Compute and patch the profile in this repo
sha=$(sha256sum "$new" | awk '{print $1}')
size=$(stat -c%s "$new")
sed -i -e "s|^  sha256: .*|  sha256: $sha|" \
       -e "s|^  size:   .*|  size: $size  # bytes|" profiles/qemu.yml

# 2. Stage into the LPS package (must match the path the patch declares)
cp "$new" eve/pkg/lps/images/small-vyos-ssh-nat.qcow2

# 3. Rebuild LPS, then the EVE image
cd eve && make pkg/lps && cd ..
./build.sh qemu
```

Skip any step and EVE either won't bundle the new image (step 2) or
LPS will refuse to serve it (step 1, hash mismatch). The patches do
**not** touch `profiles/qemu.yml` — it's editable repo content on
`main` and symlinked into `eve/profiles` at setup time.

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
cd eve && make E1000E=1 run-live  # boots live.qcow2 with KVM + swtpm
                                  # hostfwd 2222 → guest 22,
                                  # serial on  eve/eve-serial.sock (unix socket)
                                  # monitor on eve/eve-mon.sock    (unix socket)
                                  # QMP     on eve/qmp.sock
```

**`E1000E=1` is required.** The `qemu` profile pins two PCIe-passthrough
NICs (`pt_e1k0` / `pt_e1k1` at `0000:01:00.0` / `0000:02:00.0`) into the
VyOS guest. Without `E1000E=1`, the outer QEMU launches no e1000e
devices, EVE's pillar can't bind vfio for them, and the VyOS app
short-circuits to **`BROKEN`** with `AdaptersFailed=true`,
`Error="driver_override failure for PCI device 0000:01:00.0:
no such host device"`. The Makefile's `QEMU_OPTS_e1000e` block in
the eve patch series exposes two e1000e behind dedicated
`pcie-root-port`s with MACs `52:54:00:e1:00:00` / `:01` matching the
profile.

### Attaching to the EVE serial

`make run-live` no longer pins serial to stdio — the EVE serial is exposed
on a unix-domain chardev so multiple consumers (script + human) can attach
or detach without restarting QEMU. Attach with:

```sh
socat -,raw,echo=0,escape=0x1d UNIX-CONNECT:eve/eve-serial.sock
# Ctrl-]  detaches.   Ctrl-A C  is no longer needed (there is no mux on
# this serial; the QEMU monitor lives on a separate eve-mon.sock).
```

Or use `tio` (the same tool `eve app console` shells out to internally) —
its escape is `Ctrl-T q`:

```sh
tio unix:eve/eve-serial.sock
```

For headless log capture without occupying the terminal:

```sh
ts=$(date +%Y%m%d-%H%M%S)
mkdir -p ../.qemu-runs/$ts
socat -u UNIX-CONNECT:eve/eve-serial.sock - >../.qemu-runs/$ts/serial.log &
```

The QEMU monitor is on `eve/eve-mon.sock` — connect with the same socat
recipe pointed at that path to send `info`, `system_reset`, `sendkey`, etc.

EVE's kernel serial output goes quiet once linuxkit finishes onboot and
services attach to containerd. From that point onwards introspect via
SSH / pubsub files rather than the serial log — see next section.

## Flashing EVE to hardware

Two build outputs matter for hardware deploys (e.g. `./build.sh ms-01`):

| File | Path | Purpose |
|---|---|---|
| `installer.raw` | `eve/dist/amd64/snapshot/installer.raw` | Bootable USB image. dd to a stick, boot the target, installer lays down EFI + IMGA + IMGB + CONFIG + persist on the internal disk. |
| `installer/rootfs.img` | `eve/dist/amd64/snapshot/installer/rootfs.img` | Raw squashfs for one A/B partition. dd directly to the inactive `IMGB` (or `IMGA`) partition over SSH to upgrade without USB — the SSH-based "Fix F" flow. Only works once the target has been installed with patch 0030 (IMGB ≥ 2 GB). |

### First install — USB flash with dd

1. **Identify the USB device.** Plug the stick in, watch `dmesg`:

   ```sh
   sudo dmesg --follow
   # ... usb 1-2: new high-speed USB device number 7 using xhci_hcd
   # ... sd 0:0:0:0: [sdX] Attached SCSI removable disk
   ```

   Or list block devices and pick the one whose size matches the stick (NOT
   the host's internal NVMe/SSD):

   ```sh
   lsblk -o NAME,SIZE,MODEL,TRAN
   ```

2. **Unmount any auto-mounted partitions** (some desktops automount):

   ```sh
   for p in /dev/sdX*; do sudo umount "$p" 2>/dev/null; done
   ```

3. **Flash.** Replace `sdX` with the device from step 1 (no partition
   number — write to the whole device). Don't typo this — `dd` will
   happily overwrite the wrong disk:

   ```sh
   sudo dd if=eve/dist/amd64/snapshot/installer.raw \
           of=/dev/sdX \
           bs=4M status=progress conv=fsync
   sync
   ```

   `bs=4M` chunks for throughput, `status=progress` shows pace,
   `conv=fsync` forces a flush at end so the USB isn't ejected with
   data still in cache.

4. **Boot the target from the USB.** F12 / F2 / Del to enter the boot
   menu varies per BIOS. On the MS-01, press **F7** during the splash
   for one-shot boot menu, pick the USB stick.

5. **Installer runs unattended** — it dd's the rootfs into IMGA, writes
   IMGB as an empty 2 GB partition (per patch 0030), creates CONFIG +
   persist, then reboots. The target is now installed; remove the USB.

### What the installer lays down

After install, the target's internal disk has:

```
nvme0n1p1  EFI System  36M    vfat
nvme0n1p2  IMGA        2 GB   squashfs   ← currently active (rootfs.img copied here)
nvme0n1p3  IMGB        2 GB   (empty placeholder for upgrades)
nvme0n1p4  CONFIG      1M     vfat       (LPS profile, server URL, device UUID)
nvme0n1p9  P3          rest   ext4       (/persist: logs, app volumes, vault)
```

Verify on a freshly-installed box via SSH:

```sh
ssh -i ~/.ssh/id_ed25519 root@<eve-ip>
lsblk -o NAME,SIZE,PARTLABEL,FSTYPE
/hostfs/usr/bin/zboot curpart                  # → IMGA after first install
```

### In-place upgrade over SSH (Fix F sketch — tooling pending)

Once patch 0030 has laid down a 2 GB IMGB, future EVE upgrades skip the
USB entirely:

```sh
# On the build host (you):
scp eve/dist/amd64/snapshot/installer/rootfs.img \
    root@<eve-ip>:/persist/rootfs-next.img

# On the EVE target (SSH'd in):
zboot=/hostfs/usr/bin/zboot
$zboot curpart                                 # → IMGA  (so flash IMGB)
INACTIVE=IMGB
DEV=$(lsblk -nrpo NAME,PARTLABEL | awk -v p=$INACTIVE '$2==p{print $1}')
dd if=/persist/rootfs-next.img of="$DEV" bs=4M status=progress conv=fsync
sync

# Mark the new partition for next boot and reboot:
$zboot set_next_part $INACTIVE
reboot
```

After reboot, `zboot curpart` will report `IMGB`. Roll back by running
`zboot set_next_part IMGA && reboot` from the new image (the old image
is untouched). **This flow is not yet scripted in the repo** — wrap it
in `tools/ssh-upgrade.sh` once tested end-to-end.

### Boot expectations on the ms-01 profile

First boot after install, with **no cable connected to any NIC**, with
the current patch series (Fix A + Fix G + Fix H + IMGB-2GB + profile
swap):

| Phase | Timing | Evidence |
|---|---|---|
| EVE kernel + linuxkit onboot | ~30-60s | grep serial / journal for `EVE is alive` |
| **DPC verify bypass (Fix H)** | ~60-90s | `logread \| grep "skipping uplink connectivity test"` |
| zedrouter creates LMP bridge `eth3` | shortly after | `ip link show eth3` |
| **LPS attaches `lmp-keep-up` dummy (Fix G)** | shortly after | `logread \| grep "lmp-keep-up"` |
| VyOS launches | ~90-150s | `eve app list` → vyos `RUNNING` |
| VyOS' kea ready, EVE `bn1` gets `192.168.33.2` lease | ~3-7 min | `ip -4 addr show eth3` shows `192.168.33.2/24` |

If VyOS reaches RUNNING but `192.168.33.1` is unreachable, you're likely
hitting the gen-loc-config MAC-inversion bug (`[[reference_vyos_lmp_mac_inverted]]`
in memory) — separate fix.

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

`eve app console <id>` shells out to **`tio`** (a serial-port terminal,
not xenconsole). It insists on a real tty for stdin — non-interactive
attaches fail with `Saving current stdin settings failed`. For scripts
either allocate a pty (`ssh -tt … 'eve app console <id>'`) or scrape
the dom serial from outside. Detach with **`Ctrl-t q`** (tio's escape;
`Ctrl-]` won't work).

### `eve app console` looks dead until you send `Ctrl-a c`

The per-guest serial chardev in `xen1.cfg` is created with `mux = "on"`
(generated by `eve/pkg/pillar/hypervisor/kvm.go:218`). A muxed chardev
has two input frontends — the guest serial and the QEMU monitor — and
the default focus is on the **monitor**, so anything you type into
`eve app console` is silently consumed by the monitor and never reaches
the guest agetty. Output (guest → host) works fine in both directions,
so the console *looks* alive: boot log scrolls, login prompt appears,
but keystrokes vanish.

**Recipe** for `eve app console`:

1. Attach: `eve app console <UUID>.1.1/cons`
2. Once `Connected` appears, type **`Ctrl-a c`** once to flip the mux's
   input focus from monitor to console.
3. Normal interaction works from then on. tio's own escape is `Ctrl-t`,
   so `Ctrl-a` passes through unmodified.
4. Detach with **`Ctrl-t q`** (tio's escape).

Same approach via raw socat (for scripting):
```sh
( sleep 2; printf '\x01c'; sleep 1; printf '\r'; ... ) | \
  socat - UNIX-CONNECT:/run/hypervisor/kvm/<uuid>.1.1/cons
```

**Caveat: mux state is per-chardev and persists across socket clients.**
If a previous session already toggled the focus to "console", a fresh
`Ctrl-a c` flips it *back* to "monitor". When in doubt: send `Ctrl-a c`,
send `\r`, look for a prompt. If silent, send `Ctrl-a c` again.

The earlier "agetty must be on /dev/hvc0" theory was wrong — the mux
input frontend is wired to `/dev/ttyS0` (the `-serial chardev:charserial0`
backend), and the auto-spawned `serial-getty@ttyS0` (from `console=ttyS0`
on the cmdline) is what receives the keystrokes. No custom chroot hook
needed on the VyOS image.

**True upstream fix** (not currently applied) would be to set `mux = "off"`
in `eve/pkg/pillar/hypervisor/kvm.go` and ship that as a patch. With the
`Ctrl-a c` workaround documented, the upstream change isn't required.

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

### Recovering from a killed / failed eve build

`linuxkit-builder` is a long-lived `moby/buildkit` container with an
anonymous volume mounted at `/var/lib/buildkit` for its layer cache. If
a build is killed mid-flight (Ctrl-C, OOM, disk-full) the container is
left in `Exited` state and the volume keeps its in-progress layers —
routinely 40–50 GB. That volume is **not** visible to `docker buildx du`
(separate buildkit instance) and **not** reclaimed by
`docker system prune` or `docker volume prune -f` while the container
still references it.

Recovery, in order:

```sh
docker rm -v linuxkit-builder   # drops container AND its anon volume
docker volume prune -f          # mop up orphans
docker image prune -af          # unused images
df -h /
```

The next `make pkg/<x>` recreates `linuxkit-builder` with an empty
cache — so the first rebuild is slow, but subsequent ones cache
normally. Don't try to `buildctl prune` the live container first;
the buildkit DB only knows about layers it produced *after* the most
recent build, not the half-written ones the kill left behind.

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
- **Hardware (PCIe-passthrough) NICs aren't covered by gen-loc-config's
  hw-id binding.** The hw-id-for-every-VIF patch only knows MACs for
  EVE-managed VIFs (switch NIs, uplink, LMP). For vendor-MAC NICs on
  hardware, runtime MAC discovery is needed — read
  `/sys/bus/pci/devices/<addr>/net/<iface>/address` in LPS at boot and
  substitute into the cloud-init template before the cidata is built.
  This is the "Patch B" follow-up; tooling for testing it under QEMU
  (e1000 NICs at fixed PCI slots) is scaffolded but not committed.

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
