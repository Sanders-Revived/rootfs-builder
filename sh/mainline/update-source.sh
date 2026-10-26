#!/usr/bin/env bash
# Explicitly fast-forward the local Sanders kernel checkout; never builds.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  cat <<EOF
Usage: bash sh/mainline/update-source.sh

Fetches $KERNEL_REF from remote '$KERNEL_REMOTE' and fast-forwards the local
checkout at $KERNEL_DIR. It refuses to overwrite local changes.
EOF
  exit 0
fi
[ "$#" -eq 0 ] || die 'Unexpected arguments. Use --help.'

require_commands git
acquire_lock
ensure_kernel_source
[ -z "$SOURCE_DIRTY" ] || die 'Kernel checkout has local changes; commit or stash them first.'

say "Fetching $KERNEL_REF from $KERNEL_REMOTE"
git -C "$KERNEL_DIR" fetch "$KERNEL_REMOTE" "$KERNEL_REF"
REMOTE_REF="$KERNEL_REMOTE/$KERNEL_REF"
git -C "$KERNEL_DIR" show-ref --verify --quiet "refs/remotes/$REMOTE_REF" || \
  die "Remote branch not found: $REMOTE_REF"
git -C "$KERNEL_DIR" merge --ff-only "$REMOTE_REF"
say "Kernel source is now $(git -C "$KERNEL_DIR" rev-parse --short HEAD)"
