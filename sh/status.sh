#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

printf 'Project: %s\n' "$ROOT"
printf 'Kernel:  %s\n' "$KERNEL_DIR"
if [ -d "$KERNEL_DIR/.git" ]; then
  printf 'Branch:  %s\n' "$(git -C "$KERNEL_DIR" branch --show-current)"
  printf 'Commit:  %s\n' "$(git -C "$KERNEL_DIR" rev-parse --short HEAD)"
  if [ -n "$(git -C "$KERNEL_DIR" status --porcelain --untracked-files=all)" ]; then
    printf 'Source:  dirty\n'
  else
    printf 'Source:  clean\n'
  fi
else
  printf 'Source:  missing\n'
fi

if [ -s "$CHECKPOINT/kernel-release.txt" ]; then
  printf 'Checkpoint: %s (%s)\n' "$CHECKPOINT" "$(cat "$CHECKPOINT/kernel-release.txt")"
  [ ! -s "$CHECKPOINT/source-report.txt" ] || sed -n '1,20p' "$CHECKPOINT/source-report.txt"
else
  printf 'Checkpoint: absent\n'
fi

printf '\nReleases:\n'
find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -printf '  %f\n' 2>/dev/null | sort -r || true
