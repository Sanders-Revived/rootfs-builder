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
NTP_SERVERS="$SANDERS_NTP_SERVERS"
FALLBACK_NTP_SERVERS="$SANDERS_FALLBACK_NTP_SERVERS"
NTP_ROOT_DISTANCE_MAX_SEC="$SANDERS_NTP_ROOT_DISTANCE_MAX_SEC"
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

require_commands mmdebstrap fakechroot fakeroot qemu-aarch64-static rsync tar zstd \
  mkfs.ext4 e2fsck tune2fs blkid truncate sha256sum openssl
sudo -n true 2>/dev/null || die 'Passwordless sudo is required for ext4 image creation.'
[ "$ARCH" = arm64 ] || die "Only arm64 Debian rootfs is supported; got $ARCH."
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
  etc/NetworkManager/conf.d/99-usb0-unmanaged.conf \
  etc/ssh/sshd_config.d/90-sanders-root.conf \
  etc/systemd/system/sanders-ssh-keygen.service \
  etc/systemd/system/usb-gadget.service \
  usr/local/sbin/usb-gadget.sh; do
  [ -f "$OVERLAY_DIR/$overlay_file" ] || die \
    "Runtime overlay file is missing: $OVERLAY_DIR/$overlay_file"
done
[ -s "$CHECKPOINT/Image.gz" ] || die 'Checkpoint Image.gz is missing.'
[ -s "$CHECKPOINT/sanders.dtb" ] || die 'Checkpoint Sanders DTB is missing.'
[ -s /usr/lib/aarch64-linux-gnu/fakechroot/libfakechroot.so ] || die \
  'Missing ARM64 fakechroot library. Install/extract libfakechroot:arm64 for the WSL host.'
[ -s /usr/lib/aarch64-linux-gnu/libfakeroot/libfakeroot-sysv.so ] || die \
  'Missing ARM64 fakeroot library. Install/extract libfakeroot:arm64 for the WSL host.'

case "$SUITE" in
  bookworm|trixie|stable|testing) ;;
  *) die "Unsupported Debian suite: $SUITE" ;;
esac
[[ "$IMAGE_SIZE_MIB" =~ ^[0-9]+$ && "$IMAGE_SIZE_MIB" -ge 256 ]] || \
  die 'SANDERS_DEBIAN_IMAGE_SIZE_MIB must be an integer >= 256.'
[[ "$MIN_FREE_MIB" =~ ^[0-9]+$ ]] || die 'SANDERS_DEBIAN_MIN_FREE_MIB must be an integer.'

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
  chmod 0755 "$ROOTFS_DIR/usr/local/sbin/usb-gadget.sh"

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
  ln -sfn /lib/systemd/system/sanders-ssh-keygen.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/sanders-ssh-keygen.service"
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

mkdir -p "$OUT_DIR" "$RELEASES" "$WORK_ROOT"
sudo -n rm -rf "$ROOTFS_DIR" "$STAGE"
mkdir -p "$ROOTFS_DIR" "$STAGE"
trap 'sudo -n rm -rf "$ROOTFS_DIR" "$STAGE"' EXIT

say "Bootstrapping Debian $SUITE/$ARCH with fakechroot + qemu"
# Debian Trixie's openssh-server postinst runs the target sshd with `-G` while
# configuring the package. On WSL's qemu binfmt wrapper that direct exec can
# lose QEMU_LD_PREFIX even though the rest of mmdebstrap is working. Replace
# only that bootstrap-time probe with the host-side true(1); the real target
# sshd and host keys are initialized by the first-boot unit below.
FAKECHROOT_CMD_SUBST="${FAKECHROOT_CMD_SUBST:-}"
case ":$FAKECHROOT_CMD_SUBST:" in
  *:/usr/sbin/sshd=/bin/true:*) ;;
  *) FAKECHROOT_CMD_SUBST="${FAKECHROOT_CMD_SUBST:+$FAKECHROOT_CMD_SUBST:}/usr/sbin/sshd=/bin/true" ;;
esac
export FAKECHROOT_CMD_SUBST
mmdebstrap \
  --mode=fakechroot \
  --format=directory \
  --architectures="$ARCH" \
  --variant=minbase \
  --components="$COMPONENTS" \
  --include="$PACKAGES" \
  --aptopt='Acquire::Languages "none"' \
  --aptopt='APT::Install-Recommends "false"' \
  --aptopt='APT::Install-Suggests "false"' \
  "$SUITE" "$ROOTFS_DIR" "$MIRROR"

# fakechroot can leak the host-side fake root into absolute symlinks created by
# package maintainer scripts. Those links would be broken after deployment.
say "Normalizing fakechroot symlinks"
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
printf 'kernel_release=%s\n' "$KERNEL_RELEASE" > "$ROOTFS_DIR/etc/sanders-kernel-release"

# Keep the deployable image focused on the Sanders runtime. Documentation,
# manuals, package caches and build-time logs are not needed for boot, Wi-Fi,
# USB networking or SSH and only add noise to the image.
say 'Removing nonessential Debian payload'
rm -rf "$ROOTFS_DIR/usr/share/doc" "$ROOTFS_DIR/usr/share/man" \
  "$ROOTFS_DIR/usr/share/info" "$ROOTFS_DIR/usr/share/lintian"
rm -rf "$ROOTFS_DIR/var/cache/apt/archives/"* "$ROOTFS_DIR/var/log/"*

# fakechroot/fakeroot intentionally leaves files owned by the build user.
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
cat > "$INFO" <<EOF
distribution=debian
suite=$SUITE
architecture=$ARCH
kernel_release=$KERNEL_RELEASE
panel=$PANEL
kernel_source_sha=$SOURCE_SHA
kernel_modules=$KERNEL_MODULES_ARCHIVE
firmware_repository=$FIRMWARE_REPOSITORY_URL
firmware_ref=$FIRMWARE_REF
firmware_source_sha=$FIRMWARE_SHA
image_size_mib=$IMAGE_SIZE_MIB
rootfs_label=$ROOTFS_LABEL
image_free_mib=$FREE_MIB
image_min_free_mib=$MIN_FREE_MIB
ssh_root_password_configured=yes
packages=$PACKAGES
apt_install_recommends=no
apt_install_suggests=no
ntp_servers=$NTP_SERVERS
fallback_ntp_servers=$FALLBACK_NTP_SERVERS
runtime_overlay=$OVERLAY_DIR
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
