# OpenLAN Gateway (OLG) Build Manifest Specification (`build.yaml`)

## 1. Overview & Architectural Purpose

The OpenLAN Gateway (OLG) appliance firmware build engine ([`build.sh`](./build.sh)) is 100% manifest-driven. All build targets, source repositories, compilation rules, container bundling, system packages, and static file injections are declaratively configured in a single file: **[`build.yaml`](./build.yaml)** (template provided in [`build.yaml.example`](./build.yaml.example)).

### Key Design Tenets
1. **Single Source of Truth**: No URLs, branch names, build flags, or file targets are hardcoded in `build.sh`.
2. **Dual-Mode Workflow (Local vs. Cloud)**: Developers can use local directories (`local_path`) for instant compilation and testing, or omit them to let the engine clone directly from Git repositories (`repo` and `ref`).
3. **Air-Gapped Appliance Output**: The resulting ISO image encapsulates the complete immutable OS, golden VyOS disk, pre-cached containers, offline `.deb` packages, and orchestrator scripts for zero-touch offline deployment.

---

## 2. Manifest Schema & Block Hierarchy

```yaml
version: "1.0"

vyos:
  # Base image, guest binaries, libraries, patches, and guest files

host:
  # Target release, ISO URL, host binaries, container images, custom files, and offline packages
```

---

## 3. Top-Level Sections & Parameters Reference

### 3.1 `version`
* **Type**: `string`
* **Description**: Schema version of the manifest format.
* **Example**: `"1.0"`

---

### 3.2 `vyos`
Declares the base VyOS router disk, binaries to build and inject into the guest filesystem, shared libraries, and custom files.

#### 3.2.1 `vyos.base_image`
Configures the base VyOS QCOW2 disk image used as the golden template.

| Parameter | Type | Required | Description |
| :--- | :--- | :--- | :--- |
| `cache_name` | `string` | Yes | Expected disk image filename located in `build/cache/` (e.g. `"vyos-base.qcow2"`). |
| `url` | `string` | No | Optional HTTP/HTTPS fallback URL to automatically download the base image if missing from cache. |
| `sha256` | `string` | No | Optional expected SHA-256 checksum to verify base disk integrity before extraction/customization. Build aborts if hash does not match. |

#### 3.2.2 `vyos.binaries[]`
List of guest binaries compiled on the host and injected into the VyOS root filesystem.

| Parameter | Type | Required | Description |
| :--- | :--- | :--- | :--- |
| `name` | `string` | Yes | Identifier for the binary (e.g. `vyos-nats-agent`, `rtty`). |
| `type` | `string` | Yes | Build toolchain: `go` (native cross-compilation) or `cmake` (containerized CMake build). |
| `dest` | `string` | Yes | Absolute target path inside the VyOS filesystem (e.g. `/usr/local/bin/vyos-nats-agent` or `/usr/sbin/rtty`). |
| `repo` | `string` | Conditional | Remote Git repository URL (used if `local_path` is omitted or absent). |
| `ref` | `string` | Conditional | Git branch, tag, or pinned 40-character commit SHA (e.g. `"main"`, `"v1.0.0"`, `"e1a2b3c4..."`). Defaults to `"main"`. |
| `local_path` | `string` | No | Relative or absolute path to a local directory containing source code. If present, the engine builds from this folder instead of cloning from git. |
| `build_cmd` | `string` | Yes (for `go`) | Exact compilation command string. `{output}` is dynamically replaced with the temporary output binary path. Required for Go binaries. |
| `url` | `string` | Conditional | Source tarball download URL for tarball-based builds (e.g. CMake release tarballs). |
| `build_container`| `string` | Conditional | Docker container image used to isolate CMake builds (e.g. `"debian:bookworm-slim"`). |
| `cmake_args` | `string` | No | Additional flags passed directly to `cmake` (e.g. `"-DRTTY_USE_OPENSSL=ON"`). |
| `libraries` | `list` | No | List of host/container library glob patterns to copy into the VyOS guest `/usr/lib/x86_64-linux-gnu/` (e.g. `["/usr/lib/x86_64-linux-gnu/libev.so.4*"]`). |
| `patches` | `object` | No | Git repository or local folder containing `*.patch` files to apply to the source before compiling. |

