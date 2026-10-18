# stackctl guide

This guide covers setup and day-to-day use. The [README](../README.md) has the command list.

The examples are for a normal user, such as a service account, and use paths in its home folder. If you run
stackctl as root, use `/etc/stackctl` instead of `~/.config/stackctl`, `/var/lib/stackctl` instead of
`~/.local/state/stackctl`, and leave out `--user` from `systemctl` and `journalctl`.

Rootless or rootful Docker only changes how stackctl reaches files owned by container users. With rootless
Docker it uses `nsenter`. With rootful Docker as a normal user it uses a short-lived root container (the
`HELPER_IMAGE` setting), which needs no sudo. With rootful Docker as root it reads them directly.

## How it works

Your stacks live in a Git repository: one top-level folder per stack, each holding a compose file. Add
`data/` and `.env` to the repository's `.gitignore`.

Every hour, `stackctl update` fetches the repository. For each stack whose folder has changed, it:

1. pulls the new images while the stack keeps running;
2. stops the stack and backs it up, so the backup is consistent;
3. writes the new files, then runs `docker compose pull` and `docker compose up -d`.

Every night, `stackctl nightly` backs up each stack and deletes old backups according to your `KEEP_*`
settings. A stack keeps running during its nightly backup unless its folder contains a `.backup-stop` file.

stackctl keeps its own copy of the repository and writes each stack's tracked files itself, instead of
running `git pull` in the stacks folder. That lets one stack stay on an older version, after a restore or
while on hold, while the others update. Untracked files are never touched.

Anything on the deployed branch goes live within the hour, so a direct push is as live as a merge. If you
use Renovate to open pull requests for new images, or Trivy to scan them, configure them in the stacks
repository. stackctl does not need either.

### When something goes wrong

| Situation | What stackctl does |
|---|---|
| Git server unreachable | Skips the run, notifies once, and notifies again when it recovers |
| Pre-update backup fails | Restarts the stack unchanged, notifies, and retries next hour |
| A tracked file was edited on the server | Skips the stack, puts it on hold and lists the files |
| New version fails to start | Puts the stack on hold and notifies urgently. The pre-update backup is ready for `stackctl restore` |
| A stack is removed from the repository | Leaves it running and tells you to take it down by hand |
| Nightly backup or pruning fails | Notifies with the names of the failed stacks |

A stack on hold stays untouched until you run `stackctl release <stack>`.

### What is backed up

Each backup contains a stack's folder, including bind-mounted data inside it.

> Named Docker volumes are not backed up. They live in Docker's data root (`~/.local/share/docker/volumes`
> for rootless, `/var/lib/docker/volumes` for rootful), so a restore would bring the stack back with empty
> volumes. Use bind mounts inside the stack folder (`./data:/var/lib/...`) for anything you cannot lose.

## 1. Install

Run `./install.sh` from a checkout of a release tag. It covers steps 1 to 7 of this guide interactively. To
do it by hand, install the script with root or sudo:

```bash
sudo install -m 0755 -o root -g root stackctl /usr/local/bin/stackctl
```

Without sudo, install it to `~/.local/bin/stackctl` instead and change `ExecStart` in the three `.service` files
to match. The timers then run a script that the account can edit.

Then create the config file and install the units.

As a normal user (rootless Docker, or rootful as a service account):

```bash
mkdir -p ~/.config/stackctl ~/.config/systemd/user
cp stackctl.conf.example ~/.config/stackctl/stackctl.conf
chmod 600 ~/.config/stackctl/stackctl.conf
cp systemd/* ~/.config/systemd/user/ && systemctl --user daemon-reload
loginctl enable-linger "$USER"      # needs root or sudo; the timers stop when you log out without it
```

As root:

```bash
mkdir -p /etc/stackctl && chmod 700 /etc/stackctl
cp stackctl.conf.example /etc/stackctl/stackctl.conf && chmod 600 /etc/stackctl/stackctl.conf
cp systemd/* /etc/systemd/system/ && systemctl daemon-reload
```

