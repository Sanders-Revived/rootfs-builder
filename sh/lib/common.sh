#!/usr/bin/env bash
# Shared configuration and safety checks for the reproducible Sanders builder.
set -Eeuo pipefail

DEVICE="sanders"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_ROOT="$ROOT/build"
CACHE_ROOT="$ROOT/cache"

KERNEL_URL="${SANDERS_KERNEL_URL:-https://github.com/Sanders-Revived/linux.git}"
KERNEL_REF="${SANDERS_KERNEL_REF:-barni2000/7.3/develop}"
KERNEL_DIR="${SANDERS_KERNEL_CACHE_DIR:-$CACHE_ROOT/sources/linux}"
FIRMWARE_URL="${SANDERS_FIRMWARE_URL:-https://gitlab.com/vanadium-oss/motorola-msm8953/mainline/sanders-firmware.git}"
FIRMWARE_REF="${SANDERS_FIRMWARE_REF:-main}"
FIRMWARE_DIR="${SANDERS_FIRMWARE_CACHE_DIR:-$CACHE_ROOT/sources/sanders-firmware}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"

KERNEL_OUT="${SANDERS_KERNEL_OUT:-$BUILD_ROOT/mainline/out}"
RELEASES="$BUILD_ROOT/mainline/releases"
CHECKPOINT="$CACHE_ROOT/mainline/checkpoint"
MODULE_CACHE="$CACHE_ROOT/mainline/modules"
CCACHE_DIR="$CACHE_ROOT/mainline/ccache"
LK2ND_IMAGE="${SANDERS_LK2ND_IMAGE:-/home/light/lk2nd/build-lk2nd-msm8953/lk2nd.img}"

export LC_ALL=C

say() { printf '\n[%s] %s\n' "$DEVICE" "$*"; }
die() { printf '\nERROR [%s]: %s\n' "$DEVICE" "$*" >&2; exit 1; }

usage_tools() {
  cat >&2 <<'EOF'
Missing build dependencies. Install the native packages for:
  git make gcc aarch64-linux-gnu-gcc bc bison flex dtc zstd rsync python3
EOF
}

require_commands() {
  local missing=() command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  if ((${#missing[@]})); then
    usage_tools
    die "Missing commands: ${missing[*]}"
  fi
}

require_build_tools() {
  require_commands git make python3 rsync dtc zstd bc bison flex \
    "${CROSS_COMPILE}gcc" gcc
}

acquire_lock() {
  mkdir -p "$CACHE_ROOT/mainline"
  exec 9>"$CACHE_ROOT/.build.lock"
  flock -x 9 || die 'Could not acquire the local build lock.'
}

ensure_kernel_source() {
  mkdir -p "$(dirname "$KERNEL_DIR")"
  if [ ! -d "$KERNEL_DIR/.git" ]; then
    [ ! -e "$KERNEL_DIR" ] || die "Kernel cache is not a Git checkout: $KERNEL_DIR"
    say "Cloning kernel $KERNEL_REF from $KERNEL_URL"
    git clone --depth 1 --single-branch --branch "$KERNEL_REF" \
      "$KERNEL_URL" "$KERNEL_DIR"
  else
    SOURCE_DIRTY="$(git -C "$KERNEL_DIR" status --porcelain --untracked-files=all)"
    [ -z "$SOURCE_DIRTY" ] || die \
      "Kernel cache has local changes; remove it and let the builder clone again: $KERNEL_DIR"
    git -C "$KERNEL_DIR" remote set-url origin "$KERNEL_URL"
    say "Updating kernel cache to $KERNEL_REF"
    git -C "$KERNEL_DIR" fetch --depth 1 origin "$KERNEL_REF"
    git -C "$KERNEL_DIR" checkout --detach FETCH_HEAD
  fi

  SOURCE_SHA="$(git -C "$KERNEL_DIR" rev-parse HEAD)"
  SOURCE_DIRTY="$(git -C "$KERNEL_DIR" status --porcelain --untracked-files=all)"
  export SOURCE_SHA SOURCE_DIRTY
}

ensure_firmware_source() {
  mkdir -p "$(dirname "$FIRMWARE_DIR")"
  if [ ! -d "$FIRMWARE_DIR/.git" ]; then
    [ ! -e "$FIRMWARE_DIR" ] || die "Firmware cache is not a Git checkout: $FIRMWARE_DIR"
    say "Cloning Sanders firmware $FIRMWARE_REF from $FIRMWARE_URL"
    git clone --depth 1 --single-branch --branch "$FIRMWARE_REF" \
      "$FIRMWARE_URL" "$FIRMWARE_DIR"
  else
    FIRMWARE_DIRTY="$(git -C "$FIRMWARE_DIR" status --porcelain --untracked-files=all)"
    [ -z "$FIRMWARE_DIRTY" ] || die \
      "Firmware cache has local changes; remove it and let the builder clone again: $FIRMWARE_DIR"
    git -C "$FIRMWARE_DIR" remote set-url origin "$FIRMWARE_URL"
    say "Updating firmware cache to $FIRMWARE_REF"
    git -C "$FIRMWARE_DIR" fetch --depth 1 origin "$FIRMWARE_REF"
    git -C "$FIRMWARE_DIR" checkout --detach FETCH_HEAD
  fi

  [ -d "$FIRMWARE_DIR/modem/image" ] || die \
    "Firmware repository has no modem/image directory: $FIRMWARE_DIR"
  [ -d "$FIRMWARE_DIR/wlan" ] || die \
    "Firmware repository has no wlan directory: $FIRMWARE_DIR"
  FIRMWARE_SHA="$(git -C "$FIRMWARE_DIR" rev-parse HEAD)"
  export FIRMWARE_SHA
}

kernel_make() {
  make -C "$KERNEL_DIR" O="$KERNEL_OUT" ARCH="$ARCH" \
    CROSS_COMPILE="$CROSS_COMPILE" "$@"
}

kernel_release() {
  kernel_make -s kernelrelease
}

ensure_checkpoint() {
  [ -s "$CHECKPOINT/kernel-release.txt" ] || \
    die 'No kernel checkpoint. Run: bash sh/build.sh kernel'
  [ -s "$CHECKPOINT/panel.txt" ] || die 'Checkpoint panel selection is missing.'
  [ -s "$CHECKPOINT/kernel.config" ] || die 'Checkpoint config is missing.'
  [ -s "$CHECKPOINT/Image.gz" ] || die 'Checkpoint Image.gz is missing.'
  [ -s "$CHECKPOINT/sanders.dtb" ] || die 'Checkpoint Sanders DTB is missing.'
  [ -s "$CHECKPOINT/dt.img" ] || die 'Checkpoint QCDT image is missing.'
  [ -s "$CHECKPOINT/boot.img" ] || die 'Checkpoint boot.img is missing.'
  [ -s "$CHECKPOINT/lk2nd.img" ] || die 'Checkpoint lk2nd.img is missing.'
  [ -s "$CHECKPOINT/bootimg-info.txt" ] || die 'Checkpoint bootimg-info.txt is missing.'

  local krel archive
  krel="$(cat "$CHECKPOINT/kernel-release.txt")"
  archive="$CHECKPOINT/kernel-modules-$krel.tar.zst"
  [ -s "$archive" ] || die "Checkpoint modules are missing: $archive"
  printf '%s\n' "$krel"
}

new_stamp() { date -u +%Y%m%d%H%M%S; }

hash_file() {
  sha256sum "$1" | awk '{print $1}'
}
