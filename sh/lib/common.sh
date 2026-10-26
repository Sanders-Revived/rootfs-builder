#!/usr/bin/env bash
# Shared configuration and safety checks for the local Sanders builder.
set -Eeuo pipefail

DEVICE="sanders"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_ROOT="$ROOT/build"
CACHE_ROOT="$ROOT/cache"

# The kernel checkout produced in this workspace is the default source.
KERNEL_DIR="${SANDERS_KERNEL_DIR:-/home/light/linux-barni}"
KERNEL_REF="${SANDERS_KERNEL_REF:-barni2000/7.3/develop}"
KERNEL_REMOTE="${SANDERS_KERNEL_REMOTE:-destination}"
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
  [ -d "$KERNEL_DIR/.git" ] || die "Kernel checkout not found: $KERNEL_DIR"

  local branch
  branch="$(git -C "$KERNEL_DIR" branch --show-current)"
  [ "$branch" = "$KERNEL_REF" ] || die \
    "Kernel branch is '$branch'; expected '$KERNEL_REF'."

  SOURCE_SHA="$(git -C "$KERNEL_DIR" rev-parse HEAD)"
  SOURCE_DIRTY="$(git -C "$KERNEL_DIR" status --porcelain --untracked-files=all)"
  export SOURCE_SHA SOURCE_DIRTY
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
  [ -s "$CHECKPOINT/kernel.config" ] || die 'Checkpoint config is missing.'
  [ -s "$CHECKPOINT/Image.gz" ] || die 'Checkpoint Image.gz is missing.'
  [ -s "$CHECKPOINT/msm8953-motorola-sanders.dtb" ] || \
    die 'Checkpoint Sanders DTB is missing.'
  [ -s "$CHECKPOINT/dt.img" ] || die 'Checkpoint Tianma QCDT image is missing.'
  [ -s "$CHECKPOINT/dt-djn.img" ] || die 'Checkpoint DJN QCDT image is missing.'
  [ -s "$CHECKPOINT/boot.img" ] || die 'Checkpoint boot.img is missing.'
  [ -s "$CHECKPOINT/boot-djn.img" ] || die 'Checkpoint boot-djn.img is missing.'
  [ -s "$CHECKPOINT/lk2nd.img" ] || die 'Checkpoint lk2nd.img is missing.'
  [ -s "$CHECKPOINT/bootimg-info.txt" ] || die 'Checkpoint bootimg-info.txt is missing.'
  [ -s "$CHECKPOINT/bootimg-info-djn.txt" ] || \
    die 'Checkpoint bootimg-info-djn.txt is missing.'

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
