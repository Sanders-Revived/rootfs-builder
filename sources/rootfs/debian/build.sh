#!/usr/bin/env bash
# Build a minimal Debian arm64 rootfs and embed the validated Sanders kernel.
set -Eeuo pipefail

: "${ROOT:?rootfs runner did not export ROOT}"
: "${BUILD_ROOT:?rootfs runner did not export BUILD_ROOT}"
: "${CACHE_ROOT:?rootfs runner did not export CACHE_ROOT}"
: "${CHECKPOINT:?rootfs runner did not export CHECKPOINT}"
: "${KERNEL_RELEASE:?rootfs runner did not export KERNEL_RELEASE}"
: "${KERNEL_MODULES_ARCHIVE:?rootfs runner did not export KERNEL_MODULES_ARCHIVE}"
: "${KERNEL_CONFIG_FILE:?rootfs runner did not export KERNEL_CONFIG_FILE}"
: "${KERNEL_SYSTEM_MAP_FILE:?rootfs runner did not export KERNEL_SYSTEM_MAP_FILE}"

say() { printf '\n[debian] %s\n' "$*"; }
die() { printf '\nERROR [debian]: %s\n' "$*" >&2; exit 1; }

PROFILE="$ROOT/sources/rootfs/debian/profile.sh"
[ -r "$PROFILE" ] || die "Debian profile is missing: $PROFILE"
# Keep policy/configuration in profile.sh and assembly logic in this recipe.
source "$PROFILE"

SUITE="$SANDERS_DEBIAN_SUITE"
ARCH="$SANDERS_DEBIAN_ARCH"
MIRROR="$SANDERS_DEBIAN_MIRROR"
COMPONENTS="$SANDERS_DEBIAN_COMPONENTS"
PACKAGES="$SANDERS_DEBIAN_PACKAGES"
IMAGE_SIZE_MIB="$SANDERS_DEBIAN_IMAGE_SIZE_MIB"
MIN_FREE_MIB="$SANDERS_DEBIAN_MIN_FREE_MIB"
ROOTFS_LABEL="$SANDERS_ROOTFS_LABEL"
TIMEZONE="$SANDERS_TIMEZONE"
NTP_SERVERS="$SANDERS_NTP_SERVERS"
FALLBACK_NTP_SERVERS="$SANDERS_FALLBACK_NTP_SERVERS"
NTP_ROOT_DISTANCE_MAX_SEC="$SANDERS_NTP_ROOT_DISTANCE_MAX_SEC"
INCLUDE_GENERIC_QCOM_FIRMWARE="$SANDERS_DEBIAN_INCLUDE_GENERIC_QCOM_FIRMWARE"
: "${FIRMWARE_SOURCE_DIR:?rootfs runner did not export FIRMWARE_SOURCE_DIR}"
: "${FIRMWARE_REPOSITORY_URL:?rootfs runner did not export FIRMWARE_REPOSITORY_URL}"
: "${FIRMWARE_REF:?rootfs runner did not export FIRMWARE_REF}"
: "${FIRMWARE_SHA:?rootfs runner did not export FIRMWARE_SHA}"

OUT_DIR="$BUILD_ROOT/rootfs/debian"
WORK_ROOT="$CACHE_ROOT/rootfs/debian"
ROOTFS_DIR="$WORK_ROOT/rootfs"
STAGE="$WORK_ROOT/.stage-$$"
RELEASES="$OUT_DIR/releases"
OVERLAY_DIR="$ROOT/sources/rootfs/debian/overlay"