##### `vyos.binaries[].patches` Schema
```yaml
patches:
  repo: "https://github.com/RouterArchitects/ra_wlan-ap.git"
  ref: "Router-Architects_Main"
  path: "feeds/ucentral/rtty/patches"
  local_dir: "../ra_wlan-ap/feeds/ucentral/rtty/patches" # Optional local override
```

#### 3.2.3 `vyos.files[]`
Arbitrary configuration files, certificates, or scripts injected directly into the VyOS guest root filesystem.

| Parameter | Type | Required | Description |
| :--- | :--- | :--- | :--- |
| `name` | `string` | Yes | Descriptive label. |
| `local_path` | `string` | Conditional | Path to local source file (relative to repository root). |
| `url` | `string` | Conditional | Remote URL to fetch file from (used if `local_path` is omitted). |
| `dest` | `string` | Yes | Absolute destination path inside VyOS (e.g. `/etc/rtty/certs.pem`). |
| `mode` | `string` | No | Unix octal permissions (e.g. `"0644"`, `"0600"`, `"0755"`). Defaults to `"0644"`. |

---

### 3.3 `host`
Declares host Ubuntu target release version, base ISO, host binaries, containers, custom files, and offline `.deb` packages.

| Parameter | Type | Required | Description |
| :--- | :--- | :--- | :--- |
| `ubuntu_release` | `string` | Yes | Target Ubuntu Server release version (e.g. `"25.10"`). |
| `ubuntu_iso_url` | `string` | Yes | Canonical download URL for the pristine Ubuntu Live Server ISO image. Cached in `build/cache/`. |
| `ubuntu_iso_sha256` | `string` | No | Optional expected SHA-256 checksum for the pristine base Ubuntu ISO. Build aborts if hash does not match. |
| `hardware_profile` | `string` | No | Path to model-specific hardware profile JSON (e.g. `"config/hardware-profiles/acer-aspire-gateway.json"`). Baked into `/etc/olg/hardware-profile.json` on the appliance. |

#### 3.3.1 `host.binaries[]`
Utilities compiled on the host for orchestration and state seeding.

| Parameter | Type | Required | Description |
| :--- | :--- | :--- | :--- |
| `name` | `string` | Yes | Name of binary (e.g. `nats_pki_bootstrap`, `nats_kv_pusher`). |
| `type` | `string` | Yes | Toolchain (currently `go`). |
| `local_path` | `string` | Yes | Relative path to source code / main `.go` file. |
| `dest` | `string` | Yes | Target destination within `/opt/olg/` (e.g. `tools/nats_pki_bootstrap`). |
| `build_cmd` | `string` | Yes (for `go`) | Exact compilation command string. `{output}` is replaced with the target binary path. Required for Go binaries. |

#### 3.3.2 `host.containers[]`
Docker images packaged into the offline installer ISO as compressed `.tar` archives in `/opt/olg/docker-cache/`.

| Parameter | Type | Required | Description |
| :--- | :--- | :--- | :--- |
| `name` | `string` | Yes | Service name (e.g. `ucentral-client`, `nats-server`). |
| `type` | `string` | Yes | Provisioning mode: `docker-build` (builds from source Dockerfile) or `docker-pull` (pulls prebuilt image from registry). |
| `image` | `string` | Conditional | Container registry image tag or pinned digest for `docker-pull` (e.g. `"nats:2.10-alpine"` or `"nats@sha256:..."`). |
| `repo` | `string` | Conditional | Git repository URL for `docker-build`. |
| `ref` | `string` | Conditional | Git branch, tag, or pinned commit SHA for `docker-build` (e.g. `"main"`, `"v1.2.0"`, `"d3b07384..."`). |
| `local_path` | `string` | No | Optional local path to repository containing `Dockerfile`. If commented or omitted, clones from `repo` @ `ref`. |
| `tag` | `string` | Yes | Local Docker image tag assigned to built/pulled image (e.g. `"ucentral-client:latest"`). |
| `cache_tar` | `string` | Yes | Relative output path within payload directory (e.g. `"docker-cache/ucentral-client.tar"`). |

