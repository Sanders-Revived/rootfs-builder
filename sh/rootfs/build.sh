#!/usr/bin/env bash
# Rootfs runner. Each distro is isolated in its own local recipe.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DISTRO="${1:-}"
shift || true
case "$DISTRO" in
  alpine|debian|ubuntu) ;;
  -h|--help|help)
    cat <<EOF
Usage: bash sh/build.sh rootfs alpine|debian|ubuntu

A local recipe must exist at:
  $ROOT/sources/rootfs/<distro>/build.sh

The recipe receives the current kernel checkpoint through KERNEL_RELEASE,
KERNEL_MODULES_ARCHIVE, KERNEL_CONFIG_FILE and KERNEL_SYSTEM_MAP_FILE.
EOF
    exit 0
    ;;
  *) die 'Choose one rootfs: alpine, debian or ubuntu.' ;;
esac
[ "$#" -eq 0 ] || die 'Rootfs builder does not accept extra arguments.'

require_commands tar zstd
acquire_lock
KREL="$(ensure_checkpoint)"
RECIPE_ROOT="${SANDERS_ROOTFS_DIR:-$ROOT/sources/rootfs}"
RECIPE="$RECIPE_ROOT/$DISTRO/build.sh"
[ -s "$RECIPE" ] || die "No local $DISTRO recipe at $RECIPE. Kernel build is ready; add a rootfs recipe first."

OUT_DIR="$CACHE_ROOT/rootfs/$DISTRO/out"
WORK_DIR="$CACHE_ROOT/rootfs/$DISTRO/work"
mkdir -p "$OUT_DIR" "$WORK_DIR" "$BUILD_ROOT/rootfs/$DISTRO"
export ROOT BUILD_ROOT CACHE_ROOT CHECKPOINT DISTRO ROOTFS_LABEL="$DISTRO"
export KERNEL_RELEASE="$KREL" WORK_DIR OUT_DIR
export KERNEL_MODULES_ARCHIVE="$CHECKPOINT/kernel-modules-$KREL.tar.zst"
export KERNEL_CONFIG_FILE="$CHECKPOINT/kernel.config"
export KERNEL_SYSTEM_MAP_FILE="$CHECKPOINT/System.map"

say "Running local $DISTRO recipe with kernel $KREL"
bash "$RECIPE"
