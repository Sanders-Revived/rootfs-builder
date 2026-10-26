#!/usr/bin/env bash
# Debian rootfs runner.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DISTRO="${1:-debian}"
shift || true
case "$DISTRO" in
  debian) ;;
  -h|--help|help)
    cat <<EOF
Usage: bash sh/build.sh rootfs [debian]

The Debian recipe is at:
  $ROOT/sources/rootfs/debian/build.sh

The recipe receives the current kernel checkpoint through KERNEL_RELEASE,
KERNEL_MODULES_ARCHIVE, KERNEL_CONFIG_FILE and KERNEL_SYSTEM_MAP_FILE.
EOF
    exit 0
    ;;
  *) die 'Only the Debian rootfs is supported.' ;;
esac
[ "$#" -eq 0 ] || die 'Rootfs builder does not accept extra arguments.'

require_commands git tar zstd
acquire_lock
ensure_firmware_source
KREL="$(ensure_checkpoint)"
RECIPE="$ROOT/sources/rootfs/debian/build.sh"
[ -s "$RECIPE" ] || die "Debian recipe is missing: $RECIPE"

OUT_DIR="$CACHE_ROOT/rootfs/$DISTRO/out"
WORK_DIR="$CACHE_ROOT/rootfs/$DISTRO/work"
mkdir -p "$OUT_DIR" "$WORK_DIR" "$BUILD_ROOT/rootfs/$DISTRO"
export ROOT BUILD_ROOT CACHE_ROOT CHECKPOINT DISTRO ROOTFS_LABEL="$DISTRO"
export FIRMWARE_SOURCE_DIR="$FIRMWARE_DIR"
export FIRMWARE_REPOSITORY_URL="$FIRMWARE_URL" FIRMWARE_REF FIRMWARE_SHA
export KERNEL_RELEASE="$KREL" WORK_DIR OUT_DIR
export KERNEL_MODULES_ARCHIVE="$CHECKPOINT/kernel-modules-$KREL.tar.zst"
export KERNEL_CONFIG_FILE="$CHECKPOINT/kernel.config"
export KERNEL_SYSTEM_MAP_FILE="$CHECKPOINT/System.map"

say "Running local $DISTRO recipe with kernel $KREL"
bash "$RECIPE"
