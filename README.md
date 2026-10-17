# stackctl

Pull-based deploys with Borg backups for Docker Compose stacks, on a single server running
**rootless Docker**. One Bash script, run from systemd user timers.

- Deploys the stacks in a Git repo (one top-level folder per stack, each with a `compose.yaml`).
- Takes a Borg backup of a stack **before** it changes it, and a nightly backup of every stack.
- Notifies through [ntfy](https://ntfy.sh) when something is updated or goes wrong.
- Can back up folders outside the stacks (for example a mounted volume) as separate archive series.

It was written for the Hetzner VPS built by
[debian-server-scripts](https://github.com/skgchp/debian-server-scripts), which installs and pins it
with its stage 85. It also works standalone: see [Manual install](#manual-install).

## Guarantees

- **A held stack is never touched.** A failed or tampered stack goes on hold instead of retrying
  hourly, so a bad update cannot push good backups out of retention.
- **A stack is backed up before it is changed.** If that backup fails, the stack is restarted unchanged.
- **Untracked files are never written or removed.** Data and `.env` files stay where they are, because
  only files tracked in Git are written.

## Requirements

| Needed | Why |
|---|---|
| Rootless Docker with `docker compose`, and lingering enabled for the user | Runs the stacks and the timers |
| `borg` 1.2 or newer in the 1.x series (and a Borg repo, such as a Hetzner Storage Box) | Backups |
| `git`, `curl`, `flock` and `nsenter` (util-linux) | Fetching, ntfy, locking, reading container-owned files |
| A read-only deploy key for the stacks repo | Fetching |

`stackctl test` checks all of these.

## Manual install

As root, from a checkout of this repo:

```bash
install -m 0755 stackctl /usr/local/bin/stackctl
```

As the Docker user:

```bash
mkdir -p ~/.config/stackctl ~/.config/systemd/user
cp stackctl.conf.example ~/.config/stackctl/stackctl.conf && chmod 600 ~/.config/stackctl/stackctl.conf
$EDITOR ~/.config/stackctl/stackctl.conf
cp systemd/* ~/.config/systemd/user/
systemctl --user daemon-reload
stackctl init            # creates the Borg repo; save the key export and passphrase off-server
stackctl adopt           # only on a server whose stacks are already running
stackctl test
systemctl --user enable --now stackctl-update.timer stackctl-nightly.timer
```

The units run `/usr/local/bin/stackctl`, so keep the binary there, root-owned: the user whose timers
execute it then cannot change what they run. `github_known_hosts` holds GitHub's pinned SSH host keys
for `~/.ssh/known_hosts`.

[docs/GUIDE.md](docs/GUIDE.md) covers the whole setup (GitHub deploy key, Storage Box, ntfy), bringing
existing stacks under stackctl, and day-to-day use.

## Commands

Run as the Docker user. `stackctl help` lists them too.

| Command | What it does |
|---|---|
| `test [--no-notify]` | Checks tools, rootless Docker, user namespace, lingering, timers, GitHub, Borg and a backup/restore round trip, then a dry run of the next update |
| `status` | Each stack's deployed revision, running containers and state (`up to date`, `update pending`, `ON HOLD`, `not deployed`) |
| `update [--dry-run]` | Deploys changed stacks from Git (the hourly timer runs this) |
| `list <stack>` | Lists a stack's backups |
| `restore <stack> [archive] [--yes]` | Restores a backup (numbered picker if no archive), sets the current folder aside, and puts the stack **on hold** |
| `extract <stack> <archive> <dir>` | Copies a backup into `<dir>` for browsing, without touching the running stack |
| `backup <stack>... [--stop]` | Manual backup, kept until you delete it |
| `nightly` | Backs up every stack and prunes (the nightly timer runs this) |
| `data` | Backs up each folder in `DATA_DIRS` as its own archive series, then prunes (its own timer, 04:30) |
| `hold <stack> [reason]` / `release <stack>` | Stop / resume automatic updates for one stack |
| `init` | Creates the Borg repo and exports its key (first run) |
| `adopt` | Marks stacks that already match the repo as deployed, without restarting them |
| `clean` | Deletes folders set aside by past restores |
| `version`, `help` | |

## Conventions

- **Archives** are named `<stack>@<kind>@<timestamp>@<rev>`, where kind is `pre` (taken before each update),
  `nightly`, `manual`, or `data` (a folder from `DATA_DIRS`, named after the folder). Retention applies per
  stack to `nightly` and `pre` (`KEEP_*`); `manual` archives are never pruned.
- **State** lives in `~/.local/state/stackctl/`: `repo.git` (a bare mirror, not a working copy),
  `deployed/<stack>` (revision on disk), `holds/<stack>`, `removed/`.
- **Only tracked files are written or removed.** Stack folders need a `compose.yaml` (or `compose.yml`,
  `docker-compose.yaml`, `docker-compose.yml`).
- **Named Docker volumes are not backed up**, only the stack folder. Use bind mounts for data you need.

## Configuration

Read from `~/.config/stackctl/stackctl.conf`, or from `$STACKCTL_CONFIG`. Every key is documented in
[stackctl.conf.example](stackctl.conf.example).

## Development

```bash
./test/smoke.sh      # shellcheck, help, version, unit and example-config checks
```

That cannot prove rootless Docker, Borg over SSH or the timers. Read [AGENTS.md](AGENTS.md) before
changing behaviour: those are proven on a scratch server.

## Versioning

`stackctl version` prints `stackctl X.Y.Z`. Releases are Git tags (`vX.Y.Z`) and are listed in
[CHANGELOG.md](CHANGELOG.md). Consumers should pin a tag **and** its commit hash.
