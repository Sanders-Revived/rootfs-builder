#!/usr/bin/env bash
# Sanders Debian profile. Existing environment variables take precedence.

: "${SANDERS_DEBIAN_SUITE:=trixie}"
: "${SANDERS_DEBIAN_ARCH:=arm64}"
: "${SANDERS_DEBIAN_MIRROR:=http://deb.debian.org/debian}"
: "${SANDERS_DEBIAN_COMPONENTS:=main,contrib,non-free,non-free-firmware}"
# Keep only the runtime required by the Sanders server image. Audio userspace
# is intentionally omitted; the kernel codec remains available for later work.
: "${SANDERS_DEBIAN_PACKAGES:=systemd-sysv udev dbus network-manager wpasupplicant iproute2 iputils-ping kmod e2fsprogs ca-certificates locales openssh-server systemd-timesyncd systemd-zram-generator wireless-regdb rfkill libegl-mesa0 libgl1-mesa-dri libgles2}"
# The kernel embeds the A530 firmware and the Vanadium overlay supplies the
# Sanders WCNSS/ADSP/Venus images. The generic Qualcomm package is ~305 MiB
# of firmware for unrelated SoCs, so opt into it only for experiments.
: "${SANDERS_DEBIAN_INCLUDE_GENERIC_QCOM_FIRMWARE:=0}"
: "${SANDERS_DEBIAN_IMAGE_SIZE_MIB:=1024}"
: "${SANDERS_DEBIAN_MIN_FREE_MIB:=64}"
: "${SANDERS_ROOTFS_LABEL:=debian-root}"
: "${SANDERS_ROOT_PASSWORD:=sanders}"
: "${SANDERS_TIMEZONE:=America/Sao_Paulo}"

# The phone has no battery-backed RTC. Prefer globally reachable servers;
# some Brazilian NTP endpoints silently drop packets on domestic Wi-Fi.
: "${SANDERS_NTP_SERVERS:=pool.ntp.org time.cloudflare.com time.google.com}"
: "${SANDERS_FALLBACK_NTP_SERVERS:=time.google.com time.cloudflare.com}"
: "${SANDERS_NTP_ROOT_DISTANCE_MAX_SEC:=20}"
