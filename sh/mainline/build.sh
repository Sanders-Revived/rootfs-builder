#!/usr/bin/env bash
# Clone, build and publish the Sanders kernel with checked artifacts.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

usage() {
  cat <<EOF
Usage: bash sh/mainline/build.sh [OPTION]

Clones and builds:
  $KERNEL_URL

The checkout is cached at:
  $KERNEL_DIR

Expected branch:
  $KERNEL_REF

Options:
  --reuse  validate the last checkpoint without compiling
  --clean  discard only the generated kernel output and rebuild
  --help   show this help

Overrides:
  SANDERS_KERNEL_URL, SANDERS_KERNEL_REF, SANDERS_KERNEL_CACHE_DIR,
  SANDERS_KERNEL_OUT, JOBS,
  SANDERS_BOOT_CMDLINE, SANDERS_LK2ND_IMAGE
EOF
}

mode="build"
case "${1:-}" in
  '') ;;
  --reuse) mode="reuse" ;;
  --clean) mode="clean" ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

require_build_tools
acquire_lock
ensure_kernel_source
[ -s "$LK2ND_IMAGE" ] || die "LK2ND image not found: $LK2ND_IMAGE"

if [ "$mode" = reuse ]; then
  KREL="$(ensure_checkpoint)"
  say "Checkpoint OK: kernel $KREL"
  exit 0
fi

if [ "$mode" = clean ]; then
  # This path is generated exclusively by this builder.
  rm -rf "$KERNEL_OUT"
fi
mkdir -p "$KERNEL_OUT" "$RELEASES" "$MODULE_CACHE" "$CCACHE_DIR"

if command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR
  ccache --max-size "${CCACHE_MAXSIZE:-2G}" >/dev/null
  export CC="ccache ${CROSS_COMPILE}gcc"
fi

BASE_CONFIG="$KERNEL_DIR/arch/$ARCH/configs/msm8953.config"
DEVICE_CONFIG="$KERNEL_DIR/arch/$ARCH/configs/motorola-sanders.config"
TRIM_CONFIG="$KERNEL_DIR/arch/$ARCH/configs/no-unused-drivers.config"
PANEL_NAME='automatic (lk2nd mdss_mdp.panel)'
PANEL_DTB_TARGET='qcom/msm8953-motorola-sanders.dtb'
PANEL_DTB_FILE='msm8953-motorola-sanders.dtb'
[ -s "$BASE_CONFIG" ] || die "Missing config fragment: $BASE_CONFIG"
[ -s "$DEVICE_CONFIG" ] || die "Missing config fragment: $DEVICE_CONFIG"
[ -s "$TRIM_CONFIG" ] || die "Missing trim fragment: $TRIM_CONFIG"

say "Generating trimmed Sanders configuration from defconfig + trim + device fragments"
kernel_make defconfig
"$KERNEL_DIR/scripts/kconfig/merge_config.sh" -m -Q -O "$KERNEL_OUT" \
  "$KERNEL_OUT/.config" "$TRIM_CONFIG" "$BASE_CONFIG" "$DEVICE_CONFIG"
kernel_make olddefconfig

say "Compiling kernel, $PANEL_NAME DTB and modules with $JOBS jobs"
kernel_make -j"$JOBS" Image.gz modules "$PANEL_DTB_TARGET"

KREL="$(kernel_release)"
BOOT_DIR="$KERNEL_OUT/arch/$ARCH/boot"
DTB_DIR="$BOOT_DIR/dts/qcom"
IMAGE="$BOOT_DIR/Image.gz"
DTB="$DTB_DIR/$PANEL_DTB_FILE"
QCDT_TOOL="$ROOT/sh/mainline/make-qcdt.py"
BOOTIMG_TOOL="$ROOT/sh/mainline/make-bootimg-qcdt.py"
[[ -f "$QCDT_TOOL" ]] || die "QCDT generator missing: $QCDT_TOOL"
[[ -f "$BOOTIMG_TOOL" ]] || die "boot image generator missing: $BOOTIMG_TOOL"
for artifact in "$IMAGE" "$DTB" "$KERNEL_OUT/System.map" "$KERNEL_OUT/vmlinux"; do
  [ -s "$artifact" ] || die "Kernel artifact missing: $artifact"
done

