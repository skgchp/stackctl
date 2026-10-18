# stackctl

stackctl deploys Docker Compose stacks from a Git repository and backs them up. It is one Bash script that
runs from systemd timers on a single server, with either rootful or rootless Docker.

Every hour it checks your repository. When a stack's folder has changed, it backs the stack up, writes the
new files and restarts it. Every night it backs up all your stacks.

## Features

- Works with GitHub, GitLab, Forgejo, Gitea and other Git servers, over SSH or HTTPS.
- Backs up to [Borg](https://www.borgbackup.org), or to plain `.tar.zst` files in a folder if you do not use Borg.
- Sends [ntfy](https://ntfy.sh) notifications when something updates or fails. This is optional.
- Backs up folders outside your stacks, such as a mounted volume, as separate series.

## Guarantees

- A stack on hold is never touched. A stack that fails to update goes on hold, so it is not retried every
  hour and cannot push good backups out of retention.
- A stack is backed up before it is changed. If the backup fails, the stack is restarted unchanged.
- Files that are not tracked in Git, such as data and `.env` files, are never written or removed.

## Requirements

| Needed | When |
|---|---|
| Linux with systemd, Docker Engine and the `docker compose` plugin | Always |
| `git`, `ssh`, `flock`, `tar` | Always |
| A read-only deploy key or access token for your stacks repository | Always |
| Lingering for the user (an administrator runs `loginctl enable-linger <user>`) | Normal user |
| `nsenter` (util-linux) | Rootless Docker |
| Permission to pull the helper image (`debian:stable-slim`) | Rootful Docker, normal user |
| `borg` 1.2 or newer (1.x), and a Borg repository | Borg backups |
| `zstd` (or `gzip` as a fallback) | Tar backups |
| `curl` | ntfy notifications |

## Install

Run the installer from a checkout of a release tag, as the account that will run stackctl: a service account
that can use Docker (rootless Docker, or a member of the `docker` group), or root.

```bash
git clone --branch vX.Y.Z <url-of-this-repo>
cd stackctl
./install.sh
```

The installer detects your Docker mode and asks you questions about your repository, your backup target and
whether you want ntfy. It then:

1. offers to install missing packages (Debian and Ubuntu only);
2. installs the script and the systemd units;
3. creates a deploy key and records the server's host key once you have checked its fingerprint;
4. writes the config file;
5. creates the backup target and offers to enable the timers;
6. runs `stackctl test`.

After pulling a new release, run `./install.sh --upgrade` to replace only the script and the units.
The [guide](docs/GUIDE.md) explains each step and how to do the install by hand.

### Which account, and which Docker

Where stackctl keeps things depends on the account that runs it. A normal user, such as a service account,
needs no root folders.

| | Normal user | Root |
|---|---|---|
| Config | `~/.config/stackctl/stackctl.conf` | `/etc/stackctl/stackctl.conf` |
| State | `~/.local/state/stackctl/` | `/var/lib/stackctl/` |
| Systemd units | `~/.config/systemd/user/`, with `systemctl --user` | `/etc/systemd/system/` |
| Extra needs | lingering, so the timers run while logged out | none |

Whether Docker is rootless or rootful only changes how stackctl reaches files that containers created as other
users, such as database data. stackctl detects it: a user with their own Docker socket is rootless, anything
else is rootful. Set `DOCKER_MODE` to force one.

| Docker | Run as | Container-owned files are reached |
|---|---|---|
| Rootless | the Docker user | through Docker's user namespace (`nsenter`) |
| Rootful | a user in the `docker` group | through a short-lived root container (`HELPER_IMAGE`), with no sudo |
| Rootful | root | directly |

The script is installed at `/usr/local/bin/stackctl`, owned by root, so the user whose timers run it cannot
change it. Without sudo, the installer offers `~/.local/bin/stackctl` instead.

## Commands

| Command | What it does |
|---|---|
| `test [--no-notify]` | Checks the tools, Docker, timers, Git access and backup target, runs a backup and restore round trip, then shows a dry run of the next update |
| `status` | Shows each stack's deployed revision, running containers and state |
| `update [--dry-run]` | Deploys changed stacks (the hourly timer runs this) |
| `list <stack>` | Lists a stack's backups |
| `restore <stack> [archive] [--yes]` | Restores a backup, sets the current folder aside and puts the stack on hold |
| `extract <stack> <archive> <dir>` | Copies a backup into `<dir>` so you can browse it, leaving the running stack alone |
| `backup <stack>... [--stop]` | Takes a manual backup, which is kept until you delete it |
| `nightly` | Backs up every stack and deletes old backups (the nightly timer runs this) |
| `data` | Backs up each folder in `DATA_DIRS`, then deletes old backups (04:30 timer) |
| `hold <stack> [reason]` | Stops automatic updates for a stack |
| `release <stack>` | Resumes automatic updates for a stack |
| `init` | Creates the backup target: the Borg repository, or the tar folder |
| `adopt` | Marks running stacks that match the repository as deployed, without restarting them |
| `clean` | Deletes folders set aside by earlier restores |
| `version`, `help` | Print the version, or the command list |

## Things to know

- Backups are named `<stack>@<kind>@<time>@<revision>`. The kind is `pre` (before an update), `nightly`,
  `manual` or `data`. The `KEEP_*` settings apply to `nightly` and `pre` backups. Manual backups are never
  deleted automatically.
- Only the stack folder is backed up. Named Docker volumes are not, so use bind mounts for data you need.
- Tar backups are not encrypted and are stored on the same machine unless `BACKUP_DIR` is a separate disk
  or mount. Copy them off the server. Borg encrypts and deduplicates.
- Each stack folder needs a `compose.yaml`, `compose.yml`, `docker-compose.yaml` or `docker-compose.yml`.
- stackctl keeps a bare copy of your repository in its state folder. It does not use a working copy.

## Configuration

stackctl reads the config path shown in the table above, or the path in `$STACKCTL_CONFIG`.
[stackctl.conf.example](stackctl.conf.example) documents every key.

## Development

```bash
./test/smoke.sh   # lint, help, version, config loading, unit files
./test/tar.sh     # tar backups and retention (Linux, GNU date)
```

These cannot prove rootless or rootful Docker, Borg over SSH or the timers. Read [AGENTS.md](AGENTS.md)
before changing behaviour.

## Versioning

`stackctl version` prints `stackctl X.Y.Z`. Releases are Git tags (`vX.Y.Z`), listed in
[CHANGELOG.md](CHANGELOG.md).
