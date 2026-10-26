#!/usr/bin/env bash
# Remove only generated transient files from the Sanders builder.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_ROOT="$ROOT/cache"

usage() {
  cat <<'EOF'
Usage: bash sh/build.sh clean [--outputs]

Removes generated Python caches, abandoned staging directories and the local
build lock. Source checkouts, published releases and compiler caches remain.

  --outputs  also remove the unpublishable kernel compile output
EOF
}

case "${1:-}" in
  '') ;;
  --outputs) REMOVE_OUTPUTS=1 ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

exec 9>"$CACHE_ROOT/.build.lock"
flock -n 9 || {
  printf 'ERROR [sanders]: a build is still running; cleanup aborted.\n' >&2
  exit 1
}

find "$ROOT/sh" "$ROOT/sources" -type d -name __pycache__ -prune -exec rm -rf -- {} +
find "$CACHE_ROOT/mainline" -maxdepth 1 -type d \
  \( -name '.stage-*' -o -name '.modules-stage-*' -o -name '.checkpoint-previous' \) \
  -prune -exec rm -rf -- {} + 2>/dev/null || true
find "$CACHE_ROOT/rootfs" -maxdepth 3 -type d -name '.stage-*' \
  -prune -exec rm -rf -- {} + 2>/dev/null || true

if [ "${REMOVE_OUTPUTS:-0}" -eq 1 ]; then
  rm -rf "$ROOT/build/mainline/out"
fi

rm -f "$CACHE_ROOT/.build.lock"
printf 'Cleanup complete. Source caches and published releases were kept.\n'
