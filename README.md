# olg-nos-server

OLG customizations layered on top of [lf-edge/eve](https://github.com/lf-edge/eve).
At build time, upstream EVE is cloned into a local `eve/` directory and the
patches in `patches/` are applied with `git am -3`.

## Building

### Setting up your build machine

A recent Linux installation with Docker is required. The build runs inside
the container defined in `docker/Dockerfile`.

Install Docker on Debian/Ubuntu:
```
sudo apt install docker.io
sudo usermod -aG docker $USER  # log out / back in to pick up the group
```

### Native build

Use `./build.sh <profile>`, or follow the manual steps below:

1. Clone and set up the tree. This will create an `eve/` directory.
```shell
./setup.py --setup    # for subsequent builds, use --rebase instead
```

2. Build the installer for a profile (e.g. `ms-01`):
```shell
cd eve
make pkg/pillar
make pkg/lps
make HV=kvm ROOTFS_VERSION=snapshot LPS_PROFILE=ms-01 installer
```

### Dockerized build

```shell
make TARGET=ms-01
```

This invokes `dock-run.sh` to build the toolchain image and runs `build.sh`
inside it.

### Build output

Installer images and intermediate artifacts land in `eve/dist/` (eve's
default output path).

## Developer Notes

### Branching model

- `main` — patches + scripts; tracks a pinned upstream EVE commit
- `lps` — legacy: full eve fork with OLG commits on top of upstream

### Repository structure

Build files:
- `Makefile` — calls the Dockerized build environment per target
- `dock-run.sh` — Docker build wrapper
- `docker/Dockerfile` — toolchain image (Go, Docker CLI, QEMU, Python)
- `build.sh` — build orchestration (target-patches → setup.py → eve build)
- `setup.py` — clone EVE at the pinned revision and apply patches
- `config.yml` — pins EVE repo URL, branch, and revision

Directories:
- `patches/` — numbered `git am`-style patches applied to upstream EVE
- `profiles/` — per-target profile YAMLs (e.g. `ms-01.yml`, `qemu.yml`).
  Currently shipped via patches; can also be edited here once symlinked
  into the eve checkout
- `target-patches/` — per-target patches applied to the EVE checkout with
  plain `patch -p1` before the build runs

### Updating patches

After editing files inside the `eve/` checkout (which is a git repo at the
pinned upstream commit + applied patches), commit the changes there and
regenerate the patch series:

```shell
./setup.py --update
```

This wipes `patches/` and re-runs `git format-patch` over the EVE checkout.

### Rebasing onto a newer EVE

1. Update `config.yml` `revision:` to the new EVE commit.
2. Run `./setup.py --rebase`.
3. Resolve any `git am -3` conflicts inside `eve/`, then
   `./setup.py --update` to regenerate `patches/`.
