# AGENTS.md

`stackctl` is a single Bash script that deploys Docker Compose stacks from a Git repo and backs them up
to Borg, run as the Docker user from systemd user timers on a server with **rootless Docker**. It is
used on remote machines that are only reachable over SSH, so read `README.md` and `docs/GUIDE.md` before
changing behaviour.

## Layout

- `stackctl`: the tool. `VERSION` is near the top.
- `systemd/`: the three `.service` / `.timer` pairs (update hourly, nightly 03:30, data 04:30).
- `stackctl.conf.example`: every config key. `github_known_hosts`: GitHub's pinned SSH host keys.
- `docs/GUIDE.md`: full setup and day-to-day use. `test/smoke.sh`: lint plus the config-free commands.
- `CHANGELOG.md`: one entry per release.

## Guarantees to keep

- A held stack is never touched.
- A stack is backed up before it is changed; if the backup fails the stack is restarted unchanged.
- Untracked files (data, `.env`) are never written or removed. Only files tracked in Git are.
- Never print or log the Borg passphrase, the ntfy token or key material.

## Contract with consumers

The script is installed by [debian-server-scripts](https://github.com/skgchp/debian-server-scripts)
(its stage 85), which pins a tag and a commit hash and renders the config. These are a public
interface, so changing any of them is **breaking**: bump the major version and say so in `CHANGELOG.md`.

- Config keys in `stackctl.conf.example`, and the fact that `STACKCTL_CONFIG` overrides the path.
- The installed path `/usr/local/bin/stackctl` (units hard-code it) and the unit and timer names
  (`stackctl test` checks `stackctl-update.timer` and `stackctl-nightly.timer`).
- State and config paths: `~/.config/stackctl/`, `~/.local/state/stackctl/`, `~/stacks`.
- The output of `stackctl version` (`stackctl X.Y.Z`): the installer compares it with the pinned tag.

A new optional key with a default is not breaking. Add it to `load_config` and `stackctl.conf.example`
together.

## Rootless Docker and Borg

Anything Borg runs through `in_userns` executes inside rootless Docker's user namespace, where
root-owned files (`/etc/ssh/...`) appear as `nobody` and `ssh` looks for `known_hosts` under `/root`.
That is why `BORG_RSH` uses its own `-F` config and `UserKnownHostsFile`. Test such changes against a
real SSH Borg repo, not a local one.

## Style

Bash, 2-space indent. Comments explain *why*. The script does not source anything but its config file.
Keep it shellcheck-clean:

    shellcheck -x -P SCRIPTDIR stackctl test/*.sh

## Testing

`./test/smoke.sh` lints and checks `help`, `version`, the unit paths and the example config. It
**cannot** prove rootless Docker, Borg over SSH, `nsenter`, lingering or the timers. Say so when you
rely on it. Those are proven with `stackctl test` on a scratch server, and by a real update, restore and
`extract` round trip.

## Releasing

1. Bump `VERSION`, update `CHANGELOG.md`, run `./test/smoke.sh`.
2. Commit, then tag `vX.Y.Z` and note the full commit hash: consumers pin both.

## Git

Work on a feature branch (`main` is the default). Don't commit a real `stackctl.conf`.
