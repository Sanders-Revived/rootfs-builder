#!/usr/bin/env bash
# Compatibility wrapper kept for old invocations. Sources are local now.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

case "${1:-}" in
  ''|--check)
    require_commands git
    ensure_kernel_source
    say "Using local kernel checkout: $KERNEL_DIR"
    say "Revision: $SOURCE_SHA"
    ;;
  --update)
    exec bash "$ROOT/sh/mainline/update-source.sh"
    ;;
  -h|--help|help)
    echo 'Usage: bash sh/sources/prepare.sh [--check|--update]'
    ;;
  *)
    die 'Remote recipe cloning was removed. Use --check or --update.'
    ;;
esac