#### 3.3.3 `host.files[]`
Generic file injector for placing arbitrary extra files, configurations, capabilities descriptors, custom scripts, or certificates anywhere on the host Ubuntu filesystem.

> [!NOTE]
> This section is strictly optional (`files: []`). If any file is declared in `files:`, `build.sh` enforces fail-fast validation: the target source file must exist locally or download successfully via URL, otherwise the build terminates immediately to prevent building incomplete appliances.

| Parameter | Type | Required | Description |
| :--- | :--- | :--- | :--- |
| `name` | `string` | Yes | Descriptive label. |
| `local_path` | `string` | Conditional | Local source file path (relative to repo root). |
| `url` | `string` | Conditional | Remote download URL if `local_path` is not provided. |
| `dest` | `string` | Yes | Absolute destination path on host Ubuntu OS (e.g. `/etc/ucentral/capabilities.json` or `/etc/olg/device-certs/cert.pem`). |
| `mode` | `string` | No | File permission mode (`"0600"` for private keys, `"0644"` for general configs/certs). |

#### 3.3.4 `host.offline_packages[]`
List of Debian/Ubuntu packages to download and cache into `/opt/olg/debs/` on the installer ISO. During first boot or installation, these packages install automatically without requiring internet access.

---

## 4. Workflows & Usage Guide

### 4.1 Switching Between Local Source and Cloud Git

#### Local Development Mode
Use `local_path` to iterate on uncommitted local code without pushing to GitHub:
```yaml
  containers:
    - name: ucentral-client
      type: docker-build
      local_path: "../TIP-olg-ucentral-client"
      tag: "ucentral-client:latest"
      cache_tar: "docker-cache/ucentral-client.tar"
```

#### Cloud / CI Build Mode
Comment out or remove `local_path`. The build engine will automatically clone fresh source code from `repo` and checkout `ref`:
```yaml
  containers:
    - name: ucentral-client
      type: docker-build
      repo: "https://github.com/RouterArchitects/TIP-olg-ucentral-client.git"
      ref: "main"
      # local_path: "../TIP-olg-ucentral-client"
      tag: "ucentral-client:latest"
      cache_tar: "docker-cache/ucentral-client.tar"
```

---

### 4.2 Injecting Custom Host Files & Configurations (Optional)

The `host.files[]` array provides an optional hook to inject site-specific hardware capabilities, custom network scripts, or mTLS certificates onto the appliance filesystem during installation.

If your appliance does not require custom host files, leave the block empty (`files: []`) as shown in [`build.yaml.example`](./build.yaml.example). When files are specified, `build.sh` strictly validates their presence:

```yaml
host:
  # Empty by default for standard builds:
  files: []

  # Example: Uncomment when providing target-specific capabilities or credentials:
  # files:
  #   - name: "capabilities"
  #     local_path: "config/capabilities.json"
  #     dest: "/etc/ucentral/capabilities.json"
  #     mode: "0644"
  #   - name: "device-ca-cert"
  #     local_path: "certs/ca.pem"
  #     dest: "/etc/olg/device-certs/ca.pem"
  #     mode: "0644"
  #   - name: "device-client-cert"
  #     local_path: "certs/cert.pem"
  #     dest: "/etc/olg/device-certs/cert.pem"
  #     mode: "0644"
  #   - name: "device-client-key"
  #     local_path: "certs/key.pem"
  #     dest: "/etc/olg/device-certs/key.pem"
  #     mode: "0600"
```

---

### 4.3 Running the Build Engine

