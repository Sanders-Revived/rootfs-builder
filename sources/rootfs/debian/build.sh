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

SUITE="${SANDERS_DEBIAN_SUITE:-bookworm}"
ARCH="${SANDERS_DEBIAN_ARCH:-arm64}"
MIRROR="${SANDERS_DEBIAN_MIRROR:-http://deb.debian.org/debian}"
COMPONENTS="${SANDERS_DEBIAN_COMPONENTS:-main,contrib,non-free,non-free-firmware}"
PACKAGES="${SANDERS_DEBIAN_PACKAGES:-systemd-sysv udev dbus network-manager wpasupplicant iproute2 iputils-ping kmod usbutils ca-certificates locales openssh-server sudo less nano firmware-atheros firmware-qcom-soc}"
IMAGE_SIZE_MIB="${SANDERS_DEBIAN_IMAGE_SIZE_MIB:-4096}"
MIN_FREE_MIB="${SANDERS_DEBIAN_MIN_FREE_MIB:-64}"
ROOTFS_LABEL="${SANDERS_ROOTFS_LABEL:-debian-root}"
: "${FIRMWARE_SOURCE_DIR:?rootfs runner did not export FIRMWARE_SOURCE_DIR}"
: "${FIRMWARE_REPOSITORY_URL:?rootfs runner did not export FIRMWARE_REPOSITORY_URL}"
: "${FIRMWARE_REF:?rootfs runner did not export FIRMWARE_REF}"
: "${FIRMWARE_SHA:?rootfs runner did not export FIRMWARE_SHA}"

OUT_DIR="$BUILD_ROOT/rootfs/debian"
WORK_ROOT="$CACHE_ROOT/rootfs/debian"
ROOTFS_DIR="$WORK_ROOT/rootfs"
STAGE="$WORK_ROOT/.stage-$$"
RELEASES="$OUT_DIR/releases"

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
[ -s "$CHECKPOINT/Image.gz" ] || die 'Checkpoint Image.gz is missing.'
[ -s "$CHECKPOINT/msm8953-motorola-sanders.dtb" ] || die 'Checkpoint Sanders DTB is missing.'
[ -s "$CHECKPOINT/msm8953-motorola-sanders-djn.dtb" ] || die 'Checkpoint Sanders DJN DTB is missing.'
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

mkdir -p "$OUT_DIR" "$RELEASES" "$WORK_ROOT"
sudo -n rm -rf "$ROOTFS_DIR" "$STAGE"
mkdir -p "$ROOTFS_DIR" "$STAGE"
trap 'sudo -n rm -rf "$ROOTFS_DIR" "$STAGE"' EXIT

say "Bootstrapping Debian $SUITE/$ARCH with fakechroot + qemu"
mmdebstrap \
  --mode=fakechroot \
  --format=directory \
  --architectures="$ARCH" \
  --variant=minbase \
  --components="$COMPONENTS" \
  --include="$PACKAGES" \
  --aptopt='Acquire::Languages "none"' \
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
cp "$CHECKPOINT/msm8953-motorola-sanders.dtb" "$ROOTFS_DIR/boot/msm8953-motorola-sanders.dtb"
cp "$CHECKPOINT/msm8953-motorola-sanders-djn.dtb" "$ROOTFS_DIR/boot/msm8953-motorola-sanders-djn.dtb"
cp "$KERNEL_CONFIG_FILE" "$ROOTFS_DIR/boot/config-$KERNEL_RELEASE"
cp "$KERNEL_SYSTEM_MAP_FILE" "$ROOTFS_DIR/boot/System.map-$KERNEL_RELEASE"
ln -sfn "Image.gz-$KERNEL_RELEASE" "$ROOTFS_DIR/boot/Image.gz"
ln -sfn "Image.gz-$KERNEL_RELEASE" "$ROOTFS_DIR/boot/vmlinuz"

printf '%s\n' sanders > "$ROOTFS_DIR/etc/hostname"
cat > "$ROOTFS_DIR/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 sanders
::1 localhost ip6-localhost ip6-loopback
EOF
cat > "$ROOTFS_DIR/etc/fstab" <<'EOF'
LABEL=debian-root / ext4 defaults 0 1
EOF
cat > "$ROOTFS_DIR/etc/modprobe.d/sanders.conf" <<'EOF'
# Sanders mainline modules are installed from the matching kernel checkpoint.
EOF
mkdir -p "$ROOTFS_DIR/etc/modules-load.d"
cat > "$ROOTFS_DIR/etc/modules-load.d/sanders.conf" <<'EOF'
# The WCNSS child is not always auto-loaded from the legacy qcom,wcnss node.
qcom_wcnss_pil
wcn36xx
EOF

# Expose the same USB RNDIS network used by the donor image. Keeping the
# gadget RNDIS-only is important on Sanders: adding ACM can prevent the USB
# device from enumerating consistently, which also removes the SSH transport.
mkdir -p "$ROOTFS_DIR/usr/local/sbin" "$ROOTFS_DIR/etc/systemd/system"
cat > "$ROOTFS_DIR/usr/local/sbin/usb-gadget.sh" <<'EOF'
#!/bin/sh
set -e

G=/sys/kernel/config/usb_gadget/sanders
mount -t configfs none /sys/kernel/config 2>/dev/null || true
mkdir -p "$G/strings/0x409" "$G/functions/rndis.usb0" \
  "$G/functions/rndis.usb0/os_desc/interface.rndis" \
  "$G/configs/c.1/strings/0x409" "$G/os_desc"
