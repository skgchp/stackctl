# AGENTS.md

`stackctl` is a single Bash script that deploys Docker Compose stacks from a Git repo (GitHub, GitLab,
Forgejo, Gitea, ...) and backs them up to Borg or to tar files. It runs from systemd timers, as root
against **rootful** Docker or as the Docker user against **rootless** Docker. It is used on remote
machines that are only reachable over SSH, so read `README.md` and `docs/GUIDE.md` before changing
behaviour.
`stackctl` is a single Bash script that deploys Docker Compose stacks from a Git repo (GitHub, GitLab,
Forgejo, Gitea, ...) and backs them up to Borg or to tar files. It runs from systemd timers, as root
against **rootful** Docker or as the Docker user against **rootless** Docker. It is used on remote
machines that are only reachable over SSH, so read `README.md` and `docs/GUIDE.md` before changing
behaviour.

## Layout

- `stackctl`: the tool. `VERSION` is near the top.
- `install.sh`: the interactive installer and config wizard (`--upgrade` replaces only the script and units).
- `install.sh`: the interactive installer and config wizard (`--upgrade` replaces only the script and units).
- `systemd/`: the three `.service` / `.timer` pairs (update hourly, nightly 03:30, data 04:30).
- `stackctl.conf.example`: every config key. `github_known_hosts`: GitHub's pinned SSH host keys.
- `docs/GUIDE.md`: full setup and day-to-day use. `test/smoke.sh`: lint plus the config-free commands. `test/tar.sh`: the tar backend and retention (needs Linux).
- `docs/GUIDE.md`: full setup and day-to-day use. `test/smoke.sh`: lint plus the config-free commands. `test/tar.sh`: the tar backend and retention (needs Linux).
- `CHANGELOG.md`: one entry per release.

## Guarantees to keep

- A held stack is never touched.
- A stack is backed up before it is changed; if the backup fails the stack is restarted unchanged.
- Untracked files (data, `.env`) are never written or removed. Only files tracked in Git are.
- Never print or log the Borg passphrase, the ntfy token, the Git token or key material.
- Never print or log the Borg passphrase, the ntfy token, the Git token or key material.

## Compatibility
## Compatibility

Existing installs upgrade by replacing the script, so these are a public interface. Changing any of them is
**breaking**: bump the major version and say so in `CHANGELOG.md`.
Existing installs upgrade by replacing the script, so these are a public interface. Changing any of them is
**breaking**: bump the major version and say so in `CHANGELOG.md`.

- Config keys in `stackctl.conf.example`, and the fact that `STACKCTL_CONFIG` overrides the path.
- The installed path `/usr/local/bin/stackctl` (units hard-code it) and the unit and timer names
  (`stackctl test` checks `stackctl-update.timer` and `stackctl-nightly.timer`).
- State and config paths. Rootless: `~/.config/stackctl/`, `~/.local/state/stackctl/`, `~/stacks`.
  Rootful: `/etc/stackctl/`, `/var/lib/stackctl/`.
- The output of `stackctl version` (`stackctl X.Y.Z`).
- Archive names: `<series>@<kind>@<time>@<rev>`, the same for both backends.
- State and config paths. Rootless: `~/.config/stackctl/`, `~/.local/state/stackctl/`, `~/stacks`.
  Rootful: `/etc/stackctl/`, `/var/lib/stackctl/`.
- The output of `stackctl version` (`stackctl X.Y.Z`).
- Archive names: `<series>@<kind>@<time>@<rev>`, the same for both backends.

A new optional key with a default is not breaking. Add it to `load_config` and `stackctl.conf.example`
together.

## Docker modes and backups

- `MODE` (rootless or rootful) is settled before the config is read. Anything that must run as the owner of
  the stack files (reading, `rm`, `tar -x`, backups, restores) goes through `as_owner`: in rootless mode it
  runs inside rootless Docker's user namespace, where root-owned files (`/etc/ssh/...`) appear as `nobody`
  and `ssh` looks for `known_hosts` under `/root`. That is why `BORG_RSH` uses its own `-F` config and
  `UserKnownHostsFile`. Test such changes against a real SSH Borg repo, not a local one.
- All backup storage access goes through the `bk_*` functions, which dispatch on `BACKUP_BACKEND`. Do not call
  `borg` or write archives anywhere else. A tar backup is written to a `.partial` file and renamed only when
  complete.
## Docker modes and backups

- `MODE` (rootless or rootful) is settled before the config is read. Anything that must run as the owner of
  the stack files (reading, `rm`, `tar -x`, backups, restores) goes through `as_owner`: in rootless mode it
  runs inside rootless Docker's user namespace, where root-owned files (`/etc/ssh/...`) appear as `nobody`
  and `ssh` looks for `known_hosts` under `/root`. That is why `BORG_RSH` uses its own `-F` config and
  `UserKnownHostsFile`. Test such changes against a real SSH Borg repo, not a local one.
- All backup storage access goes through the `bk_*` functions, which dispatch on `BACKUP_BACKEND`. Do not call
  `borg` or write archives anywhere else. A tar backup is written to a `.partial` file and renamed only when
  complete.

## Style

Bash, 2-space indent. Comments explain *why*. The script does not source anything but its config file.
Keep it shellcheck-clean:

    shellcheck -x -P SCRIPTDIR stackctl install.sh test/*.sh
    shellcheck -x -P SCRIPTDIR stackctl install.sh test/*.sh

## Testing

`./test/smoke.sh` lints and checks `help`, `version`, config loading, the unit paths and the example config.
`./test/tar.sh` exercises the tar backend and its retention. Both need Linux (GNU `date`); on macOS run them
in a container, for example
`docker run --rm -v "$PWD":/w:ro -w /w debian:stable bash -c 'apt-get -qq update && apt-get -qq install -y zstd git shellcheck && ./test/smoke.sh && ./test/tar.sh'`.

CI (`.github/workflows/ci.yml`) runs both on every pull request, plus a Trivy scan for known vulnerabilities and
leaked secrets. Dependabot keeps the pinned action versions current.

They **cannot** prove rootful or rootless Docker, Borg over SSH, `nsenter`, lingering, the Git hosts or the
timers. Say so when you rely on them. Those are proven with `stackctl test` on a scratch server, and by a
real update, restore and `extract` round trip, for each mode and backend you touched.
`./test/smoke.sh` lints and checks `help`, `version`, config loading, the unit paths and the example config.
`./test/tar.sh` exercises the tar backend and its retention. Both need Linux (GNU `date`); on macOS run them
in a container, for example
`docker run --rm -v "$PWD":/w:ro -w /w debian:stable bash -c 'apt-get -qq update && apt-get -qq install -y zstd git shellcheck && ./test/smoke.sh && ./test/tar.sh'`.

CI (`.github/workflows/ci.yml`) runs both on every pull request, plus a Trivy scan for known vulnerabilities and
leaked secrets. Dependabot keeps the pinned action versions current.

They **cannot** prove rootful or rootless Docker, Borg over SSH, `nsenter`, lingering, the Git hosts or the
timers. Say so when you rely on them. Those are proven with `stackctl test` on a scratch server, and by a
real update, restore and `extract` round trip, for each mode and backend you touched.

## Releasing

1. Bump `VERSION`, update `CHANGELOG.md`, run `./test/smoke.sh` and `./test/tar.sh`.
2. Merge to `main`. CI then creates the `vX.Y.Z` tag and GitHub release from `VERSION`, using the matching
   `CHANGELOG.md` entry as the notes. It fails if that entry is missing. Users install from a checkout of the tag.

## Git

Work on a feature branch (`main` is the default). Don't commit a real `stackctl.conf`.