Edit the config file. Set at least `STACKS_DIR`, `GIT_REMOTE`, and either `BORG_REPO` or `BACKUP_DIR`. For rootful
Docker as a normal user, also set `DOCKER_MODE="rootful"`, and pull the helper image once with
`docker pull debian:stable-slim`.
Leave the timers off for now.

## 2. Give the server read access to the repository

Use an SSH deploy key or an HTTPS access token. Both are read-only.

### SSH deploy key

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/git-deploy
```

Add `git-deploy.pub` to the repository as a deploy key, with write access off:

- GitHub: Settings > Deploy keys > Add deploy key
- GitLab: Settings > Repository > Deploy keys
- Forgejo and Gitea: Settings > Deploy Keys > Add Deploy Key

In the config, set `GIT_SSH_KEY` to the private key. Put a non-standard SSH port in the URL, for example
`ssh://git@forgejo.example.com:2222/you/stacks.git`.

stackctl never accepts an unknown host key automatically, so record the server's host keys in a file and
point `GIT_KNOWN_HOSTS` at it. For GitHub, use the keys supplied in this repository:

```bash
install -m 0644 github_known_hosts ~/.config/stackctl/known_hosts-git
```

For any other server, scan its keys and check the fingerprints against the ones the server publishes:

```bash
ssh-keyscan -p 22 -t ed25519,ecdsa,rsa git.example.com > ~/.config/stackctl/known_hosts-git
ssh-keygen -lf ~/.config/stackctl/known_hosts-git
```

### HTTPS access token

Create a read-only token:

- GitHub: a fine-grained token with Contents set to read-only
- GitLab: a project access token with `read_repository`, or a deploy token
- Forgejo and Gitea: an application token with `read:repository`

Save it to a file that only you can read:

```bash
(umask 077 && printf '%s\n' 'THE-TOKEN' > ~/.config/stackctl/git-token)
```

In the config, set `GIT_REMOTE` to the `https://` URL, `GIT_TOKEN_FILE` to that file, and `GIT_USERNAME` to
`oauth2`. A GitLab deploy token has its own username (`gitlab+deploy-token-N`). stackctl reads the token from
the file when Git asks for it. It never appears on a command line, in the environment or in the logs.

## 3. Choose where backups go

Pick one. Both take a backup before every update and one every night, with the same retention settings.

### Tar files

Set `BACKUP_DIR` to an absolute path. Each backup becomes one `.tar.zst` file (`.tar.gz` if `zstd` is not
installed) in `BACKUP_DIR/<stack>/`. These backups are not encrypted or deduplicated, and a backup on the
same disk is lost if the disk fails. Use a separate disk or mount, or copy the folder elsewhere with rsync or
to a NAS.

### Borg

Borg makes encrypted, deduplicated backups to a local or remote repository. These steps cover a remote
repository reached over SSH. The examples use `backup-user@backup.example.com`.

1. Create a key and a passphrase file:

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/borg
(umask 077 && head -c 32 /dev/urandom | base64 > ~/.config/stackctl/borg-passphrase)
```

2. Install the public key on the backup host (`~/.ssh/borg.pub`), for example with
   `ssh-copy-id -i ~/.ssh/borg.pub backup-user@backup.example.com`. The host needs Borg 1.x installed. If its
   binary has another name, such as `borg-1.4`, set `BORG_REMOTE_PATH` to it.
3. Record the host's key in a file, then check the fingerprint against the one your provider publishes:

```bash
ssh-keyscan -t ed25519,ecdsa,rsa backup.example.com > ~/.config/stackctl/known_hosts-borg
ssh-keygen -lf ~/.config/stackctl/known_hosts-borg
```

4. Create the parent folder of the repository on the host, because Borg does not:
   `ssh -i ~/.ssh/borg backup-user@backup.example.com mkdir backups`.
5. Set these in the config, using absolute paths:

```bash
BORG_REPO="ssh://backup-user@backup.example.com/./backups/myhost"
BORG_PASSCOMMAND="cat /home/you/.config/stackctl/borg-passphrase"
BORG_RSH="ssh -F /home/you/.config/stackctl/ssh_config -i /home/you/.ssh/borg -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=/home/you/.config/stackctl/known_hosts-borg"
```

With rootless Docker, Borg runs inside Docker's user namespace, where `/etc/ssh` looks like it belongs to
`nobody` and ssh looks for known hosts under `/root`. The `-F` option and `UserKnownHostsFile` above avoid
that, so create an empty ssh config with `touch ~/.config/stackctl/ssh_config`. With rootful Docker, drop the
`-F` option.

Some providers need a special port or path. For example, a Hetzner Storage Box uses SSH port 23 and a path
that starts `/./`, as in `ssh://user@host:23/./backups/myhost`, and its sub-accounts connect to the main
account's hostname.