The engine reads `build.yaml` in the repository root by default:

```bash
# Full build: VyOS Golden Master QCOW2 + Ubuntu Installer ISO
sudo ./build.sh

# Rebuild VyOS Golden Master disk image only (fast iteration)
sudo ./build.sh --vyos-only

# Rebuild Ubuntu Host Installer ISO only (requires vyos-golden.qcow2)
sudo ./build.sh --iso-only

# Specify a custom manifest file
sudo ./build.sh --config custom-build.yaml
```

---

### 4.4 Supply-Chain Security & Artifact Provenance Manifest

To satisfy strict enterprise security audit requirements and guarantee reproducibility:
1. **Source Integrity Validation**: Base disk and ISO images can be pinned with SHA-256 hashes (`vyos.base_image.sha256` and `host.ubuntu_iso_sha256`). The builder computes SHA-256 hashes immediately after download/cache resolution and aborts on any mismatch.
2. **Pinned Git Commit SHAs & Container Digests**: All repository references (`ref`) support exact 40-character Git commit SHAs, and container pulls (`image`) support immutable digests (e.g. `nats@sha256:...`).
3. **Automated Provenance Manifest (`provenance.json`)**:
   During the build process, the builder dynamically resolves and logs exact Git commit SHAs (via `git rev-parse HEAD`), Docker image IDs and repo digests (via `docker inspect`), base image hashes, and resulting artifact checksums.
   - Output path on host: `build/output/provenance.json`
   - Installed path on appliance: `/etc/olg/provenance.json`
   - Payload path in installer ISO: `/olg-payload/config/provenance.json`

Example `provenance.json`:
```json
{
  "schema_version": "1.0",
  "build_timestamp": "2026-11-04T12:00:00Z",
  "builder": "carlos@build-server",
  "manifest_version": "1.0",
  "ubuntu_release": "25.10",
  "base_images": {
    "vyos": {
      "cache_name": "vyos-base.qcow2",
      "url": "",
      "expected_sha256": "3fa85f647902bec2fd5419910d65b744d03ff42d3...e0"
    },
    "ubuntu_installer": {
      "url": "https://releases.ubuntu.com/25.10/ubuntu-25.10-live-server-amd64.iso",
      "expected_sha256": "a3b2c1..."
    }
  },
  "vyos_binaries": [
    {
      "name": "vyos-nats-agent",
      "type": "go",
      "repo": "https://github.com/RouterArchitects/TIP-olg-server-vyos-client-natsagent.git",
      "ref": "main",
      "commit_sha": "7f8b9a10c11d12e13f14a15b16c17d18e19f20a1",
      "dest": "/usr/local/bin/vyos-nats-agent"
    }
  ],
  "host_binaries": [
    {
      "name": "nats_pki_bootstrap",
      "type": "go",
      "repo": "local",
      "ref": "local",
      "commit_sha": "local",
      "dest": "tools/nats_pki_bootstrap"
    }
  ],
  "containers": [
    {
      "name": "ucentral-client",
      "type": "docker-build",
      "tag": "ucentral-client:latest",
      "repo": "https://github.com/vimauryaxx/TIP-olg-ucentral-client.git",
      "ref": "dockerfile_test",
      "commit_sha": "992484ab3e936b...",
      "image_id": "sha256:d159...",
      "cache_tar": "docker-cache/ucentral-client.tar"
    },
    {
      "name": "nats-server",
      "type": "docker-pull",
      "image": "nats:2.10-alpine",
      "image_id": "sha256:a123...",
      "digest": "nats@sha256:456...",
      "cache_tar": "docker-cache/nats-server.tar"
    }
  ],
  "artifacts": {
    "vyos_golden_disk": {
      "file": "vyos-golden.qcow2",
      "sha256": "4b68..."
    },
    "enterprise_iso": {
      "file": "olg-enterprise-appliance-25.10.iso",
      "sha256": "9f8e..."
    }
  }
}
```