require_commands() {
  local missing=() command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  ((${#missing[@]} == 0)) || die "Missing Debian rootfs tools: ${missing[*]}"
}

require_commands mmdebstrap qemu-aarch64-static rsync tar zstd \
  mkfs.ext4 e2fsck tune2fs blkid truncate sha256sum openssl
sudo -n true 2>/dev/null || die 'Passwordless sudo is required for ext4 image creation.'
[ "$ARCH" = arm64 ] || die "Only arm64 Debian rootfs is supported; got $ARCH."

# Use mmdebstrap's root mode by default. This WSL environment already grants
# passwordless sudo for image creation, and root mode copies static QEMU into
# the target chroot instead of relying on the host binfmt loader prefix.
MMDEBSTRAP_MODE="${SANDERS_MMDEBSTRAP_MODE:-root}"
case "$MMDEBSTRAP_MODE" in
  root)
    sudo -n true 2>/dev/null || die 'Passwordless sudo is required for SANDERS_MMDEBSTRAP_MODE=root.'
    ;;
  *)
    die "Unsupported SANDERS_MMDEBSTRAP_MODE: $MMDEBSTRAP_MODE (use root)."
    ;;
esac
[ -s "$KERNEL_MODULES_ARCHIVE" ] || die "Kernel modules archive is missing: $KERNEL_MODULES_ARCHIVE"
[ -s "$KERNEL_CONFIG_FILE" ] || die "Kernel config is missing: $KERNEL_CONFIG_FILE"
[ -s "$KERNEL_SYSTEM_MAP_FILE" ] || die "Kernel System.map is missing: $KERNEL_SYSTEM_MAP_FILE"
[ -s "$FIRMWARE_SOURCE_DIR/wlan/WCNSS_qcom_wlan_nv.bin" ] || die \
  "Sanders firmware NV file is missing: $FIRMWARE_SOURCE_DIR/wlan/WCNSS_qcom_wlan_nv.bin"
[ -d "$FIRMWARE_SOURCE_DIR/modem/image" ] || die \
  "Sanders modem firmware directory is missing: $FIRMWARE_SOURCE_DIR/modem/image"
for zap_name in a506_zap.mdt a506_zap.b00 a506_zap.b01 a506_zap.b02; do
  [ -s "$FIRMWARE_SOURCE_DIR/modem/image/$zap_name" ] || die \
    "Sanders Adreno 506 firmware is missing: $FIRMWARE_SOURCE_DIR/modem/image/$zap_name"
done
[ -d "$OVERLAY_DIR" ] || die "Runtime overlay is missing: $OVERLAY_DIR"
for overlay_file in \
  etc/hosts \
  etc/fstab \
  etc/modprobe.d/sanders.conf \
  etc/modules-load.d/sanders.conf \
  etc/systemd/zram-generator.conf \
  etc/NetworkManager/conf.d/99-usb0-unmanaged.conf \
  etc/ssh/sshd_config.d/90-sanders-root.conf \
  etc/systemd/system/sanders-ssh-hostkeys.service \
  etc/systemd/system/sanders-time-sync.service \
  etc/systemd/system/sanders-grow-rootfs.service \
  etc/systemd/system/usb-gadget.service \
  usr/local/sbin/usb-gadget.sh \
  usr/local/sbin/sanders-time-sync \
  usr/local/sbin/sanders-grow-rootfs; do
  [ -f "$OVERLAY_DIR/$overlay_file" ] || die \
    "Runtime overlay file is missing: $OVERLAY_DIR/$overlay_file"
done
[ -s "$CHECKPOINT/Image.gz" ] || die 'Checkpoint Image.gz is missing.'
[ -s "$CHECKPOINT/sanders.dtb" ] || die 'Checkpoint Sanders DTB is missing.'

case "$SUITE" in
  bookworm|trixie|stable|testing) ;;
  *) die "Unsupported Debian suite: $SUITE" ;;
esac
[[ "$IMAGE_SIZE_MIB" =~ ^[0-9]+$ && "$IMAGE_SIZE_MIB" -ge 256 ]] || \
  die 'SANDERS_DEBIAN_IMAGE_SIZE_MIB must be an integer >= 256.'
