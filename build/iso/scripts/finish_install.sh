#!/bin/bash
# ==============================================================================
# OLG Enterprise Appliance Post-Install Provisioning (Late Command)
# Executed by cloud-init autoinstall after Ubuntu disk imaging completes
# ==============================================================================
set -euo pipefail
set -x

INSTALL_LOG="/target/var/log/olg-install.log"
mkdir -p "$(dirname "$INSTALL_LOG")"
echo "=== [$(date -u)] Starting OLG Enterprise Appliance Post-Install Provisioning ===" > "$INSTALL_LOG"
ln -sf olg-install.log /target/var/log/olg-package-install.log 2>/dev/null || true

# 0. Ensure kernel virtual filesystems (/dev, /proc, /sys, /run) are bind-mounted into /target for chroot operations
MOUNTED_FS=()
for fs in /dev /dev/pts /proc /sys /run; do
  if [ -d "$fs" ] && ! mountpoint -q "/target$fs"; then
    mkdir -p "/target$fs"
    mount --bind "$fs" "/target$fs"
    MOUNTED_FS+=("/target$fs")
  fi
done

cleanup_mounts() {
  rm -f /target/usr/sbin/policy-rc.d 2>/dev/null || true
  for ((idx=${#MOUNTED_FS[@]}-1; idx>=0; idx--)); do
    local m="${MOUNTED_FS[idx]}"
    if mountpoint -q "$m"; then
      umount -l "$m" 2>/dev/null || true
    fi
  done
}
trap cleanup_mounts EXIT

# 1. Update kernel command line parameters in GRUB
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash intel_iommu=on amd_iommu=on iommu=pt kvm.ignore_msrs=1 console=tty0 console=ttyS0,115200n8"/' /target/etc/default/grub 2>/dev/null || true
sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /target/etc/default/grub 2>/dev/null || true
chroot /target update-grub 2>/dev/null || true

# 2. Add olg user to required groups and ensure groups exist
chroot /target groupadd -f kvm 2>/dev/null || true
chroot /target usermod -aG kvm,libvirt,docker olg 2>/dev/null || true

# 3. Create OLG Directory Hierarchy
mkdir -p /target/opt/olg/{scripts,tools,config,images,data,debs,docker-cache}
mkdir -p /target/etc/olg/{client,guest-secrets,device-certs} /target/etc/ucentral
chmod 0755 /target/etc/olg/device-certs 2>/dev/null || true

# 4. Copy pre-bundled payload from /cdrom to /target/opt/olg
echo "=== [$(date -u)] Copying pre-bundled payload to /target/opt/olg ===" >> "$INSTALL_LOG"
if ! cp -a /cdrom/olg-payload/* /target/opt/olg/ >> "$INSTALL_LOG" 2>&1; then
  echo "FATAL: Failed to copy payload from /cdrom/olg-payload" | tee -a "$INSTALL_LOG" >&2
  exit 1
fi
chmod 0755 /target/opt/olg/scripts/startup_node.sh 2>/dev/null || true
[ -f /target/opt/olg/tools/pki_init ] && chmod 0755 /target/opt/olg/tools/pki_init 2>/dev/null || true
[ -f /target/opt/olg/tools/kv_config_init ] && chmod 0755 /target/opt/olg/tools/kv_config_init 2>/dev/null || true

# 4.5. Install custom files declared in manifest onto the root filesystem
if [ -d /cdrom/olg-payload/custom-files/root ]; then
  echo "=== [$(date -u)] Installing custom files onto root filesystem ===" >> "$INSTALL_LOG"
  if ! cp -a /cdrom/olg-payload/custom-files/root/. /target/ >> "$INSTALL_LOG" 2>&1; then
    echo "FATAL: Failed to copy custom host files to /target" | tee -a "$INSTALL_LOG" >&2
    exit 1
  fi
  if [ -f /cdrom/olg-payload/custom-files/apply_permissions.sh ]; then
    echo "Applying permissions to custom host files..." >> "$INSTALL_LOG"
    if ! bash /cdrom/olg-payload/custom-files/apply_permissions.sh /target >> "$INSTALL_LOG" 2>&1; then
      echo "FATAL: Failed to apply permissions to custom host files" | tee -a "$INSTALL_LOG" >&2
      exit 1
    fi
  fi
  rm -rf /target/opt/olg/custom-files
fi

# Install authoritative hardware profile into /etc/olg/hardware-profile.json
if [ -f /target/opt/olg/config/hardware-profile.json ]; then
  if ! cp -f /target/opt/olg/config/hardware-profile.json /target/etc/olg/hardware-profile.json >> "$INSTALL_LOG" 2>&1; then
    echo "FATAL: Failed to copy hardware profile to /etc/olg/hardware-profile.json" | tee -a "$INSTALL_LOG" >&2
    exit 1
  fi
  chmod 0644 /target/etc/olg/hardware-profile.json
fi

# Seed baseline uCentral client configuration into /etc/olg/client/config.json
if [ -f /target/opt/olg/config/ucentral_client_template.json ]; then
  if ! cp -f /target/opt/olg/config/ucentral_client_template.json /target/etc/olg/client/config.json >> "$INSTALL_LOG" 2>&1; then
    echo "FATAL: Failed to copy uCentral client configuration template" | tee -a "$INSTALL_LOG" >&2
    exit 1
  fi
  chmod 0600 /target/etc/olg/client/config.json
fi

# Install artifact image details manifest into /etc/olg/image_details.json
if [ -f /target/opt/olg/config/image_details.json ]; then
  if ! cp -f /target/opt/olg/config/image_details.json /target/etc/olg/image_details.json >> "$INSTALL_LOG" 2>&1; then
    echo "WARNING: Failed to copy image details manifest to /etc/olg/image_details.json" >> "$INSTALL_LOG"
  else
    chmod 0644 /target/etc/olg/image_details.json
  fi
fi

# 5. Install offline Debian packages (strictly 64-bit AMD64)
echo "=== [$(date -u)] Starting offline package installation ===" >> "$INSTALL_LOG"

rm -f /target/opt/olg/debs/*_i386.deb 2>/dev/null || true
if [ -f /target/opt/olg/debs/Packages.gz ]; then
  echo "Isolating APT configuration for air-gapped installation..." >> "$INSTALL_LOG"
  # Temporarily disable online repositories so APT does not query upstream mirrors offline
  mkdir -p /target/etc/apt/sources.list.d/bak_offline
  [ -f /target/etc/apt/sources.list ] && mv -f /target/etc/apt/sources.list /target/etc/apt/sources.list.bak_offline 2>/dev/null || true
  for src in /target/etc/apt/sources.list.d/*.sources /target/etc/apt/sources.list.d/*.list; do
    [ -f "$src" ] && mv -f "$src" /target/etc/apt/sources.list.d/bak_offline/ 2>/dev/null || true
  done

  # Prevent background daemons from starting inside chroot during package install
  echo -e '#!/bin/sh\nexit 101' > /target/usr/sbin/policy-rc.d 2>/dev/null || true
  chmod +x /target/usr/sbin/policy-rc.d 2>/dev/null || true

  echo "deb [trusted=yes] file:/opt/olg/debs ./" > /target/etc/apt/sources.list.d/olg-offline.list

  echo "Updating local APT repository cache..." >> "$INSTALL_LOG"
  if ! chroot /target bash -c 'DEBIAN_FRONTEND=noninteractive apt-get update' >> "$INSTALL_LOG" 2>&1; then
    echo "FATAL: Failed to update local APT repository from /opt/olg/debs." | tee -a "$INSTALL_LOG" >&2
    exit 1
  fi

  echo "Installing offline dependencies via APT solver..." >> "$INSTALL_LOG"
  if ! chroot /target bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtiofsd \
    docker.io docker-compose-v2 containerd runc jq openssl pciutils iproute2 curl ca-certificates netplan.io' >> "$INSTALL_LOG" 2>&1; then
    echo "FATAL: Offline package installation failed." | tee -a "$INSTALL_LOG" >&2
    exit 1
  fi

  # Clean up policy-rc.d
  rm -f /target/usr/sbin/policy-rc.d 2>/dev/null || true

  # Remove local repo and restore online repository configurations
  rm -f /target/etc/apt/sources.list.d/olg-offline.list
  if [ -f /target/etc/apt/sources.list.bak_offline ]; then
    mv -f /target/etc/apt/sources.list.bak_offline /target/etc/apt/sources.list
  fi
  if [ -d /target/etc/apt/sources.list.d/bak_offline ]; then
    for bak in /target/etc/apt/sources.list.d/bak_offline/*; do
      [ -f "$bak" ] && mv -f "$bak" /target/etc/apt/sources.list.d/
    done
    rm -rf /target/etc/apt/sources.list.d/bak_offline
  fi
elif ls /target/opt/olg/debs/*.deb >/dev/null 2>&1; then
  echo "Unpacking offline Debian packages via dpkg..." >> "$INSTALL_LOG"
  if ! chroot /target bash -c 'DEBIAN_FRONTEND=noninteractive dpkg --unpack --skip-same-version /opt/olg/debs/*.deb' >> "$INSTALL_LOG" 2>&1; then
    echo "FATAL: Failed to unpack offline Debian packages." | tee -a "$INSTALL_LOG" >&2
    exit 1
  fi
  echo "Configuring unpacked packages..." >> "$INSTALL_LOG"
  if ! chroot /target bash -c 'DEBIAN_FRONTEND=noninteractive dpkg --configure -a' >> "$INSTALL_LOG" 2>&1; then
    echo "FATAL: Failed to configure offline Debian packages." | tee -a "$INSTALL_LOG" >&2
    exit 1
  fi
fi

# 5.1 Ensure virtiofsd is accessible in PATH and verify critical dependencies
# (virtiofsd on Debian/Ubuntu is packaged in /usr/libexec or /usr/lib/qemu)
if [ -x /target/usr/libexec/virtiofsd ] && [ ! -f /target/usr/bin/virtiofsd ]; then
  ln -sf /usr/libexec/virtiofsd /target/usr/bin/virtiofsd
elif [ -x /target/usr/lib/qemu/virtiofsd ] && [ ! -f /target/usr/bin/virtiofsd ]; then
  ln -sf /usr/lib/qemu/virtiofsd /target/usr/bin/virtiofsd
fi

CRITICAL_BINS=(docker virsh qemu-system-x86_64 virtiofsd jq openssl netplan curl)
MISSING_BINS=()
for bin in "${CRITICAL_BINS[@]}"; do
  if [ "$bin" = "virtiofsd" ]; then
    if ! chroot /target which virtiofsd >/dev/null 2>&1 && [ ! -x /target/usr/libexec/virtiofsd ] && [ ! -x /target/usr/lib/qemu/virtiofsd ]; then
      MISSING_BINS+=("$bin")
    fi
  else
    if ! chroot /target which "$bin" >/dev/null 2>&1; then
      MISSING_BINS+=("$bin")
    fi
  fi
done

if [ ${#MISSING_BINS[@]} -gt 0 ]; then
  echo "FATAL: Critical runtime binaries missing after package installation: ${MISSING_BINS[*]}" | tee -a "$INSTALL_LOG" >&2
  exit 1
fi
echo "Offline package installation verified successfully." >> "$INSTALL_LOG"

# 6. Verify & set permissions on Golden Master VyOS image
if [ -f /target/opt/olg/images/vyos-golden.qcow2 ]; then
  chown -R root:kvm /target/opt/olg/images 2>/dev/null || true
  chmod 1775 /target/opt/olg/images 2>/dev/null || true
  chmod 0444 /target/opt/olg/images/vyos-golden.qcow2 2>/dev/null || true
  if [ ! -f /target/opt/olg/images/vyos-golden.qcow2.sha256 ]; then
    (cd /target/opt/olg/images && sha256sum vyos-golden.qcow2 > vyos-golden.qcow2.sha256)
  fi
  chmod 0444 /target/opt/olg/images/vyos-golden.qcow2.sha256 2>/dev/null || true
  [ -f /target/opt/olg/images/vyos-golden.qcow2.attestation.json ] && chmod 0444 /target/opt/olg/images/vyos-golden.qcow2.attestation.json 2>/dev/null || true
fi

# 7. Install and enable the Systemd Startup Service, Docker Service, and Libvirt
if [ ! -f /target/opt/olg/systemd/olg-orchestrator.service ]; then
  echo "FATAL: Startup service /target/opt/olg/systemd/olg-orchestrator.service not found." | tee -a "$INSTALL_LOG" >&2
  exit 1
fi

echo "=== [$(date -u)] Installing and enabling core systemd services ===" >> "$INSTALL_LOG"
cp -f /target/opt/olg/systemd/olg-orchestrator.service /target/etc/systemd/system/olg-orchestrator.service

if ! chroot /target systemctl daemon-reload >> "$INSTALL_LOG" 2>&1; then
  echo "FATAL: Failed to execute systemctl daemon-reload" | tee -a "$INSTALL_LOG" >&2
  exit 1
fi

CRITICAL_SERVICES=(docker.service libvirtd.service libvirtd.socket olg-orchestrator.service)
for svc in "${CRITICAL_SERVICES[@]}"; do
  echo "Enabling critical service: $svc..." >> "$INSTALL_LOG"
  if ! chroot /target systemctl enable "$svc" >> "$INSTALL_LOG" 2>&1; then
    echo "FATAL: Failed to enable critical service: $svc" | tee -a "$INSTALL_LOG" >&2
    exit 1
  fi
done

# Ensure libvirt-guests does not auto-start un-reconciled domains before olg-orchestrator
chroot /target systemctl disable libvirt-guests.service >> "$INSTALL_LOG" 2>&1 || true

# 8. Ensure pre-cached Docker container archives are preserved in /opt/olg/docker-cache
# (startup_node.sh will automatically load them on first boot)
if [ -d /cdrom/olg-payload/docker-cache ]; then
  mkdir -p /target/opt/olg/docker-cache
  cp -f /cdrom/olg-payload/docker-cache/*.tar /target/opt/olg/docker-cache/ 2>/dev/null || true
fi

# 9. Factory Sanitization (Sysprep) to guarantee unique per-device identity
truncate -s 0 /target/etc/machine-id 2>/dev/null || true
rm -f /target/var/lib/dbus/machine-id 2>/dev/null || true
rm -f /target/etc/ssh/ssh_host_* 2>/dev/null || true
rm -rf /target/opt/olg/config/certs/* /target/opt/olg/config/jwt/* 2>/dev/null || true
rm -f /target/opt/olg/config/resolver.conf 2>/dev/null || true

exit 0
