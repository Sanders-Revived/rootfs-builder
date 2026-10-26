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
GPU_FIRMWARE_STAGE="${SANDERS_GPU_FIRMWARE_STAGE:-$CACHE_ROOT/mainline/gpu-firmware}"
GPU_HOST_FIRMWARE_ROOT="${SANDERS_GPU_FIRMWARE_ROOT:-/usr/lib/firmware}"
GPU_FIRMWARE_SOURCE_URL="${SANDERS_GPU_FIRMWARE_SOURCE_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/qcom}"
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
    if ! git -C "$KERNEL_DIR" diff --quiet || \
       ! git -C "$KERNEL_DIR" diff --cached --quiet; then
      die \
      "Kernel cache has local changes; remove it and let the builder clone again: $KERNEL_DIR"
    fi
    git -C "$KERNEL_DIR" remote set-url origin "$KERNEL_URL"
    say "Updating kernel cache to $KERNEL_REF"
    git -C "$KERNEL_DIR" fetch --depth 1 origin "$KERNEL_REF"
    git -C "$KERNEL_DIR" checkout --detach FETCH_HEAD
  fi

  SOURCE_SHA="$(git -C "$KERNEL_DIR" rev-parse HEAD)"
  SOURCE_DIRTY=""
  if ! git -C "$KERNEL_DIR" diff --quiet || \
     ! git -C "$KERNEL_DIR" diff --cached --quiet; then
    SOURCE_DIRTY=tracked-changes
  fi
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
    if ! git -C "$FIRMWARE_DIR" diff --quiet || \
       ! git -C "$FIRMWARE_DIR" diff --cached --quiet; then
      die \
      "Firmware cache has local changes; remove it and let the builder clone again: $FIRMWARE_DIR"
    fi
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

prepare_gpu_firmware() {
  local host_root="$GPU_HOST_FIRMWARE_ROOT"
  local zap_source="$FIRMWARE_DIR/modem/image"
  local required_file

  for required_file in a530_pm4.fw a530_pfp.fw; do
    if [ ! -s "$host_root/qcom/$required_file" ] && \
       ! command -v curl >/dev/null 2>&1; then
      die "Missing host GPU firmware and curl: $host_root/qcom/$required_file"
    fi
  done

  for required_file in a506_zap.mdt a506_zap.b00 a506_zap.b01 a506_zap.b02; do
    [ -s "$zap_source/$required_file" ] || die \
      "Missing Sanders GPU firmware: $zap_source/$required_file"
  done

  # These files are requested before userdata is mounted. Stage them in a
  # stable generated directory so the kernel can embed them in Image.gz.
  rm -rf "$GPU_FIRMWARE_STAGE"
  mkdir -p \
    "$GPU_FIRMWARE_STAGE/qcom" \
    "$GPU_FIRMWARE_STAGE/qcom/msm8953/motorola/sanders"
  for required_file in a530_pm4.fw a530_pfp.fw; do
    if [ -s "$host_root/qcom/$required_file" ]; then
      cp "$host_root/qcom/$required_file" "$GPU_FIRMWARE_STAGE/qcom/"
      continue
    fi

    command -v curl >/dev/null 2>&1 || die \
      "Missing curl to download GPU firmware: $GPU_FIRMWARE_SOURCE_URL/$required_file"
    say "Downloading standard GPU firmware $required_file"
    curl -fsSL --retry 3 --connect-timeout 15 \
      "$GPU_FIRMWARE_SOURCE_URL/$required_file" \
      -o "$GPU_FIRMWARE_STAGE/qcom/$required_file.tmp"
    mv "$GPU_FIRMWARE_STAGE/qcom/$required_file.tmp" \
      "$GPU_FIRMWARE_STAGE/qcom/$required_file"
  done
  for required_file in a506_zap.mdt a506_zap.b00 a506_zap.b01 a506_zap.b02; do
    cp "$zap_source/$required_file" \
      "$GPU_FIRMWARE_STAGE/qcom/msm8953/motorola/sanders/"
  done

  GPU_EXTRA_FIRMWARE='qcom/a530_pm4.fw qcom/a530_pfp.fw qcom/msm8953/motorola/sanders/a506_zap.mdt qcom/msm8953/motorola/sanders/a506_zap.b00 qcom/msm8953/motorola/sanders/a506_zap.b01 qcom/msm8953/motorola/sanders/a506_zap.b02'
  export GPU_EXTRA_FIRMWARE GPU_FIRMWARE_STAGE
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
  grep -q 'root=/dev/mmcblk1p53' "$CHECKPOINT/bootimg-info.txt" || die \
    'Checkpoint boot image uses an obsolete root device; rebuild the kernel checkpoint.'

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
