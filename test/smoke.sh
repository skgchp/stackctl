#!/usr/bin/env bash
# Smoke test: lint, then the commands that need no config, Docker or Borg.
# The real behaviour (rootless Docker, Borg over SSH, timers) is proven on a scratch server: see AGENTS.md.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if command -v shellcheck >/dev/null; then
  shellcheck -x -P SCRIPTDIR stackctl install.sh test/*.sh
else
  printf 'skip: shellcheck not installed\n'
fi

./stackctl help | grep -q 'Everyday commands' || fail "help prints nothing useful"
version=$(./stackctl version)
[[ $version =~ ^stackctl\ [0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "unexpected version output: $version"

# Units must point at the installed path, never the checkout.
for unit in systemd/*.service; do
  grep -q '^ExecStart=/usr/local/bin/stackctl ' "$unit" || fail "$unit does not use /usr/local/bin/stackctl"
done

# The example config must define the keys that are always required.
for key in STACKS_DIR GIT_REMOTE; do
  grep -q "^${key}=" stackctl.conf.example || fail "stackctl.conf.example is missing ${key}"
done

# Config loading: one backup target is required, and either works.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mode=rootless
if (( EUID == 0 )); then mode=rootful; fi
export DOCKER_MODE="$mode" STACKCTL_STATE_DIR="$tmp/state" XDG_STATE_HOME="$tmp/state" XDG_RUNTIME_DIR="$tmp/run"
mkdir -p "$tmp/run"
printf 'STACKS_DIR="%s/stacks"\nGIT_REMOTE="x"\n' "$tmp" > "$tmp/none.conf"
if STACKCTL_CONFIG="$tmp/none.conf" ./stackctl list app 2> "$tmp/err"; then fail "config without a backup target loaded"; fi
grep -q 'no backup target' "$tmp/err" || fail "missing backup target gives the wrong error: $(cat "$tmp/err")"
printf 'BACKUP_DIR="%s/backups"\n' "$tmp" >> "$tmp/none.conf"
STACKCTL_CONFIG="$tmp/none.conf" ./stackctl list app > /dev/null 2>&1 || fail "config with BACKUP_DIR did not load"

./install.sh --help | grep -q 'Usage' || fail "install.sh --help prints nothing useful"

printf 'ok: %s\n' "$version"
