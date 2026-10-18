# Changelog

Breaking changes to the config keys, unit names, paths or `stackctl version` output bump the major
version (see AGENTS.md).

## 2.1.0

stackctl now runs as a normal service account against rootful Docker, with no sudo. **Existing installs keep
working with their current config and paths.**

Added:
- Rootful Docker as a normal user in the `docker` group. Config, state and systemd user timers stay in the
  account's home folder. Files owned by container users (root, database uids) are read and restored by a
  short-lived root helper container instead of `nsenter`. `HELPER_IMAGE` (default `debian:stable-slim`)
  sets its image. With Borg, the files reach Borg through `borg import-tar` and `borg export-tar`.
- `install.sh` offers `~/.local/bin/stackctl` when there is no sudo to write `/usr/local/bin`.

Changed:
- Paths and timers follow the user running stackctl (a normal user: home folder and user timers; root: `/etc`,
  `/var/lib` and system timers). `DOCKER_MODE` now only says how Docker runs, so rootful no longer means root.
- `DOCKER_MODE=auto` picks rootless when a normal user has its own Docker socket, otherwise rootful.
- `install.sh --mode` is now `--docker-mode`.
- `stackctl test` checks lingering for every normal user, and checks the helper container when it is used.

## 2.0.0

stackctl is now a standalone project with its own installer. **Existing rootless + Borg installs keep
working with their current config**: upgrade by running `./install.sh --upgrade` (or replacing
`/usr/local/bin/stackctl` and the unit files). The major bump marks the end of the debian-server-scripts
contract (its stage 85 no longer drives releases) and the new modes below.

Added:
- `install.sh`: interactive installer and config wizard (`--upgrade` to only replace the script and units).
- Rootful Docker support. Run as root; config in `/etc/stackctl/stackctl.conf`, state in `/var/lib/stackctl`,
  system units in `/etc/systemd/system`. `DOCKER_MODE=auto|rootless|rootful` (default `auto`: root means rootful).
- Tar backups as an alternative to Borg: set `BACKUP_DIR` (and optionally `TAR_COMPRESSION=zstd|gzip`) instead of
  `BORG_REPO`. `BACKUP_BACKEND=auto|borg|tar` picks explicitly. One of the two is required.
- Any Git server: `GIT_SSH_KEY` (replaces `GITHUB_SSH_KEY`, which still works), `GIT_KNOWN_HOSTS`, and HTTPS remotes with
  `GIT_TOKEN_FILE` and `GIT_USERNAME` for GitLab, Forgejo and Gitea.
- `stackctl test` prints `[SKIP]` for what is not configured (ntfy) and checks the Docker mode.
- `test/tar.sh`.

Changed:
- Notifications say "Cannot reach Git server" / "Git server reachable again" instead of naming GitHub.
- `BORG_REPO` and `BORG_PASSCOMMAND` are only required when Borg is the backend; ntfy is optional.

## 1.0.0

First release as a standalone project. The script, units and pinned GitHub host keys are unchanged
from the copy that lived in debian-server-scripts (`files/stackctl/`).
