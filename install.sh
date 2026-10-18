#!/usr/bin/env bash
#
# install.sh: interactive installer for stackctl.
#
# Run it from a checkout of a release tag, as root for rootful Docker or as the
# Docker user for rootless Docker. It installs the script and the systemd units,
# asks how you want to deploy and back up, writes the config, and runs the
# first-time setup and self-test. It does not install Docker.
#
# Re-running is safe: an existing config is kept unless you choose to redo it.

set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BIN=/usr/local/bin/stackctl
UPGRADE=false
MODE=""

say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat << 'EOT'
Usage: ./install.sh [--upgrade] [--mode rootless|rootful]

Installs stackctl and walks you through setting it up.

  --upgrade   Only replace the script and the systemd units. Leaves your
              config, keys and timers alone.
  --mode M    Force rootless (run as the Docker user) or rootful (run as
              root). By default: rootful when run as root, else rootless.
  --help      Show this help.
EOT
}

while (( $# > 0 )); do
  case $1 in
    --upgrade) UPGRADE=true ;;
    --mode)
      shift
      MODE=${1:-}
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

# The config file is sourced by bash, so these characters would break it.
has_bad_chars() {
  case $1 in
    *'"'* | *'$'* | *'`'* | *\\*) return 0 ;;
  esac
  return 1
}

# ask VAR "Question" [default]
ask() {
  local reply
  while true; do
    read -r -p "$2${3:+ [$3]}: " reply
    reply=${reply:-${3:-}}
    if has_bad_chars "$reply"; then
      warn 'Values cannot contain  "  $  `  or a backslash.'
      continue
    fi
    printf -v "$1" '%s' "$reply"
    return 0
  done
}

# ask_required VAR "Question" [default]
ask_required() {
  while true; do
    ask "$1" "$2" "${3:-}"
    [[ -n ${!1} ]] && return 0
    warn "This one is required."
  done
}

# ask_secret VAR "Question": not echoed, never printed back.
ask_secret() {
  local reply
  while true; do
    read -r -s -p "$2: " reply
    echo
    if has_bad_chars "$reply"; then
      warn 'Values cannot contain  "  $  `  or a backslash.'
      continue
    fi
    printf -v "$1" '%s' "$reply"
    return 0
  done
}

# ask_yn "Question" y|n
ask_yn() {
  local reply
  read -r -p "$1 [$(if [[ $2 == y ]]; then echo Y/n; else echo y/N; fi)]: " reply
  reply=${reply:-$2}
  [[ $reply == [yY]* ]]
}

pause() { read -r -p "Press Enter when done... " _; }

# ---------------------------------------------------------------------------
# Mode and paths
# ---------------------------------------------------------------------------

detect_mode() {
  if [[ -z $MODE ]]; then
    if (( EUID == 0 )); then MODE=rootful; else MODE=rootless; fi
  fi
  case $MODE in
    rootful) (( EUID == 0 )) || die "rootful mode needs root: run  sudo ./install.sh" ;;
    rootless) (( EUID != 0 )) || die "rootless mode must run as the Docker user, not root" ;;
    *) die "--mode must be rootless or rootful" ;;
  esac

  SUDO=""
  if (( EUID != 0 )); then
    command -v sudo > /dev/null || die "sudo is needed to install $BIN"
    SUDO=sudo
  fi

  if [[ $MODE == rootful ]]; then
    CONF_DIR=/etc/stackctl
    UNIT_DIR=/etc/systemd/system
    KEY_DIR=/root/.ssh
    DEFAULT_STACKS=/srv/stacks
    DEFAULT_BACKUPS=/var/backups/stackctl
  else
    CONF_DIR="$HOME/.config/stackctl"
    UNIT_DIR="$HOME/.config/systemd/user"
    KEY_DIR="$HOME/.ssh"
    DEFAULT_STACKS="$HOME/stacks"
    DEFAULT_BACKUPS="$HOME/backups/stackctl"
    export DOCKER_HOST="${DOCKER_HOST:-unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock}"
  fi
  CONF="${STACKCTL_CONFIG:-$CONF_DIR/stackctl.conf}"
}

