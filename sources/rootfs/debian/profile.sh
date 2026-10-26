#!/usr/bin/env bash
# Sanders Debian profile. Existing environment variables take precedence.

: "${SANDERS_DEBIAN_SUITE:=trixie}"
: "${SANDERS_DEBIAN_ARCH:=arm64}"
: "${SANDERS_DEBIAN_MIRROR:=http://deb.debian.org/debian}"
: "${SANDERS_DEBIAN_COMPONENTS:=main,contrib,non-free,non-free-firmware}"
: "${SANDERS_DEBIAN_PACKAGES:=systemd-sysv udev dbus network-manager wpasupplicant iproute2 iputils-ping kmod ca-certificates locales openssh-server systemd-timesyncd wireless-regdb rfkill alsa-utils firmware-qcom-soc libegl-mesa0 libgl1-mesa-dri libgles2}"
: "${SANDERS_DEBIAN_INCLUDE_GENERIC_QCOM_FIRMWARE:=1}"
: "${SANDERS_DEBIAN_IMAGE_SIZE_MIB:=1024}"
: "${SANDERS_DEBIAN_MIN_FREE_MIB:=64}"
: "${SANDERS_ROOTFS_LABEL:=debian-root}"
: "${SANDERS_ROOT_PASSWORD:=sanders}"

# The phone has no battery-backed RTC. Keep the first boot deterministic and
# use Brazilian servers before public fallbacks.
: "${SANDERS_NTP_SERVERS:=a.st1.ntp.br b.st1.ntp.br pool.ntp.org}"
: "${SANDERS_FALLBACK_NTP_SERVERS:=time.cloudflare.com time.google.com}"
: "${SANDERS_NTP_ROOT_DISTANCE_MAX_SEC:=20}"