[[ "$MIN_FREE_MIB" =~ ^[0-9]+$ ]] || die 'SANDERS_DEBIAN_MIN_FREE_MIB must be an integer.'
case "$INCLUDE_GENERIC_QCOM_FIRMWARE" in
  0|1) ;;
  *) die 'SANDERS_DEBIAN_INCLUDE_GENERIC_QCOM_FIRMWARE must be 0 or 1.' ;;
esac
[ -f "/usr/share/zoneinfo/$TIMEZONE" ] || die "Unknown timezone: $TIMEZONE"

if [ "$INCLUDE_GENERIC_QCOM_FIRMWARE" -eq 0 ]; then
  # The kernel embeds A530 firmware and the Sanders firmware checkout supplies
  # the WCNSS/ADSP/Venus images used by this device. The generic Qualcomm
  # package is optional and contains firmware for many unrelated SoCs.
  PACKAGES="${PACKAGES//firmware-qcom-soc/}"
fi

normalize_rootfs_symlinks() {
  local link target normalized
  while IFS= read -r -d '' link; do
    target="$(readlink "$link")"
    case "$target" in
      "$ROOTFS_DIR"/*)
        normalized="/${target#"$ROOTFS_DIR"/}"
        rm -f "$link"
        ln -s "$normalized" "$link"
        ;;
    esac
  done < <(find "$ROOTFS_DIR" -type l -print0)
}

audit_rootfs_symlinks() {
  local link target
  while IFS= read -r -d '' link; do
    target="$(readlink "$link")"
    case "$target" in
      "$ROOTFS_DIR"/*|/home/light/*)
        die "Host path leaked into rootfs symlink: $link -> $target"
        ;;
    esac
  done < <(find "$ROOTFS_DIR" -type l -print0)
}

install_runtime_overlay() {
  say 'Installing Sanders runtime overlay'
  rsync -a "$OVERLAY_DIR/" "$ROOTFS_DIR/"
  chmod 0755 "$ROOTFS_DIR/usr/local/sbin/usb-gadget.sh" \
    "$ROOTFS_DIR/usr/local/sbin/sanders-time-sync" \
    "$ROOTFS_DIR/usr/local/sbin/sanders-grow-rootfs"

  mkdir -p \
    "$ROOTFS_DIR/etc/systemd/timesyncd.conf.d" \
    "$ROOTFS_DIR/etc/systemd/system/sysinit.target.wants" \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants"

  cat > "$ROOTFS_DIR/etc/systemd/timesyncd.conf.d/sanders.conf" <<EOF
[Time]
NTP=$NTP_SERVERS
FallbackNTP=$FALLBACK_NTP_SERVERS
RootDistanceMaxSec=$NTP_ROOT_DISTANCE_MAX_SEC
EOF

  ln -sfn /lib/systemd/system/systemd-timesyncd.service \
    "$ROOTFS_DIR/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service"
  ln -sfn ../usb-gadget.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/usb-gadget.service"
  ln -sfn ../sanders-ssh-hostkeys.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/sanders-ssh-hostkeys.service"
  ln -sfn ../sanders-time-sync.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/sanders-time-sync.service"
  ln -sfn ../sanders-grow-rootfs.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/sanders-grow-rootfs.service"
}

configure_root_password() {
  say 'Configuring the root SSH password'
  local root_password_hash
  root_password_hash="$(printf '%s' "$SANDERS_ROOT_PASSWORD" | openssl passwd -6 -stdin)"
  awk -F: -v hash="$root_password_hash" 'BEGIN { OFS=FS } $1 == "root" { $2 = hash } { print }' \
    "$ROOTFS_DIR/etc/shadow" > "$ROOTFS_DIR/etc/shadow.new"
  mv "$ROOTFS_DIR/etc/shadow.new" "$ROOTFS_DIR/etc/shadow"
  ln -sfn /lib/systemd/system/ssh.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/ssh.service"
}

configure_timezone() {
  say "Configuring timezone $TIMEZONE"
  ln -sfn "/usr/share/zoneinfo/$TIMEZONE" "$ROOTFS_DIR/etc/localtime"
  printf '%s\n' "$TIMEZONE" > "$ROOTFS_DIR/etc/timezone"
}

mkdir -p "$OUT_DIR" "$RELEASES" "$WORK_ROOT"
sudo -n rm -rf "$ROOTFS_DIR" "$STAGE"
mkdir -p "$ROOTFS_DIR" "$STAGE"
trap 'sudo -n rm -rf "$ROOTFS_DIR" "$STAGE"' EXIT

say "Bootstrapping Debian $SUITE/$ARCH with $MMDEBSTRAP_MODE + qemu"
# Root mode copies qemu-aarch64-static into the target, so maintainer scripts
# can execute ARM64 programs with the target's own loader and libraries.
sudo -n mmdebstrap \
  --mode="$MMDEBSTRAP_MODE" \
  --format=directory \
  --architectures="$ARCH" \
  --variant=minbase \
  --components="$COMPONENTS" \
  --include="$PACKAGES" \
  --skip=check/qemu \
  --setup-hook='mkdir -p "$1/usr/libexec/qemu-binfmt" && cp /usr/bin/qemu-aarch64-static "$1/usr/libexec/qemu-binfmt/aarch64-binfmt-P" && chmod 0755 "$1/usr/libexec/qemu-binfmt/aarch64-binfmt-P"' \
  --aptopt='Acquire::Languages "none"' \
  --aptopt='APT::Install-Recommends "false"' \
  --aptopt='APT::Install-Suggests "false"' \
  "$SUITE" "$ROOTFS_DIR" "$MIRROR"

# Continue the assembly as the build user; ownership is normalized to 0:0
# again immediately before the deployable tarball and ext4 image are made.
sudo -n chown -R "$(id -u):$(id -g)" "$ROOTFS_DIR"

# Normalize absolute symlinks created by package maintainer scripts before
# overlay files are added to the deployed rootfs.
say "Normalizing rootfs symlinks"
normalize_rootfs_symlinks
audit_rootfs_symlinks

say "Embedding kernel $KERNEL_RELEASE"
mkdir -p "$ROOTFS_DIR/boot" "$ROOTFS_DIR/etc/modprobe.d" "$ROOTFS_DIR/etc/systemd/system"
tar -I zstd -xf "$KERNEL_MODULES_ARCHIVE" -C "$ROOTFS_DIR" --no-same-owner
# modules_install records build/source links from the host output tree. They
# are useful on the build host but must not escape the deployed rootfs.
for MODULE_LINK in \
  "$ROOTFS_DIR/usr/lib/modules/$KERNEL_RELEASE/build" \
  "$ROOTFS_DIR/usr/lib/modules/$KERNEL_RELEASE/source"; do
  [ ! -L "$MODULE_LINK" ] || rm -f "$MODULE_LINK"
done
audit_rootfs_symlinks

# Debian's generic firmware packages do not contain all firmware used by the
# Sanders multimedia, remoteproc and WCNSS stacks. Clone the maintained
# Vanadium OSS repository at build time and install its modem image plus the
# Sanders-specific WLAN calibration/configuration files.
say "Installing Sanders firmware commit $FIRMWARE_SHA"
mkdir -p "$ROOTFS_DIR/usr/lib/firmware/postmarketos" \
  "$ROOTFS_DIR/usr/lib/firmware/qcom/msm8953/motorola/sanders" \
  "$ROOTFS_DIR/usr/lib/firmware/wlan/prima"
cp -a "$FIRMWARE_SOURCE_DIR/modem/image/." \
  "$ROOTFS_DIR/usr/lib/firmware/postmarketos/"
mkdir -p "$ROOTFS_DIR/usr/lib/firmware/qcom/msm8953/motorola/sanders"
for zap_name in a506_zap.mdt a506_zap.b00 a506_zap.b01 a506_zap.b02; do
  cp "$FIRMWARE_SOURCE_DIR/modem/image/$zap_name" \
    "$ROOTFS_DIR/usr/lib/firmware/qcom/msm8953/motorola/sanders/"
done
for firmware_path in "$FIRMWARE_SOURCE_DIR/modem/image/"*; do
  [ -f "$firmware_path" ] || continue
  firmware_name="${firmware_path##*/}"
  ln -sfn "postmarketos/$firmware_name" \
    "$ROOTFS_DIR/usr/lib/firmware/$firmware_name"