sctl() { if [[ $MODE == rootful ]]; then systemctl "$@"; else systemctl --user "$@"; fi; }

# Value of a key in the existing config, read in a subshell so nothing leaks.
# shellcheck disable=SC1090
read_cfg() { (set +u; source "$CONF" > /dev/null 2>&1; printf '%s' "${!1:-}"); }

# ---------------------------------------------------------------------------
# Checks and packages
# ---------------------------------------------------------------------------

apt_package() {
  case $1 in
    flock | nsenter) echo util-linux ;;
    borg) echo borgbackup ;;
    *) echo "$1" ;;
  esac
}

is_debian_like() {
  [[ -r /etc/os-release ]] || return 1
  # shellcheck source=/dev/null
  (source /etc/os-release && [[ "${ID:-} ${ID_LIKE:-}" =~ (debian|ubuntu) ]])
}

ensure_tools() { # command...
  local t
  local -a missing=() pkgs=()
  for t in "$@"; do
    command -v "$t" > /dev/null || missing+=("$t")
  done
  (( ${#missing[@]} > 0 )) || return 0

  for t in "${missing[@]}"; do pkgs+=("$(apt_package "$t")"); done
  say "Missing tools: ${missing[*]}"
  if is_debian_like; then
    if ask_yn "Install ${pkgs[*]} with apt-get?" y; then
      $SUDO apt-get update
      $SUDO apt-get install -y "${pkgs[@]}"
      for t in "${missing[@]}"; do
        command -v "$t" > /dev/null || die "$t is still missing after installing"
      done
      return 0
    fi
  fi
  die "install these first, then run ./install.sh again: ${pkgs[*]}"
}

check_docker() {
  command -v docker > /dev/null || die "Docker is not installed. Install Docker Engine first (https://docs.docker.com/engine/install/), or rootless Docker (https://docs.docker.com/engine/security/rootless/)."
  docker compose version > /dev/null 2>&1 || die "The Docker Compose plugin is missing (https://docs.docker.com/compose/install/linux/)."
  local opts
  opts="$(docker info --format '{{.SecurityOptions}}' 2> /dev/null)" \
    || die "Cannot reach the Docker daemon as $(id -un) in $MODE mode."
  if [[ $MODE == rootless && $opts != *rootless* ]]; then
    die "This Docker daemon is not rootless. For a normal Docker install, run as root: sudo ./install.sh"
  fi
  if [[ $MODE == rootful && $opts == *rootless* ]]; then
    die "This Docker daemon is rootless. Run ./install.sh as the Docker user instead of root."
  fi
  say "Docker ($MODE) and the Compose plugin are working."
}

# ---------------------------------------------------------------------------
# Install files
# ---------------------------------------------------------------------------

install_files() {
  say "Installing $BIN"
  $SUDO install -m 0755 -o root -g root "$HERE/stackctl" "$BIN"
  mkdir -p "$UNIT_DIR"
  install -m 0644 "$HERE"/systemd/* "$UNIT_DIR/"
  sctl daemon-reload
  say "Installed the systemd units into $UNIT_DIR"

  if [[ $MODE == rootless ]]; then
    if [[ "$(loginctl show-user "$(id -un)" -p Linger --value 2> /dev/null)" != yes ]]; then
      say "Lingering keeps your Docker and the timers running when you are logged out."
      if ask_yn "Enable lingering for $(id -un) (needs sudo)?" y; then
        $SUDO loginctl enable-linger "$(id -un)"
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# Config wizard
# ---------------------------------------------------------------------------

# parse_remote URL: sets R_KIND (ssh|https), R_HOST, R_PORT
parse_remote() {
  local rest
  R_HOST="" R_PORT=22
  case $1 in
    http://* | https://*) R_KIND=https ;;
    ssh://*)
      R_KIND=ssh
      rest=${1#ssh://}
      rest=${rest#*@}
      rest=${rest%%/*}
      R_HOST=${rest%%:*}
      if [[ $rest == *:* ]]; then R_PORT=${rest##*:}; fi
      ;;
    *@*:*)
      R_KIND=ssh
      rest=${1#*@}
      R_HOST=${rest%%:*}
      ;;
    *) die "Cannot tell whether '$1' is an SSH or HTTPS remote. Use git@host:owner/repo.git, ssh://git@host:port/owner/repo.git or https://host/owner/repo.git" ;;
  esac
}

make_key() { # path comment
  if [[ -f $1 ]]; then
    say "Using the existing key $1"
  else
    mkdir -p "$(dirname "$1")"
    chmod 700 "$(dirname "$1")"
    ssh-keygen -q -t ed25519 -N '' -C "$2" -f "$1"
    say "Created $1"
  fi
}

# pin_host_key HOST PORT FILE: record the server's host keys after you confirm the fingerprints.
pin_host_key() {
  local keys tmp
  if [[ $1 == github.com ]]; then
    install -m 0644 "$HERE/github_known_hosts" "$3"
    say "Using GitHub's published host keys."
    return 0
  fi
  # Comment lines (the server banner) are dropped, so only real keys count.
  keys="$(ssh-keyscan -T 10 -p "$2" "$1" 2> /dev/null | grep -v '^#' || true)"
  if [[ -z $keys ]]; then
    die "ssh-keyscan found no host keys at $1:$2. Check the host and port, that this machine can reach it, and run: ssh-keyscan -p $2 $1"
  fi
  # ssh-keygen needs a real file here, not a pipe.
  tmp="$(mktemp)"
  printf '%s\n' "$keys" > "$tmp"
  say "Host keys offered by $1:$2:"
  if ! ssh-keygen -lf "$tmp" | sed 's/^/  /'; then
    rm -f "$tmp"
    die "Could not read the host keys that $1:$2 returned. Run: ssh-keyscan -p $2 $1"
  fi
  rm -f "$tmp"
  say "Compare these with the server's own list (the Git server's admin page, or your provider's published fingerprints)."
  ask_yn "Do they match?" n || die "Host key not confirmed, nothing was trusted."
  (umask 022 && printf '%s\n' "$keys" > "$3")
}

configure_git() {
  ask_required GIT_REMOTE "Git repo with your stacks (SSH or HTTPS URL)"
  ask BRANCH "Branch to deploy" main
  parse_remote "$GIT_REMOTE"

  GIT_SSH_KEY="" GIT_KNOWN_HOSTS="" GIT_TOKEN_FILE="" GIT_USERNAME=oauth2
  if [[ $R_KIND == ssh ]]; then
    GIT_SSH_KEY="$KEY_DIR/git-deploy"
    GIT_KNOWN_HOSTS="$CONF_DIR/known_hosts-git"
    make_key "$GIT_SSH_KEY" "stackctl@$(hostname -s)"
    pin_host_key "$R_HOST" "$R_PORT" "$GIT_KNOWN_HOSTS"
    cat << EOT

Add this public key to the repo as a READ-ONLY deploy key:
  GitHub:        repo Settings > Deploy keys > Add deploy key (leave "Allow write access" off)
  GitLab:        project Settings > Repository > Deploy keys (read-only)
  Forgejo/Gitea: repo Settings > Deploy Keys > Add Deploy Key (leave "Enable Write Access" off)

EOT
    cat "$GIT_SSH_KEY.pub"
    echo
    pause
  else
    cat << 'EOT'

HTTPS needs a read-only access token for the repo:
  GitHub:        a fine-grained token with "Contents: read-only" on this repo
  GitLab:        a project access token (read_repository) or deploy token
  Forgejo/Gitea: an application token with read:repository
EOT
    ask GIT_USERNAME "Username to send with the token (oauth2 for access tokens; a GitLab deploy token has its own)" oauth2
    local token
    ask_secret token "Paste the token (not shown)"
    [[ -n $token ]] || die "No token given."
    GIT_TOKEN_FILE="$CONF_DIR/git-token"
    (umask 077 && printf '%s\n' "$token" > "$GIT_TOKEN_FILE")
    token=""
  fi
}

# The same Git settings stackctl uses, to try the repo before going further.
git_check() {
  local -a args=()
  if [[ $R_KIND == ssh ]]; then
    export GIT_SSH_COMMAND="ssh -o BatchMode=yes -i $GIT_SSH_KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=$GIT_KNOWN_HOSTS -o StrictHostKeyChecking=yes"
  else
    args=(-c credential.helper=
      -c "credential.helper=!f() { echo username=$GIT_USERNAME; printf 'password=%s\\n' \"\$(cat $GIT_TOKEN_FILE)\"; }; f")
    export GIT_TERMINAL_PROMPT=0
  fi
  git ${args[@]+"${args[@]}"} ls-remote --exit-code --heads "$GIT_REMOTE" "$BRANCH" > /dev/null
}

configure_borg() {
  BORG_RSH="" BORG_REMOTE_PATH=""
  ask_required BORG_REPO "Borg repo (for example ssh://user@host:23/./backups/myhost, or a local path)"
  BORG_PASSFILE="$CONF_DIR/borg-passphrase"
  if [[ ! -f $BORG_PASSFILE ]]; then
    (umask 077 && head -c 32 /dev/urandom | base64 > "$BORG_PASSFILE")
    say "Generated a Borg passphrase in $BORG_PASSFILE (save a copy off this server)."
  fi

  if [[ $BORG_REPO == ssh://* ]]; then
    parse_remote "$BORG_REPO"
    local key="$KEY_DIR/borg" known="$CONF_DIR/known_hosts-borg" rsh="ssh"
    make_key "$key" "stackctl-borg@$(hostname -s)"
    pin_host_key "$R_HOST" "$R_PORT" "$known"
    # Rootless: Borg runs inside Docker's user namespace, where /etc/ssh is owned by "nobody" and ssh
    # looks for known_hosts under /root, so give it its own config file and known_hosts.
    if [[ $MODE == rootless ]]; then
      printf '# Keeps ssh from reading /etc/ssh inside Docker'"'"'s user namespace (see stackctl.conf.example)\n' > "$CONF_DIR/ssh_config"
      rsh+=" -F $CONF_DIR/ssh_config"
    fi
    BORG_RSH="$rsh -i $key -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=$known -o StrictHostKeyChecking=yes"
    cat << EOT

Install this public key on the Borg host (for a Hetzner Storage Box sub-account:
ssh-copy-id -p 23 -s -i $key.pub USER@HOST), and make sure the parent folder of the repo exists:

EOT
    cat "$key.pub"
    echo
    pause
    ask BORG_REMOTE_PATH "Remote borg binary, if not 'borg' (for example borg-1.4 on a Storage Box; Enter for none)" ""
  fi
}

configure_backups() {
  BORG_REPO="" BORG_RSH="" BORG_REMOTE_PATH="" BACKUP_DIR="" BORG_PASSFILE=""
  TAR_COMPRESSION=zstd
  if [[ $BACKEND == borg ]]; then
    configure_borg
  else
    ask_required BACKUP_DIR "Folder for tar backups (absolute path)" "$DEFAULT_BACKUPS"
    [[ $BACKUP_DIR == /* ]] || die "BACKUP_DIR must be an absolute path"
    if ! command -v zstd > /dev/null; then TAR_COMPRESSION=gzip; fi
  fi
}

configure_rest() {
  DATA_DIRS=""
  KEEP_DAILY=3 KEEP_WEEKLY=3 KEEP_MONTHLY=3 KEEP_PRE=3
  KEEP_DATA_DAILY=7 KEEP_DATA_WEEKLY=4 KEEP_DATA_MONTHLY=3
  NTFY_URL="" NTFY_TOKEN="" NOTIFY_SUCCESS=true NOTIFY_NIGHTLY_SUCCESS=false

  ask DATA_DIRS "Extra folders outside the stacks to back up (absolute paths, space-separated; Enter for none)" ""
  if ask_yn "Change how many backups are kept? (defaults: nightly 3 daily/3 weekly/3 monthly, 3 pre-update)" n; then
    ask KEEP_DAILY "Nightly: daily backups to keep" "$KEEP_DAILY"
    ask KEEP_WEEKLY "Nightly: weekly backups to keep" "$KEEP_WEEKLY"
    ask KEEP_MONTHLY "Nightly: monthly backups to keep" "$KEEP_MONTHLY"
    ask KEEP_PRE "Pre-update backups to keep" "$KEEP_PRE"
  fi

  if (( WANT_NTFY )); then
    ask_required NTFY_URL "ntfy URL including the topic (https://ntfy.example.com/my-topic)"
    ask_secret NTFY_TOKEN "ntfy access token (not shown; Enter for none)"
    if ! ask_yn "Notify after each successful update?" y; then NOTIFY_SUCCESS=false; fi
    if ask_yn "Notify after each successful nightly backup?" n; then NOTIFY_NIGHTLY_SUCCESS=true; fi
  fi
}

write_config() {
  local tmp
  mkdir -p "$CONF_DIR"
  chmod 700 "$CONF_DIR"
  if [[ -f $CONF ]]; then
    cp -p "$CONF" "$CONF.bak.$(date +%Y%m%d%H%M%S)"
    say "The previous config was saved as $CONF.bak.*"
  fi
  tmp="$(umask 077 && mktemp "$CONF_DIR/.stackctl.conf.XXXXXX")"
  {
    cat << EOT
# stackctl configuration, written by install.sh on $(date '+%F %T').
# Every key is documented in stackctl.conf.example. The file is sourced by bash.
DOCKER_MODE="$MODE"
STACKS_DIR="$STACKS_DIR"

GIT_REMOTE="$GIT_REMOTE"
BRANCH="$BRANCH"
GIT_SSH_KEY="$GIT_SSH_KEY"
GIT_KNOWN_HOSTS="$GIT_KNOWN_HOSTS"
GIT_TOKEN_FILE="$GIT_TOKEN_FILE"
GIT_USERNAME="$GIT_USERNAME"

BACKUP_BACKEND="$BACKEND"
EOT
    if [[ $BACKEND == borg ]]; then
      cat << EOT
BORG_REPO="$BORG_REPO"
BORG_PASSCOMMAND="cat $BORG_PASSFILE"
BORG_RSH="$BORG_RSH"
BORG_REMOTE_PATH="$BORG_REMOTE_PATH"
EOT
    else
      cat << EOT
BACKUP_DIR="$BACKUP_DIR"
TAR_COMPRESSION="$TAR_COMPRESSION"
EOT
    fi
    cat << EOT

KEEP_DAILY=$KEEP_DAILY
KEEP_WEEKLY=$KEEP_WEEKLY
KEEP_MONTHLY=$KEEP_MONTHLY
KEEP_PRE=$KEEP_PRE

DATA_DIRS="$DATA_DIRS"
KEEP_DATA_DAILY=$KEEP_DATA_DAILY
KEEP_DATA_WEEKLY=$KEEP_DATA_WEEKLY
KEEP_DATA_MONTHLY=$KEEP_DATA_MONTHLY

NTFY_URL="$NTFY_URL"
NTFY_TOKEN="$NTFY_TOKEN"
NOTIFY_SUCCESS=$NOTIFY_SUCCESS
NOTIFY_NIGHTLY_SUCCESS=$NOTIFY_NIGHTLY_SUCCESS
EOT
  } > "$tmp"
  chmod 600 "$tmp"
  mv -- "$tmp" "$CONF"
  say "Wrote $CONF (mode 600)"
}

configure() {
  # The keys, token and passphrase below are written into this folder before the config file is.
  mkdir -p "$CONF_DIR"
  chmod 700 "$CONF_DIR"
  ask_required STACKS_DIR "Folder for your stacks" "$DEFAULT_STACKS"
  mkdir -p "$STACKS_DIR"
  configure_git
  while ! git_check; do
    warn "Could not read $GIT_REMOTE (branch $BRANCH) with those credentials."
    ask_yn "Try again? (No continues anyway; fix it before enabling the timers)" y || break
  done
  configure_backups
  configure_rest
  write_config
}

# ---------------------------------------------------------------------------
# Finish
# ---------------------------------------------------------------------------

has_stacks() {
  local d
  for d in "$1"/*/; do
    [[ -d $d ]] || continue
    ls "$d"compose.y*ml "$d"docker-compose.y*ml > /dev/null 2>&1 && return 0
  done
  return 1
}

finish() {
  local stacks data
  stacks="$(read_cfg STACKS_DIR)"
  data="$(read_cfg DATA_DIRS)"

  say
  say "First-time setup (creates the backup target):"
  "$BIN" init

  if [[ -d $stacks ]] && has_stacks "$stacks"; then
    say
    say "Stacks already exist in $stacks. 'adopt' marks the ones that match the repo as deployed,"
    say "so the first update does not restart them."
    if ask_yn "Run stackctl adopt?" y; then "$BIN" adopt; fi
  fi

  say
  if ask_yn "Enable the hourly update and nightly backup timers now?" y; then
    sctl enable --now stackctl-update.timer stackctl-nightly.timer
    if [[ -n $data ]]; then sctl enable --now stackctl-data.timer; fi
  else
    say "Enable them later with:"
    say "  $(if [[ $MODE == rootful ]]; then echo systemctl; else echo systemctl --user; fi) enable --now stackctl-update.timer stackctl-nightly.timer"
  fi

  say
  say "Running the self-test (timer checks fail if you did not enable them):"
  "$BIN" test || warn "Some checks failed. Fix them and run: stackctl test"

  cat << EOT

stackctl is installed ($MODE Docker).
  Config:   $CONF
  Commands: stackctl status | update | test | list <stack> | restore <stack>
  Guide:    $HERE/docs/GUIDE.md
EOT
  if [[ $BACKEND == borg ]]; then
    say "  Save the Borg key export and passphrase somewhere safe off this server (see the init output above)."
  fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  detect_mode

  if $UPGRADE; then
    install_files
    say "Upgraded. Your config and timers were not touched. Check CHANGELOG.md for changes that need action."
    return 0
  fi

  [[ -t 0 ]] || die "install.sh is interactive; run it from a terminal (use --upgrade for a non-interactive upgrade)."
  say "stackctl installer ($MODE Docker)"
  say
  check_docker
  ensure_tools git ssh ssh-keygen ssh-keyscan flock tar cmp

  KEEP_CONFIG=false
  if [[ -f $CONF ]]; then
    say "A config already exists: $CONF"
    if ask_yn "Keep it?" y; then KEEP_CONFIG=true; fi
  fi

  if $KEEP_CONFIG; then
    BACKEND="$(read_cfg BACKUP_BACKEND)"
    if [[ -z $BACKEND || $BACKEND == auto ]]; then
      if [[ -n "$(read_cfg BORG_REPO)" ]]; then BACKEND=borg; else BACKEND=tar; fi
    fi
    WANT_NTFY=0
    if [[ -n "$(read_cfg NTFY_URL)" ]]; then WANT_NTFY=1; fi
  else
    say "Where should backups go?"
    say "  1) Borg  (deduplicated, encrypted, usually a remote repo such as a Storage Box)"
    say "  2) tar   (plain compressed tar files in a folder)"
    local choice
    read -r -p "Choose [1]: " choice
    if [[ ${choice:-1} == 2 ]]; then BACKEND=tar; else BACKEND=borg; fi
    WANT_NTFY=0
    if ask_yn "Send notifications through ntfy?" n; then WANT_NTFY=1; fi
  fi

  local -a tools=()
  if [[ $MODE == rootless ]]; then tools+=(nsenter); fi
  if [[ $BACKEND == borg ]]; then tools+=(borg); else tools+=(zstd); fi
  if (( WANT_NTFY )); then tools+=(curl); fi
  ensure_tools "${tools[@]}"

  install_files
  if ! $KEEP_CONFIG; then configure; fi
  finish
}

main