STAGE="$CACHE_ROOT/mainline/.stage-$$"
MODULES_STAGE="$CACHE_ROOT/mainline/.modules-stage-$$"
rm -rf "$STAGE"
rm -rf "$MODULES_STAGE"
mkdir -p "$STAGE" "$MODULES_STAGE"
trap 'rm -rf "$STAGE" "$MODULES_STAGE"' EXIT

say "Installing modules for kernel $KREL into a staging directory"
kernel_make modules_install INSTALL_MOD_PATH="$MODULES_STAGE" INSTALL_MOD_STRIP=1
MODULE_ARCHIVE="$STAGE/kernel-modules-$KREL.tar.zst"
tar -C "$MODULES_STAGE" -I zstd -cf "$MODULE_ARCHIVE" "lib/modules/$KREL"
rm -rf "$MODULES_STAGE"

cp "$IMAGE" "$STAGE/Image.gz"
cp "$DTB" "$STAGE/sanders.dtb"
cp "$LK2ND_IMAGE" "$STAGE/lk2nd.img"
cp "$KERNEL_OUT/.config" "$STAGE/kernel.config"
cp "$KERNEL_OUT/System.map" "$STAGE/System.map"
cp "$KERNEL_OUT/vmlinux" "$STAGE/vmlinux"
printf '%s\n' "$KREL" > "$STAGE/kernel-release.txt"
printf '%s\n' auto > "$STAGE/panel.txt"

say "Creating Qualcomm QCDT tables for lk2nd"
python3 "$QCDT_TOOL" "$STAGE/dt.img" "$STAGE/sanders.dtb"

validate_qcdt() {
  python3 - "$1" <<'PY'
import struct
import sys

path = sys.argv[1]
data = open(path, "rb").read()
if len(data) < 16:
    raise SystemExit(f"QCDT is too small: {path}")

magic, version, count = struct.unpack_from("<3I", data, 0)
if (magic, version) != (0x54444351, 2):
    raise SystemExit(f"invalid QCDT header in {path}: {magic:#x}/{version}")
if count < 1:
    raise SystemExit(f"QCDT has no entries: {path}")

entries = [struct.unpack_from("<6I", data, 12 + index * 24)
           for index in range(count)]
if len({entry[4] for entry in entries}) != count:
    raise SystemExit(f"QCDT entries reuse a DTB offset: {path}")

for entry in entries:
    _, _, _, _, offset, size = entry
    if offset + size > len(data) or data[offset:offset + 4] != b"\xd0\x0d\xfe\xed":
        raise SystemExit(f"invalid DTB payload in {path}: {entry}")

# This is the tuple reported by a diagnostic Sanders LK2ND build on the
# target device: platform 0x125, hardware 0x8, subtype 0, SOC revision 0.
if not any(entry[:4] == (293, 0x8, 0, 0) for entry in entries):
    raise SystemExit(f"QCDT lacks the target Sanders LK2ND tuple: {path}")
PY
}

validate_qcdt "$STAGE/dt.img"
cat "$IMAGE" "$DTB" > "$STAGE/Image.gz-dtb"

BOOT_ROOT="${SANDERS_BOOT_ROOT:-/dev/mmcblk0p54}"
BOOT_CMDLINE="${SANDERS_BOOT_CMDLINE:-console=tty0 root=$BOOT_ROOT rootfstype=ext4 rw rootwait panic=10 fsck.repair=yes lpm_levels.sleep_disabled=1 msm.prefer_mdp5=true clk_ignore_unused pd_ignore_unused rootdelay=10}"
BOOT_IMAGE="$STAGE/boot.img"

say "Creating Android boot images with the Sanders-tested legacy header"
make_boot_image() {
  local kernel_image="$1" dt_image="$2" output_image="$3"

  python3 "$BOOTIMG_TOOL" \
    --kernel "$kernel_image" \
    --qcdt "$dt_image" \
    --base 0x80000000 \
    --kernel-offset 0x8000 \
    --ramdisk-offset 0x01000000 \
    --tags-offset 0x00000100 \
    --pagesize 2048 \
    --cmdline "$BOOT_CMDLINE" \
    --output "$output_image"

  [ "$(dd if="$output_image" bs=1 count=8 2>/dev/null)" = 'ANDROID!' ] || \
    die "mkbootimg produced an invalid image: $output_image"
  local image_size
  image_size="$(stat -c '%s' "$output_image")"
  [ "$image_size" -le 16777216 ] || die \
    "$output_image is ${image_size} bytes; Sanders boot partition is 16777216 bytes."
}