done
cp "$FIRMWARE_SOURCE_DIR/wlan/WCNSS_qcom_wlan_nv.bin" \
  "$ROOTFS_DIR/usr/lib/firmware/qcom/msm8953/motorola/sanders/"
for wlan_name in WCNSS_cfg.dat WCNSS_qcom_cfg.ini; do
  [ -s "$FIRMWARE_SOURCE_DIR/wlan/$wlan_name" ] || continue
  cp "$FIRMWARE_SOURCE_DIR/wlan/$wlan_name" \
    "$ROOTFS_DIR/usr/lib/firmware/wlan/prima/$wlan_name"
done
ln -sfn ../../qcom/msm8953/motorola/sanders/WCNSS_qcom_wlan_nv.bin \
  "$ROOTFS_DIR/usr/lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin"
audit_rootfs_symlinks

cp "$CHECKPOINT/Image.gz" "$ROOTFS_DIR/boot/Image.gz-$KERNEL_RELEASE"
cp "$CHECKPOINT/sanders.dtb" "$ROOTFS_DIR/boot/sanders.dtb"
cp "$KERNEL_CONFIG_FILE" "$ROOTFS_DIR/boot/config-$KERNEL_RELEASE"
cp "$KERNEL_SYSTEM_MAP_FILE" "$ROOTFS_DIR/boot/System.map-$KERNEL_RELEASE"
ln -sfn "Image.gz-$KERNEL_RELEASE" "$ROOTFS_DIR/boot/Image.gz"
ln -sfn "Image.gz-$KERNEL_RELEASE" "$ROOTFS_DIR/boot/vmlinuz"

