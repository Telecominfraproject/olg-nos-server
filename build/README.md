# OLG Enterprise Appliance Build System

This directory contains the unified, manifest-driven build pipeline for the OpenLAN Gateway (OLG) enterprise appliance.

---

## Architecture Overview

```text
               ┌───────────────────────────┐
               │        build.yaml         │ <--- Master Declarative Manifest
               └─────────────┬─────────────┘
                             │
                             ▼
                    [ ./build.sh ] <--- Single Central Build Engine
                             │
            ┌────────────────┴────────────────┐
            ▼                                 ▼
   [ VyOS Target ]                     [ Host Target ]
• Base vyos-base.qcow2              • Base ubuntu-25.10 ISO
• Generic binary compiler (Go/CMake)• Generic container builder
• Auto-fetches external patches     • Pre-caches offline debs
• Injects via qemu-nbd              • Prepares finish_install.sh
• Generates vyos-golden.qcow2       • Repackages bootable hybrid ISO
            │                                 │
            └────────────────┬────────────────┘
                             ▼
         [ build/output/olg-enterprise-appliance-25.10.iso ]
```

---

## Directory Structure

* **`build.yaml`** (and template **`build.yaml.example`**): The single declarative manifest defining all VyOS binaries (with patch sources), host containers, offline debs, and cloud endpoints.
* **`build.sh`**: The single central master engine that reads `build.yaml`, compiles all binaries/containers with patches, and produces both the VyOS golden master and the air-gapped Ubuntu ISO.
* **`build/cache/`**: Cache directory for base images (`ubuntu-25.10-live-server-amd64.iso` and `vyos-base.qcow2`).
* **`build/output/`**: Unified output directory for generated `.qcow2`, `.iso`, and `.sha256` files.
* **`build/iso/`**: Autoinstall recipes (`user-data`), GRUB config, and post-installation hook (`finish_install.sh`).

---

## Quick Start: Single-Command Build

From the repository root, simply run:
```bash
./build.sh
```

To build only the router disk or only the ISO:
```bash
./build.sh --vyos-only    # Builds only vyos-golden.qcow2
./build.sh --iso-only     # Packages only the Ubuntu ISO (requires golden disk)
```

To flash the resulting ISO to a USB thumb drive (`/dev/sda`):
```bash
sudo umount /dev/sda* 2>/dev/null || true
sudo dd if=build/output/olg-enterprise-appliance-25.10.iso of=/dev/sda bs=4M status=progress conv=fsync
sync
```
