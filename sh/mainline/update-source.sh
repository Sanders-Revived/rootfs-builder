#!/usr/bin/env bash
# Explicitly refresh the cached Sanders kernel checkout; never builds.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  cat <<EOF
Usage: bash sh/mainline/update-source.sh

Fetches $KERNEL_REF from $KERNEL_URL and refreshes the ignored checkout at
$KERNEL_DIR. It refuses to overwrite local changes.
EOF
  exit 0
fi
[ "$#" -eq 0 ] || die 'Unexpected arguments. Use --help.'

require_commands git
acquire_lock
ensure_kernel_source
say "Kernel cache is now $(git -C "$KERNEL_DIR" rev-parse --short HEAD)"
