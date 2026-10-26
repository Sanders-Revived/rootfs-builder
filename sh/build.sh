#!/usr/bin/env bash
# Small, explicit entry point for the Sanders local builder.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
SANDERS MAINLINE BUILDER

  bash sh/build.sh kernel [--clean|--reuse]
  bash sh/build.sh update
  bash sh/build.sh status
  bash sh/build.sh clean [--outputs]
  bash sh/build.sh rootfs [debian]
  bash sh/build.sh all [--clean|--reuse]

The builder clones the kernel branch barni2000/7.3/develop from
https://github.com/Sanders-Revived/linux.git into its ignored cache.

The builder supports only Debian arm64. It clones the Sanders firmware from
the Vanadium OSS GitLab repository during the rootfs build. It does not run
GitHub Actions or install host packages automatically. The boot image requires
lk2nd: boot lk2nd.img once from stock fastboot, then flash the actual boot.img
from the lk2nd fastboot interface.

One universal boot image is emitted. LK2ND carries the panel identifier from
the stock bootloader (`mdss_mdp.panel`) and rewrites the Sanders DTB to the
matching Tianma or DJN Linux panel driver.
EOF
}

command="${1:-help}"
shift || true
case "$command" in
  kernel) exec bash "$ROOT/sh/mainline/build.sh" "$@" ;;
  update) exec bash "$ROOT/sh/mainline/update-source.sh" "$@" ;;
  status) exec bash "$ROOT/sh/status.sh" "$@" ;;
  clean) exec bash "$ROOT/sh/clean.sh" "$@" ;;
  rootfs) exec bash "$ROOT/sh/rootfs/build.sh" "$@" ;;
  all)
    case "${1:-}" in
      --clean) bash "$ROOT/sh/mainline/build.sh" --clean ;;
      --reuse) bash "$ROOT/sh/mainline/build.sh" --reuse ;;
      '') bash "$ROOT/sh/mainline/build.sh" ;;
      *) usage; exit 2 ;;
    esac
    exec bash "$ROOT/sh/rootfs/build.sh" debian
    ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