echo 0x05c6 > "$G/idVendor"
echo 0x90db > "$G/idProduct"
# Advertise the USB composite/IAD class used by Windows' inbox RNDIS INF.
# Without this, Windows sees the RNDIS interface as an unknown 02/06/00
# device and leaves it at Code 28 even though netrndis.inf is installed.
echo 0xef > "$G/bDeviceClass"
echo 0x04 > "$G/bDeviceSubClass"
echo 0x01 > "$G/bDeviceProtocol"
echo sanders > "$G/strings/0x409/manufacturer"
echo sanders > "$G/strings/0x409/product"
echo 42:61:6e:64:65:72 > "$G/functions/rndis.usb0/host_addr"
echo 42:61:6e:64:65:73 > "$G/functions/rndis.usb0/dev_addr"
echo rndis > "$G/configs/c.1/strings/0x409/configuration"
# Publish the Microsoft OS descriptor that makes Windows bind its built-in
# Remote NDIS driver instead of leaving the interface as an unknown device.
echo 1 > "$G/os_desc/use"
echo 0xcd > "$G/os_desc/b_vendor_code"
echo MSFT100 > "$G/os_desc/qw_sign"
echo RNDIS > "$G/functions/rndis.usb0/os_desc/interface.rndis/compatible_id"
echo 5162001 > "$G/functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id"
ln -sfn "$G/functions/rndis.usb0" "$G/configs/c.1/"
ln -sfn "$G/configs/c.1" "$G/os_desc/"

for i in $(seq 1 30); do
    UDC=$(ls /sys/class/udc/ 2>/dev/null | head -n 1)
    [ -n "$UDC" ] && break
    sleep 1
done
[ -n "${UDC:-}" ] || { echo no-udc >&2; exit 1; }
echo "$UDC" > "$G/UDC"
ip addr add 172.16.42.1/24 dev usb0 2>/dev/null || true
ip link set usb0 up 2>/dev/null || true
EOF
chmod 0755 "$ROOTFS_DIR/usr/local/sbin/usb-gadget.sh"

mkdir -p "$ROOTFS_DIR/etc/NetworkManager/conf.d"
cat > "$ROOTFS_DIR/etc/NetworkManager/conf.d/99-usb0-unmanaged.conf" <<'EOF'
[keyfile]
unmanaged-devices=interface-name:usb0
EOF

mkdir -p "$ROOTFS_DIR/etc/ssh/sshd_config.d"
cat > "$ROOTFS_DIR/etc/ssh/sshd_config.d/90-sanders-root.conf" <<'EOF'
# Enable root SSH for a locally configured test password or authorized key.
PermitRootLogin yes
PasswordAuthentication yes
EOF

if [ -n "${SANDERS_ROOT_PASSWORD:-}" ]; then
  say 'Configuring the requested root password for SSH'
  ROOT_PASSWORD_HASH="$(printf '%s' "$SANDERS_ROOT_PASSWORD" | openssl passwd -6 -stdin)"
  awk -F: -v hash="$ROOT_PASSWORD_HASH" 'BEGIN { OFS=FS } $1 == "root" { $2 = hash } { print }' \
    "$ROOTFS_DIR/etc/shadow" > "$ROOTFS_DIR/etc/shadow.new"
  mv "$ROOTFS_DIR/etc/shadow.new" "$ROOTFS_DIR/etc/shadow"
fi
if [ -n "${SANDERS_SSH_AUTHORIZED_KEY_FILE:-}" ]; then
  [ -s "$SANDERS_SSH_AUTHORIZED_KEY_FILE" ] || die \
    "SSH authorized-key file is missing: $SANDERS_SSH_AUTHORIZED_KEY_FILE"
  SANDERS_SSH_AUTHORIZED_KEY="$(cat "$SANDERS_SSH_AUTHORIZED_KEY_FILE")"
fi
if [ -n "${SANDERS_SSH_AUTHORIZED_KEY:-}" ]; then
  say 'Installing the requested root SSH authorized key'
  install -d -m 0700 "$ROOTFS_DIR/root/.ssh"
  printf '%s\n' "$SANDERS_SSH_AUTHORIZED_KEY" > "$ROOTFS_DIR/root/.ssh/authorized_keys"
  chmod 0600 "$ROOTFS_DIR/root/.ssh/authorized_keys"
fi
ln -sfn /lib/systemd/system/ssh.service \
  "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/ssh.service"

cat > "$ROOTFS_DIR/etc/systemd/system/usb-gadget.service" <<'EOF'
[Unit]
Description=USB gadget networking
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/usb-gadget.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants"
ln -sfn ../usb-gadget.service \
  "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/usb-gadget.service"
printf 'kernel_release=%s\n' "$KERNEL_RELEASE" > "$ROOTFS_DIR/etc/sanders-kernel-release"

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
cat > "$INFO" <<EOF
distribution=debian
suite=$SUITE
architecture=$ARCH
kernel_release=$KERNEL_RELEASE
kernel_source_sha=$SOURCE_SHA
kernel_modules=$KERNEL_MODULES_ARCHIVE
firmware_repository=$FIRMWARE_REPOSITORY_URL
firmware_ref=$FIRMWARE_REF
firmware_source_sha=$FIRMWARE_SHA
image_size_mib=$IMAGE_SIZE_MIB
rootfs_label=$ROOTFS_LABEL
image_free_mib=$FREE_MIB
image_min_free_mib=$MIN_FREE_MIB
ssh_root_password_configured=$([ -n "${SANDERS_ROOT_PASSWORD:-}" ] && printf yes || printf no)
ssh_authorized_key_configured=$([ -n "${SANDERS_SSH_AUTHORIZED_KEY:-}" ] || [ -n "${SANDERS_SSH_AUTHORIZED_KEY_FILE:-}" ] && printf yes || printf no)
packages=$PACKAGES
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
