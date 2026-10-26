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
  bash sh/build.sh rootfs alpine|debian|ubuntu
  bash sh/build.sh all [--clean|--reuse]

The default kernel source is /home/light/linux-barni on branch
barni2000/7.3/develop. Override it with SANDERS_KERNEL_DIR.

The kernel build is local and deterministic. It does not clone repositories,
run GitHub Actions, or install host packages automatically. It also publishes
a Sanders-compatible Android boot.img using the local mkbootimg tool. The boot
image requires lk2nd: boot lk2nd.img once from stock fastboot, then flash the
actual boot.img from the lk2nd fastboot interface.
EOF
}

command="${1:-help}"
shift || true
case "$command" in
  kernel) exec bash "$ROOT/sh/mainline/build.sh" "$@" ;;
  update) exec bash "$ROOT/sh/mainline/update-source.sh" "$@" ;;
  status) exec bash "$ROOT/sh/status.sh" "$@" ;;
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
