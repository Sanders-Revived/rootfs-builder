#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

printf 'Project: %s\n' "$ROOT"
printf 'Kernel URL:   %s\n' "$KERNEL_URL"
printf 'Kernel cache: %s\n' "$KERNEL_DIR"
if [ -d "$KERNEL_DIR/.git" ]; then
  printf 'Commit:       %s\n' "$(git -C "$KERNEL_DIR" rev-parse --short HEAD)"
  if ! git -C "$KERNEL_DIR" diff --quiet || \
     ! git -C "$KERNEL_DIR" diff --cached --quiet; then
    printf 'Source:  dirty\n'
  else
    printf 'Source:  clean\n'
  fi
else
  printf 'Source:  missing\n'
fi

printf 'Firmware URL:   %s\n' "$FIRMWARE_URL"
printf 'Firmware cache: %s\n' "$FIRMWARE_DIR"
if [ -d "$FIRMWARE_DIR/.git" ]; then
  printf 'Firmware commit: %s\n' "$(git -C "$FIRMWARE_DIR" rev-parse --short HEAD)"
else
  printf 'Firmware: missing\n'
fi

if [ -s "$CHECKPOINT/kernel-release.txt" ]; then
  printf 'Checkpoint: %s (%s)\n' "$CHECKPOINT" "$(cat "$CHECKPOINT/kernel-release.txt")"
  [ ! -s "$CHECKPOINT/source-report.txt" ] || sed -n '1,20p' "$CHECKPOINT/source-report.txt"
  if grep -q 'root=LABEL=debian-root' "$CHECKPOINT/bootimg-info.txt" 2>/dev/null; then
    printf 'Root device: ext4 label debian-root (MMC-number independent)\n'
  else
    printf 'Root device: STALE (rebuild kernel checkpoint)\n'
  fi
else
  printf 'Checkpoint: absent\n'
fi

printf '\nReleases:\n'
find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -printf '  %f\n' 2>/dev/null | sort -r || true

printf '\nLatest kernel artifact:\n'
if [ -s "$BUILD_ROOT/mainline/latest" ] && [ -d "$(cat "$BUILD_ROOT/mainline/latest")" ]; then
  KERNEL_LATEST="$(cat "$BUILD_ROOT/mainline/latest")"
  printf '  %s\n' "$KERNEL_LATEST"
  [ ! -s "$KERNEL_LATEST/source-report.txt" ] || \
    grep -E '^(kernel_release|kernel_source_sha|kernel_debug_info|gpu_driver|battery_driver|bootimg_cmdline)=' \
      "$KERNEL_LATEST/source-report.txt" || true
else
  printf '  absent\n'
fi

printf '\nLatest Debian rootfs:\n'
if [ -s "$BUILD_ROOT/rootfs/debian/latest" ] && \
   [ -d "$(cat "$BUILD_ROOT/rootfs/debian/latest")" ]; then
  ROOTFS_LATEST="$(cat "$BUILD_ROOT/rootfs/debian/latest")"
  printf '  %s\n' "$ROOTFS_LATEST"
  [ ! -s "$ROOTFS_LATEST/build-info.txt" ] || \
    grep -E '^(suite|architecture|kernel_release|image_size_mib|image_free_mib|rootfs_payload_bytes|generic_qcom_firmware|ssh_host_keys|machine_id|qemu_build_helpers)=' \
      "$ROOTFS_LATEST/build-info.txt" || true
  if [ -s "$ROOTFS_LATEST/SHA256SUMS" ]; then
    (cd "$ROOTFS_LATEST" && sha256sum -c SHA256SUMS >/dev/null) &&
      printf '  checksums: OK\n' || printf '  checksums: FAILED\n'
  fi
else
  printf '  absent\n'
fi
