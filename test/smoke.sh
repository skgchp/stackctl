#!/usr/bin/env bash
# Smoke test: lint, then the commands that need no config, Docker or Borg.
# The real behaviour (rootless Docker, Borg over SSH, timers) is proven on a scratch server: see AGENTS.md.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if command -v shellcheck >/dev/null; then
  shellcheck -x -P SCRIPTDIR stackctl test/*.sh
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

# The example config must define every key the script requires.
for key in STACKS_DIR GIT_REMOTE BORG_REPO BORG_PASSCOMMAND; do
  grep -q "^${key}=" stackctl.conf.example || fail "stackctl.conf.example is missing ${key}"
done

printf 'ok: %s\n' "$version"