## 4. Set up notifications (optional)

Leave `NTFY_URL` empty to skip this. stackctl then only writes to the journal, and `stackctl test` reports
ntfy as skipped.

On your ntfy server, create a user that can only publish to one topic. You may need `sudo`.

```bash
ntfy user add stackctl
ntfy access stackctl stackctl write-only
ntfy token add stackctl
```

Put the token (it starts with `tk_`) in `NTFY_TOKEN`. Set `NTFY_URL` to the address including the topic, for
example `https://ntfy.example.com/stackctl`. Without the topic, ntfy answers 404 or 400. Then subscribe to
the topic on your phone.

Two things to watch for:

- If ntfy denies anonymous access, an empty token makes every notification fail with `403`.
- If ntfy runs as one of your stacks, it cannot report problems while it is down. Monitor the server from
  somewhere else as well.

## 5. Create the backup target

```bash
stackctl init
```

For tar, this creates `BACKUP_DIR`. For Borg, it creates the repository and exports its key. With Borg, save
the key export and the passphrase in your password manager, then delete the export. Without both, you cannot
restore if the server is lost.

```bash
cat ~/.local/state/stackctl/borg-key-export.txt
cat ~/.config/stackctl/borg-passphrase
rm ~/.local/state/stackctl/borg-key-export.txt
```

## 6. Bring in existing stacks

Skip this on a new server. On a server that already runs stacks, read it before enabling updates.

stackctl deploys whatever is on the deployed branch. If the image versions in the repository are newer than
the data on this server, the first deploy runs new images against old data. Some apps cannot start on data
from an older major version, or need each major release in turn. Before enabling updates:

- Compare each stack's data version with the image the repository will deploy.
- Check that host paths in compose files, such as `/mnt/data/...`, exist on this server.

Hold any stack whose data needs migrating, preview what would change, and take a baseline backup:

```bash
stackctl hold app "data needs migrating first"
stackctl update --dry-run
stackctl backup app --stop
```

Migrate one stack at a time, following the app's own upgrade instructions, then run `stackctl release app`.
stackctl never touches untracked files, so you can add a temporary `docker-compose.override.yml` during a
migration (for example to stop a service starting) and delete it afterwards.

### Data copied from another server

On rootless Docker, files copied as the Docker user are owned by root inside the containers. Containers
that run as another user then fail with "not writable" or "Operation not permitted". Fix the ownership
inside Docker's user namespace, using the user ID the image runs as (find it with
`docker run --rm --entrypoint id <image>`):

```bash
nsenter -U --preserve-credentials -t "$(cat /run/user/$(id -u)/docker.pid)" -- \
  chown -R 1000:1000 ~/stacks/app/data
```

On rootful Docker, use `sudo chown -R 1000:1000 ~/stacks/app/data`. Without sudo, run the same command in a
root container:

```bash
docker run --rm -v "$HOME/stacks:$HOME/stacks" debian:stable-slim chown -R 1000:1000 "$HOME/stacks/app/data"
```

### Adopt the stacks

Put your stacks in `STACKS_DIR`, under the same names as in the repository, and keep any originals until
everything works. Then record which stacks already match the repository, so the first hourly run does not
restart them all:

```bash
stackctl adopt
```

Stacks that differ are backed up and updated on the first run. To avoid that, commit the server's version of
those files to Git and run `adopt` again. If the stacks folder is a Git clone, its `.git` folder is no longer
used and can be removed once everything works.

## 7. Start the timers and test

```bash
systemctl --user enable --now stackctl-update.timer stackctl-nightly.timer
systemctl --user enable --now stackctl-data.timer      # only if DATA_DIRS is set
stackctl test
```

To keep backups but deploy by hand, leave out `stackctl-update.timer` and run `stackctl update` yourself.

`stackctl test` checks the tools, the Docker mode, the timers, Git access, the backup target and a full
backup and restore round trip. It sends a test notification if ntfy is set up (add `--no-notify` to skip
that), then shows a dry run of the next update. Run it again after any change to the server, keys or backup
target.

## Day to day

### Check on things

```bash
stackctl status
journalctl --user -u stackctl-update.service -n 50
```

### Apply a merged change now

```bash
stackctl update
```

### Restore a stack

```bash
stackctl list app
stackctl restore app
```

The restore stops the stack, moves its current folder to `.stackctl-trash` in the stacks folder, restores the
backup, starts the stack and puts it on hold. To stay on the restored version, revert the change in Git, then
release the stack:

```bash
stackctl release app
```

If you release it without reverting, the next run updates it to the latest version again, after a fresh
backup. When you are happy with the result, delete the set-aside folders with `stackctl clean`.

### Get one file back without touching the running stack

```bash
stackctl extract app app@nightly@2026-09-29T033012@a1b2c3d ~/restore-browse
```

### Pause updates for a stack

```bash
stackctl hold app "migrating database by hand"
stackctl release app
```

### Get consistent nightly backups for databases

Add an empty `.backup-stop` file to the stack's folder, ideally committed to the repository. The stack is
then stopped for its nightly backup and restarted afterwards, including all of its services.

### Back up a folder outside the stacks

Large data outside the stack folders, such as a mounted volume, is not in the stack backups. Set the folders
in the config and enable `stackctl-data.timer` (04:30, after the stack backups):

```bash
DATA_DIRS="/mnt/media /mnt/archive"     # space-separated absolute paths
KEEP_DATA_DAILY=7
KEEP_DATA_WEEKLY=4
KEEP_DATA_MONTHLY=3
```

Each folder becomes its own series named after the folder, for example `media@data@<time>@none`. It is not
part of updates, stack pruning or `stackctl restore`. Use `stackctl list media` and
`stackctl extract media <archive> <dir>` to browse or recover. `lost+found` is excluded, and `stackctl test`
checks that each folder is readable.

If an app keeps its database in a stack folder and its files in a data folder, the two backups are taken a
little apart. For a consistent pair, stop the app or put it in maintenance mode around the backups, or
restore both from the same night.

### Skip caches in Borg backups

Borg skips any folder containing a `CACHEDIR.TAG` file with the standard signature:

```bash
printf 'Signature: 8a477f597d28d172789f06886806bc55\n' > ~/stacks/app/data/cache/CACHEDIR.TAG
```

### Take a manual backup

```bash
stackctl backup app --stop
```

Manual backups are named `app@manual@...` and are never deleted automatically. Delete one with
`borg delete ::<archive>` (Borg), or remove its file from `BACKUP_DIR/app/` (tar).

### Upgrade stackctl

Check [CHANGELOG.md](../CHANGELOG.md). A major version can change config keys, paths or unit names. Then run
`./install.sh --upgrade` from the new release. It replaces the script and the units, reloads systemd and
leaves your config, keys and passphrase alone.

### Test a real restore

The self-test proves the backup system works. Every few months, also restore a real stack into a scratch
folder with `stackctl extract` and check that the data opens.

### Running commands again

`update`, `nightly`, `adopt`, `init`, `hold`, `release`, `test` and `install.sh` are safe to run again.
`restore` sets the current folder aside and restores again each time, and `backup` makes a new backup each
time.
