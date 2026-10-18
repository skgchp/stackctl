# Changelog

Breaking changes to the config keys, unit names, paths or `stackctl version` output bump the major
version (see AGENTS.md).

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