make_boot_image "$STAGE/Image.gz" "$STAGE/dt.img" "$BOOT_IMAGE"

write_boot_image_info() {
  local kernel_name="$1" dt_name="$2" info_file="$3"

  cat > "$info_file" <<EOF
format=android-bootimg-v0
bootimg_tool=$BOOTIMG_TOOL
kernel=$kernel_name
ramdisk=none
dtb=$dt_name (QCDT v2, selected by lk2nd)
pagesize=2048
base=0x80000000
kernel_offset=0x00008000
ramdisk_offset=0x01000000
tags_offset=0x00000100
root=$BOOT_ROOT
cmdline=$BOOT_CMDLINE
requires_lk2nd=true
lk2nd_boot_partition_offset=512KiB
install_stock_fastboot=fastboot boot lk2nd.img
install_lk2nd_fastboot=fastboot flash lk2nd lk2nd.img; fastboot flash boot boot.img
EOF
}

write_boot_image_info Image.gz dt.img "$STAGE/bootimg-info.txt"

{
  printf 'device=%s\n' "$DEVICE"
  printf 'kernel_url=%s\n' "$KERNEL_URL"
  printf 'kernel_cache=%s\n' "$KERNEL_DIR"
  printf 'kernel_ref=%s\n' "$KERNEL_REF"
  printf 'kernel_source_sha=%s\n' "$SOURCE_SHA"
  printf 'kernel_source_dirty=%s\n' "$([ -n "$SOURCE_DIRTY" ] && echo yes || echo no)"
  printf 'kernel_release=%s\n' "$KREL"
  printf 'panel=auto (%s)\n' "$PANEL_NAME"
  printf 'bootimg_tool=%s\n' "$BOOTIMG_TOOL"
  printf 'bootimg_cmdline=%s\n' "$BOOT_CMDLINE"
  printf 'lk2nd_image=%s\n' "$LK2ND_IMAGE"
  printf 'lk2nd_partition=lk2nd\n'
  printf 'bootimg=Image.gz + dt.img (%s)\n' "$PANEL_NAME"
  printf 'built_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$STAGE/source-report.txt"

(cd "$STAGE" && sha256sum \
  Image.gz Image.gz-dtb dt.img boot.img \
  lk2nd.img \
  bootimg-info.txt sanders.dtb panel.txt \
  kernel.config System.map vmlinux kernel-release.txt \
  "kernel-modules-$KREL.tar.zst" > SHA256SUMS)

MOD_PATH="$MODULE_CACHE/$SOURCE_SHA/$KREL"
mkdir -p "$MOD_PATH"
cp "$MODULE_ARCHIVE" "$MOD_PATH/kernel-modules-$KREL.tar.zst"
printf '%s\n' "$MOD_PATH/kernel-modules-$KREL.tar.zst" > "$MODULE_CACHE/current.txt"

STAMP="$(new_stamp)"
RELEASE="$RELEASES/sanders-$STAMP"
[ ! -e "$RELEASE" ] || die "Release already exists: $RELEASE"
mkdir -p "$RELEASE"
cp -a "$STAGE/." "$RELEASE/"
printf '%s\n' "$RELEASE" > "$BUILD_ROOT/mainline/latest"

# Replace the reusable checkpoint only after every artifact has a checksum.
PREVIOUS="$CACHE_ROOT/mainline/.checkpoint-previous"
rm -rf "$PREVIOUS"
if [ -d "$CHECKPOINT" ]; then mv "$CHECKPOINT" "$PREVIOUS"; fi
if ! mv "$STAGE" "$CHECKPOINT"; then
  [ ! -d "$PREVIOUS" ] || mv "$PREVIOUS" "$CHECKPOINT"
  die 'Could not publish the validated kernel checkpoint.'
fi
trap - EXIT
rm -rf "$PREVIOUS"

say "Kernel build complete"
say "Release: $RELEASE"
say "Checkpoint: $CHECKPOINT"
say "Android boot image: $RELEASE/boot.img ($PANEL_NAME)"
say "LK2ND: $RELEASE/lk2nd.img (flash to the lk2nd partition, not boot)"
say 'The boot image requires LK2ND and boots the ext4 rootfs from eMMC /dev/mmcblk0p54 (userdata).'
if [ -n "$SOURCE_DIRTY" ]; then
  say 'WARNING: the kernel checkout had uncommitted changes; see source-report.txt.'
fi
