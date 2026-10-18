#!/usr/bin/env bash
# Tests the tar backup backend and its retention. Needs GNU date and tar (Linux), zstd and gzip, but no
# Docker or Borg. On macOS run it in a container: see AGENTS.md.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# shellcheck source=/dev/null
source ./stackctl
as_owner() { "$@"; } # no user namespace to enter here
log() { :; }

# shellcheck disable=SC2034 # read by the sourced backup functions
BACKUP_BACKEND=tar
BACKUP_DIR="$work/backups"
STACKS_DIR="$work/stacks"

mkdir -p "$STACKS_DIR/app/sub"
echo one > "$STACKS_DIR/app/a.txt"
echo two > "$STACKS_DIR/app/sub/b.txt"

for TAR_COMPRESSION in zstd gzip; do
  rm -rf "$BACKUP_DIR" "$work/out"
  name="app@manual@2026-09-29T033000@abc1234"

  # Round trip, and nothing left behind but the archive.
  bk_create "$name" "$STACKS_DIR" app stack || fail "$TAR_COMPRESSION: create"
  bk_exists "$name" || fail "$TAR_COMPRESSION: archive not found after create"
  [[ "$(bk_names app)" == "$name" ]] || fail "$TAR_COMPRESSION: bk_names: $(bk_names app)"
  [[ "$(bk_series)" == app ]] || fail "$TAR_COMPRESSION: bk_series: $(bk_series)"
  mkdir "$work/out"
  bk_extract "$name" "$work/out" app noown || fail "$TAR_COMPRESSION: extract"
  diff -r "$STACKS_DIR/app" "$work/out/app" || fail "$TAR_COMPRESSION: restored files differ"
  [[ -z "$(find "$BACKUP_DIR" -name '*.partial')" ]] || fail "$TAR_COMPRESSION: .partial file left behind"
  [[ "$(stat -c %a "$BACKUP_DIR/app")" == 700 ]] || fail "$TAR_COMPRESSION: backup folder is not mode 700"

  # A failed backup leaves neither an archive nor a partial file.
  if bk_create "app@manual@2026-09-29T040000@abc1234" "$STACKS_DIR" missing stack 2> /dev/null; then
    fail "$TAR_COMPRESSION: backing up a missing path succeeded"
  fi
  [[ "$(bk_names app)" == "$name" ]] || fail "$TAR_COMPRESSION: failed backup left an archive"
  [[ -z "$(find "$BACKUP_DIR" -name '*.partial')" ]] || fail "$TAR_COMPRESSION: failed backup left a .partial file"

  bk_delete "$name"
  bk_exists "$name" && fail "$TAR_COMPRESSION: archive still there after delete"
done

# Retention: one nightly archive per day from June to the end of September 2026 (a Tuesday).
rm -rf "$BACKUP_DIR"
TAR_COMPRESSION=zstd
mkdir -p "$BACKUP_DIR/app"
day=2026-06-01
while [[ $day < 2026-09-30 ]]; do
  : > "$BACKUP_DIR/app/app@nightly@${day}T033000@abc1234.tar.zst"
  day="$(date -d "$day + 1 day" +%F)"
done
# Other kinds in the series must never be touched by the nightly prune.
: > "$BACKUP_DIR/app/app@manual@2026-06-01T100000@abc1234.tar.zst"
: > "$BACKUP_DIR/app/app@pre@2026-06-01T100000@abc1234.tar.zst"

bk_prune app nightly 3 3 3
got="$(bk_names app | grep nightly | cut -d@ -f3 | cut -dT -f1 | paste -sd' ')"
# daily: 29 28 27 Sep; weekly: ISO weeks 40 39 38 end on 29 Sep, 27 Sep, 20 Sep; monthly: 29 Sep, 31 Aug, 31 Jul.
want="2026-07-31 2026-08-31 2026-09-20 2026-09-27 2026-09-28 2026-09-29"
[[ $got == "$want" ]] || fail "nightly retention kept: $got (want: $want)"
bk_names app | grep -q '@manual@' || fail "prune removed a manual archive"
bk_names app | grep -q '@pre@' || fail "nightly prune removed a pre archive"

# Keep-last for pre archives.
for t in 01 02 03 04 05; do : > "$BACKUP_DIR/app/app@pre@2026-09-${t}T100000@abc1234.tar.zst"; done
bk_prune_last app pre 3
got="$(bk_names app | grep '@pre@' | cut -d@ -f3 | cut -dT -f1 | paste -sd' ')"
[[ $got == "2026-09-03 2026-09-04 2026-09-05" ]] || fail "keep-last kept: $got"

printf 'ok: tar backend\n'