printf '%s\n' sanders > "$ROOTFS_DIR/etc/hostname"
install_runtime_overlay
configure_root_password
configure_timezone
printf 'kernel_release=%s\n' "$KERNEL_RELEASE" > "$ROOTFS_DIR/etc/sanders-kernel-release"

sanitize_rootfs() {
  # Keep the image reproducible. Host keys are generated by the explicit
  # Sanders first-boot unit below; mmdebstrap runs package postinst scripts in
  # the ARM64 chroot, so any keys created there must be removed.
  say 'Removing build-time identities and helpers'
  find "$ROOTFS_DIR/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -delete
  rm -f "$ROOTFS_DIR/root/.bash_history" \
    "$ROOTFS_DIR/var/lib/systemd/random-seed" \
    "$ROOTFS_DIR/var/lib/NetworkManager/secret_key" \
    "$ROOTFS_DIR/usr/bin/qemu-aarch64-static" \
    "$ROOTFS_DIR/usr/libexec/qemu-binfmt/aarch64-binfmt-P"
  : > "$ROOTFS_DIR/etc/machine-id"
  rm -f "$ROOTFS_DIR/var/lib/dbus/machine-id"
  ln -s /etc/machine-id "$ROOTFS_DIR/var/lib/dbus/machine-id"

  # The Adreno PM4/PFP blobs are embedded in Image.gz for pre-rootfs GPU
  # initialization. Remove only those duplicate copies; keep generic Qualcomm
  # firmware for Venus, remoteproc and WCNSS userspace requests.
  rm -f "$ROOTFS_DIR/usr/lib/firmware/qcom/a530_pm4.fw" \
    "$ROOTFS_DIR/usr/lib/firmware/qcom/a530_pfp.fw"

  # Keep directories but remove caches, logs, package indexes and interpreter
  # bytecode that can only have come from the build environment.
  mkdir -p "$ROOTFS_DIR/tmp" "$ROOTFS_DIR/var/tmp"
  for clean_dir in \
    "$ROOTFS_DIR/usr/share/doc" \
    "$ROOTFS_DIR/usr/share/man" \
    "$ROOTFS_DIR/usr/share/info" \
    "$ROOTFS_DIR/usr/share/lintian" \
    "$ROOTFS_DIR/var/cache/apt/archives" \
    "$ROOTFS_DIR/var/lib/apt/lists" \
    "$ROOTFS_DIR/var/log" \
    "$ROOTFS_DIR/tmp" \
    "$ROOTFS_DIR/var/tmp"; do
    [ -d "$clean_dir" ] || continue
    find "$clean_dir" -mindepth 1 -delete
  done
  find "$ROOTFS_DIR" -xdev -type f -name '*.pyc' -delete
  chmod 1777 "$ROOTFS_DIR/tmp" "$ROOTFS_DIR/var/tmp"
}

