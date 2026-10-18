# stackctl

Pull-based deploys with backups for Docker Compose stacks, on a single server running **rootful or
rootless Docker**. One Bash script, run from systemd timers.

- Deploys the stacks in a Git repo (one top-level folder per stack, each with a `compose.yaml`).
  Works with GitHub, GitLab, Forgejo, Gitea and any other Git server, over SSH or HTTPS.
- Takes a backup of a stack **before** it changes it, and a nightly backup of every stack. Backups go to
  [Borg](https://www.borgbackup.org) or, if you don't use Borg, to plain `.tar.zst` files in a folder.
- Optionally notifies through [ntfy](https://ntfy.sh) when something is updated or goes wrong.
- Can back up folders outside the stacks (for example a mounted volume) as separate archive series.

## Guarantees

- **A held stack is never touched.** A failed or tampered stack goes on hold instead of retrying
  hourly, so a bad update cannot push good backups out of retention.
- **A stack is backed up before it is changed.** If that backup fails, the stack is restarted unchanged.
- **Untracked files are never written or removed.** Data and `.env` files stay where they are, because
  only files tracked in Git are written.

## Install

On a Linux server with Docker and the Compose plugin already installed, from a checkout of a release tag:

```bash
git clone --branch vX.Y.Z <url-of-this-repo>
cd stackctl
./install.sh          # as the Docker user for rootless Docker; with sudo for rootful Docker
```

The installer detects which Docker you have, offers to install missing packages on Debian/Ubuntu, installs
the script and the systemd units, and asks about your Git repo, backup target and (optionally) ntfy. It
creates the deploy key, pins the server's host keys after you confirm their fingerprints, writes the config,
runs `stackctl init`, offers to adopt running stacks and enable the timers, and ends with `stackctl test`.
Run `./install.sh --upgrade` after pulling a new release to replace only the script and the units.

### Rootless or rootful

| | Rootless Docker | Rootful Docker |
|---|---|---|
| Runs as | the Docker user | root |
| Config | `~/.config/stackctl/stackctl.conf` | `/etc/stackctl/stackctl.conf` |
| State | `~/.local/state/stackctl/` | `/var/lib/stackctl/` |
| Units | `~/.config/systemd/user/`, `systemctl --user` | `/etc/systemd/system/`, `systemctl` |
| Needs | lingering, `nsenter` | nothing extra |

`DOCKER_MODE=auto` (the default) picks rootful when run as root. The binary is always
`/usr/local/bin/stackctl`, root-owned, so the user whose timers run it cannot change what they run.

## Requirements

| Needed | When |
|---|---|
| Docker Engine with `docker compose` | Always |
| `git`, `ssh`, `flock`, `tar` | Always |
| `nsenter` (util-linux) and lingering for the user | Rootless Docker |
| `borg` 1.2 or newer in the 1.x series, and a Borg repo | Borg backups |
| `zstd` (falls back to `gzip`) | Tar backups |
| `curl` | ntfy notifications |
| A read-only deploy key or access token for the stacks repo | Always |

`stackctl test` checks everything that applies to your config.

## Manual install

What `install.sh` does, by hand. As root, from a checkout:

```bash
install -m 0755 stackctl /usr/local/bin/stackctl
```

Rootful (as root):

```bash
mkdir -p /etc/stackctl && chmod 700 /etc/stackctl
cp stackctl.conf.example /etc/stackctl/stackctl.conf && chmod 600 /etc/stackctl/stackctl.conf
$EDITOR /etc/stackctl/stackctl.conf
cp systemd/* /etc/systemd/system/ && systemctl daemon-reload
stackctl init && stackctl test
systemctl enable --now stackctl-update.timer stackctl-nightly.timer
```

Rootless (as the Docker user):

```bash
mkdir -p ~/.config/stackctl ~/.config/systemd/user
cp stackctl.conf.example ~/.config/stackctl/stackctl.conf && chmod 600 ~/.config/stackctl/stackctl.conf
$EDITOR ~/.config/stackctl/stackctl.conf
cp systemd/* ~/.config/systemd/user/ && systemctl --user daemon-reload
stackctl init && stackctl test
systemctl --user enable --now stackctl-update.timer stackctl-nightly.timer
```

Run `stackctl adopt` before enabling the timers on a server whose stacks are already running.
`github_known_hosts` holds GitHub's pinned SSH host keys, for use as `GIT_KNOWN_HOSTS`.

[docs/GUIDE.md](docs/GUIDE.md) covers the whole setup (Git deploy keys and tokens, Borg and tar
backups, ntfy), bringing existing stacks under stackctl, and day-to-day use.

## Commands

Run as the Docker user (rootless) or root (rootful). `stackctl help` lists them too.

| Command | What it does |
|---|---|
| `test [--no-notify]` | Checks tools, Docker mode, timers, the Git repo, the backup target and a backup/restore round trip, then a dry run of the next update |
| `status` | Each stack's deployed revision, running containers and state (`up to date`, `update pending`, `ON HOLD`, `not deployed`) |
| `update [--dry-run]` | Deploys changed stacks from Git (the hourly timer runs this) |
| `list <stack>` | Lists a stack's backups |
| `restore <stack> [archive] [--yes]` | Restores a backup (numbered picker if no archive), sets the current folder aside, and puts the stack **on hold** |
| `extract <stack> <archive> <dir>` | Copies a backup into `<dir>` for browsing, without touching the running stack |
| `backup <stack>... [--stop]` | Manual backup, kept until you delete it |
| `nightly` | Backs up every stack and prunes (the nightly timer runs this) |
| `data` | Backs up each folder in `DATA_DIRS` as its own archive series, then prunes (its own timer, 04:30) |
| `hold <stack> [reason]` / `release <stack>` | Stop / resume automatic updates for one stack |
| `init` | Sets up the backup target: creates the Borg repo and exports its key, or the tar folder (first run) |
| `adopt` | Marks stacks that already match the repo as deployed, without restarting them |
| `clean` | Deletes folders set aside by past restores |
| `version`, `help` | |

## Conventions

- **Archives** are named `<stack>@<kind>@<timestamp>@<rev>`, where kind is `pre` (taken before each update),
  `nightly`, `manual`, or `data` (a folder from `DATA_DIRS`, named after the folder). Retention applies per
  stack to `nightly` and `pre` (`KEEP_*`); `manual` archives are never pruned. With tar backups an archive is the
  file `BACKUP_DIR/<stack>/<name>.tar.zst`.
- **State** lives in the state folder (see the table above): `repo.git` (a bare mirror, not a working copy),
  `deployed/<stack>` (revision on disk), `holds/<stack>`, `removed/`.
- **Only tracked files are written or removed.** Stack folders need a `compose.yaml` (or `compose.yml`,
  `docker-compose.yaml`, `docker-compose.yml`).
- **Named Docker volumes are not backed up**, only the stack folder. Use bind mounts for data you need.
- **Tar backups are not encrypted** and stay on the machine unless `BACKUP_DIR` is a separate disk or mount.
  Copy them off the server. Borg gives you encryption and deduplication.

## Configuration

Read from the config path in the table above, or from `$STACKCTL_CONFIG`. Every key is documented in
[stackctl.conf.example](stackctl.conf.example).

## Development

```bash
./test/smoke.sh      # shellcheck, help, version, config loading, unit and example-config checks
./test/tar.sh        # tar backup and retention (Linux; GNU date)
```

Those cannot prove rootful or rootless Docker, Borg over SSH or the timers. Read [AGENTS.md](AGENTS.md)
before changing behaviour: those are proven on a scratch server.

## Versioning

`stackctl version` prints `stackctl X.Y.Z`. Releases are Git tags (`vX.Y.Z`) and are listed in
[CHANGELOG.md](CHANGELOG.md).