audit_rootfs_runtime() {
  local required
  for required in \
    /sbin/init \
    /usr/sbin/sshd \
    /usr/sbin/NetworkManager \
    /usr/bin/nmcli \
    /sbin/wpa_supplicant \
    /usr/bin/timedatectl \
    /sbin/resize2fs \
    /boot/Image.gz \
    /boot/sanders.dtb \
    /usr/lib/firmware/qcom/msm8953/motorola/sanders/a506_zap.mdt \
    /usr/lib/firmware/qcom/msm8953/motorola/sanders/WCNSS_qcom_wlan_nv.bin; do
    [ -e "$ROOTFS_DIR$required" ] || die "Required runtime file is missing: $required"
  done
  [ ! -e "$ROOTFS_DIR/usr/bin/qemu-aarch64-static" ] || die 'QEMU helper leaked into rootfs.'
  [ ! -e "$ROOTFS_DIR/usr/libexec/qemu-binfmt/aarch64-binfmt-P" ] || \
    die 'QEMU binfmt helper leaked into rootfs.'
  if find "$ROOTFS_DIR/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -print -quit | grep -q .; then
    die 'Build-time SSH host key leaked into rootfs.'
  fi
  [ ! -s "$ROOTFS_DIR/etc/machine-id" ] || die 'Build-time machine-id leaked into rootfs.'
  [ -L "$ROOTFS_DIR/var/lib/dbus/machine-id" ] || die 'dbus machine-id is not a first-boot symlink.'
  if find "$ROOTFS_DIR/var/lib/apt/lists" -mindepth 1 -print -quit | grep -q .; then
    die 'APT indexes were not removed from rootfs.'
  fi
  audit_rootfs_symlinks
}

sanitize_rootfs
audit_rootfs_runtime

# Normalize ownership before creating the deployable tarball and ext4 image.
sudo -n chown -R 0:0 "$ROOTFS_DIR"

TARBALL="$STAGE/debian-${SUITE}-${ARCH}-sanders-$KERNEL_RELEASE.tar.zst"
IMAGE="$STAGE/debian-${SUITE}-${ARCH}-sanders-$KERNEL_RELEASE.ext4"
INFO="$STAGE/build-info.txt"

say "Creating Debian tarball"
sudo -n tar --numeric-owner --xattrs --acls -I zstd -cf "$TARBALL" -C "$ROOTFS_DIR" .

say "Creating ${IMAGE_SIZE_MIB} MiB ext4 image"
truncate -s "${IMAGE_SIZE_MIB}M" "$IMAGE"
sudo -n mkfs.ext4 -F -m 0 -N 32768 -J size=16 -L "$ROOTFS_LABEL" -U random -d "$ROOTFS_DIR" "$IMAGE" >/dev/null
sudo -n e2fsck -fn "$IMAGE" >/dev/null

FS_STATS="$(sudo -n tune2fs -l "$IMAGE")"
FREE_BLOCKS="$(printf '%s\n' "$FS_STATS" | awk -F: '$1 == "Free blocks" {gsub(/[[:space:]]/, "", $2); print $2}')"
BLOCK_SIZE="$(printf '%s\n' "$FS_STATS" | awk -F: '$1 == "Block size" {gsub(/[[:space:]]/, "", $2); print $2}')"
[[ "$FREE_BLOCKS" =~ ^[0-9]+$ && "$BLOCK_SIZE" =~ ^[0-9]+$ ]] || die 'Could not inspect ext4 free space.'
FREE_MIB=$((FREE_BLOCKS * BLOCK_SIZE / 1024 / 1024))
[ "$FREE_MIB" -ge "$MIN_FREE_MIB" ] || die "Debian image has only ${FREE_MIB} MiB free; need ${MIN_FREE_MIB} MiB."

SOURCE_SHA="unknown"
[ -s "$CHECKPOINT/source-report.txt" ] && SOURCE_SHA="$(awk -F= '$1 == "kernel_source_sha" {print $2}' "$CHECKPOINT/source-report.txt")"
PANEL="unknown"
[ -s "$CHECKPOINT/panel.txt" ] && PANEL="$(cat "$CHECKPOINT/panel.txt")"
ROOTFS_PAYLOAD_BYTES="$(sudo -n du -sb "$ROOTFS_DIR" | cut -f1)"
cat > "$INFO" <<EOF
distribution=debian
suite=$SUITE
architecture=$ARCH
kernel_release=$KERNEL_RELEASE
panel=$PANEL
kernel_source_sha=$SOURCE_SHA
kernel_modules=cache/mainline/checkpoint/kernel-modules-$KERNEL_RELEASE.tar.zst
firmware_repository=$FIRMWARE_REPOSITORY_URL
firmware_ref=$FIRMWARE_REF
firmware_source_sha=$FIRMWARE_SHA
generic_qcom_firmware=$INCLUDE_GENERIC_QCOM_FIRMWARE
image_size_mib=$IMAGE_SIZE_MIB
rootfs_label=$ROOTFS_LABEL
image_free_mib=$FREE_MIB
image_min_free_mib=$MIN_FREE_MIB
rootfs_payload_bytes=$ROOTFS_PAYLOAD_BYTES
ssh_root_password_configured=yes
ssh_host_keys=generated_on_first_boot
machine_id=generated_on_first_boot
qemu_build_helpers=removed
embedded_gpu_runtime_duplicates=removed
packages=$PACKAGES
apt_install_recommends=no
apt_install_suggests=no
ntp_servers=$NTP_SERVERS
fallback_ntp_servers=$FALLBACK_NTP_SERVERS
timezone=$TIMEZONE
runtime_overlay=sources/rootfs/debian/overlay
built_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

STAMP="$(date -u +%Y%m%d%H%M%S)"
RELEASE="$RELEASES/debian-${SUITE}-${ARCH}-$STAMP"
mkdir -p "$RELEASE"
cp "$TARBALL" "$RELEASE/"
cp "$IMAGE" "$RELEASE/"
cp "$INFO" "$RELEASE/build-info.txt"
(cd "$RELEASE" && sha256sum -- build-info.txt *.ext4 *.tar.zst > SHA256SUMS)
# Keep latest as a regular pointer file; remove only an old generated symlink.
if [ -L "$OUT_DIR/latest" ]; then
  rm -f -- "$OUT_DIR/latest"
fi
printf '%s\n' "$RELEASE" > "$OUT_DIR/latest"

say "Debian rootfs complete"
say "Release: $RELEASE"
say "Free ext4 space: ${FREE_MIB} MiB"
