# stackctl guide: setup and day-to-day use

`stackctl` deploys your Docker Compose stacks from a Git repo (GitHub, GitLab, Forgejo, Gitea, ...) and backs
them up to a Borg repo or to tar files. It runs from systemd timers, as root against rootful Docker or as the
Docker user against rootless Docker. See the [README](../README.md) for the command reference.

`./install.sh` does the install, key and config steps below for you interactively. This guide explains what
it does, how to do it by hand, and everything after.

## How it fits together

1. **Renovate** (optional; the Mend Renovate app on GitHub, or self-hosted Renovate for GitLab, Forgejo and Gitea) opens a pull request in your stacks repo when a newer image is available.
2. **Trivy scan** (optional; a CI workflow in your stacks repo) comments on the pull request with what the update fixes and introduces.
3. **Minor, patch and digest updates merge themselves** overnight once the Trivy check passes and the release is at least
   three days old (see `renovate.json` in the stacks repo). **Major updates never do**: you review and merge them. Postgres
   majors are not offered at all (they need a dump and restore), and Nextcloud majors arrive one PR per major, labelled
   `manual-migration`. Either way, anything on `main` goes live within the hour, so a direct push is as live as a merge.
4. **stackctl update** runs hourly on the VPS. For each stack whose folder changed, it:
   - pre-pulls the new images while the stack keeps running
   - stops the stack and backs it up, so the backup is consistent
   - writes out the new files, then runs `docker compose pull` and `docker compose up -d`
5. **stackctl nightly** backs up every stack each night, live unless the stack has a `.backup-stop` file, then prunes old archives.
6. If you set up ntfy, you get a notification for updates and for anything that goes wrong. Without it, check `stackctl status` and the journal.

The stacks repo is separate from this one: one top-level folder per stack, each with a `compose.yaml`
(or `compose.yml`, `docker-compose.yaml`, `docker-compose.yml`). Add `data/` and `.env` to its `.gitignore`.
Renovate and Trivy configuration lives in that repo, not here. See Part 1.

### Why the VPS keeps a mirror rather than a working copy

`stackctl` keeps a private copy of the repo in `~/.local/state/stackctl/repo.git` and writes each stack's files individually, instead of running `git pull` in the stacks folder. This lets one stack sit on an older version (after a restore, or while on hold) while the others keep updating. Your data and `.env` files are never touched, because only files tracked in Git are written or removed.

### What happens when things go wrong

| Situation | What stackctl does |
|---|---|
| Git server unreachable | Skips the run and notifies once, then again when it recovers |
| Pre-update backup fails | Restarts the stack unchanged, notifies, retries next hour |
| A tracked file was edited on the server | Skips that stack, puts it on hold, notifies with the file list |
| New version fails to start | Puts the stack on hold and notifies urgently. The pre-update backup is ready for `stackctl restore` |
| A stack is removed from the repo | Leaves it running and notifies you to take it down by hand |
| Nightly backup or prune fails | Notifies with the failed stacks |

A held stack is never touched by updates until you run `stackctl release <stack>`, so a broken update can't be retried hourly and push your good backups out of retention.

### What is and is not backed up

Each backup archives a stack's **folder** (`<STACKS_DIR>/<stack>`), including bind-mounted data under it.

> **Named Docker volumes are not backed up.** They live in Docker's data root (`~/.local/share/docker/volumes` for rootless Docker, `/var/lib/docker/volumes` for rootful), outside the
> stack folder, so a restore would bring the stack back with empty volumes. Use bind mounts under the
> stack folder (`./data:/var/lib/...`) for anything you cannot lose.

## What you set up

| Step | Where |
|---|---|
| Put your stacks in a Git repo (and optionally Renovate) | Part 1 |
| Install and configure | Part 2 |
| Give the server read access to the repo (deploy key or token) | Part 3 |
| Choose a backup target: tar files or Borg (Storage Box example) | Part 4 |
| Optionally set up ntfy | Part 5 |
| Run `stackctl init`; with Borg, copy the key export and passphrase off the server | Part 6 |
| Run `stackctl adopt` on a server with existing stacks | Part 7 |
| Enable the timers and run `stackctl test` | Parts 8 and 9 |

Commands below run as the Docker user (rootless) or root (rootful), unless they say otherwise. See
[Rootful Docker](#rootful-docker) for what differs.

## Part 1: The stacks repo

1. Create a private repo on your Git server and push your stack folders. Each stack is a top-level folder with a compose file.
2. Optional, to keep images up to date: add a `renovate.json` and let Renovate open pull requests.
   - GitHub: install the Mend Renovate app (`github.com/apps/renovate`) and choose **Only select repositories**.
   - GitLab, Forgejo, Gitea: run Renovate yourself ([docs](https://docs.renovatebot.com)); it supports all three.
3. Optional, to scan updates: a CI workflow in the repo that runs Trivy on pull requests (GitHub Actions, GitLab CI or Forgejo Actions).

Your stacks repo's `renovate.json` can automerge minor, patch and digest updates (after the scan and a release-age delay) and
leave majors to you. For approval on every update, drop the automerge rule. Validate any change to `renovate.json` before
merging it, because a single invalid rule makes Renovate pause **all** pull requests:
`npx --yes --package renovate -- renovate-config-validator renovate.json`.

Anything on the deployed branch goes live within the hour, so a direct push is as live as a merge. Where your plan allows it,
protect the branch and require pull requests.

## Part 2: Install and configure

Run `./install.sh` from a checkout of a release tag, or follow [Manual install](../README.md#manual-install): put the
binary at `/usr/local/bin/stackctl`, copy `stackctl.conf.example` to the config path (mode 0600) and set at least:

```bash
GIT_REMOTE="git@github.com:YOUR-USER/YOUR-REPO.git"
BORG_REPO="ssh://u123456-sub1@u123456.your-storagebox.de:23/./backups/myhost"   # or BACKUP_DIR="/var/backups/stackctl"
```

Do not enable the timers yet. Every option is documented in `stackctl.conf.example`.

## Part 3: Read access to the repo

Pick the way that suits your Git server. Both are read-only.

### SSH deploy key

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/git-deploy        # as root, ~ is /root
```

Add `git-deploy.pub` to the repo as a deploy key with write access **off**:

- GitHub: repo **Settings > Deploy keys > Add deploy key**.
- GitLab: project **Settings > Repository > Deploy keys**.
- Forgejo / Gitea: repo **Settings > Deploy Keys > Add Deploy Key**.

Set `GIT_SSH_KEY` to the private key. A non-standard SSH port goes in the URL: `ssh://git@forgejo.example.com:2222/you/stacks.git`.

Pin the server's host keys so there is no trust-on-first-use prompt (stackctl never auto-accepts host keys). For GitHub, use the
pinned keys in this repo (they come from `https://api.github.com/meta`); for any other server, scan the keys and compare the
fingerprints with the ones your server publishes:

```bash
install -m 0644 github_known_hosts ~/.config/stackctl/known_hosts-git                         # GitHub
ssh-keyscan -p 22 -t ed25519,ecdsa,rsa git.example.com > ~/.config/stackctl/known_hosts-git   # others
ssh-keygen -lf ~/.config/stackctl/known_hosts-git
```

Then set `GIT_KNOWN_HOSTS` to that file. (Rootful: use `/etc/stackctl/` instead of `~/.config/stackctl/`.)

### HTTPS access token

Create a read-only token and put it in a file with mode 0600:

- GitHub: a fine-grained token with **Contents: read-only** on the repo.
- GitLab: a project access token with `read_repository`, or a deploy token.
- Forgejo / Gitea: an application token with `read:repository`.

```bash
(umask 077 && printf '%s\n' 'THE-TOKEN' > ~/.config/stackctl/git-token)
```

Set `GIT_REMOTE` to the `https://` URL, `GIT_TOKEN_FILE` to the file, and `GIT_USERNAME` to `oauth2` (access tokens on GitLab,
Forgejo and Gitea). A GitLab **deploy token** has its own username (`gitlab+deploy-token-N`). The token is read from the file
when Git needs it and is never put on a command line, in the environment or in the logs.

`stackctl test` checks that the repo can be read.

## Part 4: Backups

Choose one backend. Both take a backup before every update and a nightly backup of every stack, with the same retention settings.

### Option A: tar files

Set `BACKUP_DIR` to an absolute path (for example a mounted disk). Each backup is one `.tar.zst` file (gzip if `zstd` is not
installed) in `BACKUP_DIR/<stack>/`. `stackctl init` creates the folder. Tar backups are **not encrypted and not deduplicated**,
and a backup on the same disk does not survive that disk failing: point `BACKUP_DIR` at a separate disk or mount, or copy it off
the server (rsync, a NAS). Nothing else is needed.

### Option B: Borg on a Hetzner Storage Box

Borg gives encrypted, deduplicated backups to a remote repo. Any Borg repo works; this is the Storage Box walkthrough.

In the Hetzner console:

1. Create a **sub-account** for this VPS with its own base directory, for example `vps-borg`.
2. Enable **SSH support** for the sub-account, and **external reachability** if the VPS is outside Hetzner.
3. On the main Storage Box, turn on **automatic snapshots** (for example daily, keeping 7). The VPS can't delete these, so they protect you if the server is ever compromised.

Note the sub-account's username, which looks like `u123456-sub1`. Sub-accounts connect to the **main
account's hostname** (`u123456.your-storagebox.de`), with the sub-account username. Borg needs SSH on **port 23**.
Generate a key (`ssh-keygen -t ed25519 -N '' -f ~/.ssh/storagebox`) and a passphrase
(`(umask 077 && head -c 32 /dev/urandom | base64 > ~/.config/stackctl/borg-passphrase)`), then install the `storagebox` key on it.
It asks for the sub-account password once, and skips keys already installed:

```bash
ssh-copy-id -p 23 -s -i ~/.ssh/storagebox.pub u123456-sub1@u123456.your-storagebox.de
```

Test the connection, which also records the Storage Box's host key:

```bash
ssh -p 23 -i ~/.ssh/storagebox -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new u123456-sub1@u123456.your-storagebox.de ls
```

Compare the fingerprint against the ones Hetzner publishes in its
[Storage Box overview](https://docs.hetzner.com/storage/storage-box/general/) before trusting it
(ED25519 `SHA256:XqONwb1S0zuj5A1CDxpOSuD2hnAArV1A3wKY7Z3sdgM`, RSA `SHA256:EMlfI8GsRIfpVkoW1H2u0zYVpFGKkIMKHFZIRkf2ioI`
at the time of writing; check the page if they differ). Without this step Borg fails with
`Host key verification failed`, because stackctl never auto-accepts host keys.

Then create the folder that will hold the repo's **parent**, because Borg won't create it
(`Repository … does not exist` / `The parent path of the repo directory … does not exist`):

```bash
ssh -p 23 -i ~/.ssh/storagebox -o IdentitiesOnly=yes u123456-sub1@u123456.your-storagebox.de mkdir backups
```

Your `BORG_REPO` is then `ssh://u123456-sub1@u123456.your-storagebox.de:23/./backups/myhost`. The
`:23` and the `/./` (path relative to the sub-account's home, not the server's filesystem root) are both
required for a Storage Box.

## Part 5: ntfy notifications (optional)

Skip this part and leave `NTFY_URL` empty if you don't want notifications. stackctl then only logs to the journal, and
`stackctl test` shows ntfy as `[SKIP]`.

On your ntfy server, create a user that can only publish to one topic. These commands may need `sudo`,
depending on how ntfy is installed:

```bash
ntfy user add vps-deploy
ntfy access vps-deploy vps-deploy write-only
ntfy token add vps-deploy
```

Put the token (it starts with `tk_`) in `NTFY_TOKEN`, and set `NTFY_URL` **including the
topic**: `https://ntfy.example.com/vps-deploy` (without the topic ntfy answers 404/400). Then subscribe to the `vps-deploy` topic on your phone.

If your ntfy denies anonymous access (`auth-default-access: deny-all`), an **empty** token makes every
notification fail with `403`, which is easy to miss. If ntfy runs as one of your stacks, it only receives
notifications once Traefik and ntfy are both up; until then alerts (including "Cannot reach Git server") can't
be delivered. Consider also watching the server from somewhere else, since a notification about the server
dying can't be sent through the server.

## Part 6: Set up the backup target

```bash
stackctl init
```

With tar this creates `BACKUP_DIR` and checks it is writable. With Borg it creates the repo and exports its key.
**Before going further with Borg,** copy the exported key file and the passphrase into your password manager,
then delete the export. Without both, the backups can't be restored if the server is lost:

```bash
cat ~/.local/state/stackctl/borg-key-export.txt        # rootful: /var/lib/stackctl/borg-key-export.txt
cat ~/.config/stackctl/borg-passphrase                 # rootful: /etc/stackctl/borg-passphrase
rm ~/.local/state/stackctl/borg-key-export.txt
```

## Part 7: Bring your existing stacks under stackctl

**Read this before enabling automatic updates on a server whose data came from somewhere else.** `stackctl`
deploys whatever is on `main` of your stacks repo. If Renovate has been merging image bumps while your data
stayed behind, the first deploy would run new images against old data. In practice that means:

- **Postgres**: a major version bump (for example 16 to 18) cannot start on the old data directory. The
  official `postgres:18` image also keeps its data in `/var/lib/postgresql/18/docker`, so a compose file that
  mounts `/var/lib/postgresql/data` would start with an **empty database** and leave your data unused.
  Migrate with a dump and restore, and fix the mount, before releasing the stack.
- **Nextcloud** refuses to skip major versions (32 to 35 must go 33, then 34, then 35).
- **Host paths** in compose files (for example `/mnt/data/...`) must exist on the new server.
- Compare the data's real version with the image you are about to run (`PG_VERSION` in a Postgres data
  directory, `version.php` for Nextcloud) before the first update.

Protect those stacks first. `hold` stops any update of a stack, and leaving `stackctl-update.timer` disabled keeps the
nightly backup timer while disabling automatic deploys:

```bash
stackctl hold vaultwarden "Postgres 16 data, repo is 18"
stackctl update --dry-run        # shows exactly which stacks would change
```

Take a baseline backup of every stack (`stackctl backup <stack>... [--stop]`) before changing anything.
Then migrate one stack at a time and `stackctl release` it when its data matches the repo.

### Recipe: Postgres 16 to 18 (one stack at a time)

This worked for Vaultwarden and Forgejo with every table's row count identical afterwards. Replace
`<stack>`, `<db-service>`, `<user>` and `<db>` (the compose service, `POSTGRES_USER` and `POSTGRES_DB`).

1. Put the stack on hold, then take a consistent dump from the **running** old database and record row counts:
   `docker exec <db-service> pg_dump -U <user> -Fc <db> > dump`, plus a `count(*)` per table.
   Check that the dump is readable (`pg_restore -l`) and keep its checksum.
2. Stop the stack and **move the old data directory aside** (`mv appdata/<db-service> appdata/<db-service>.pg16`).
   Keep it until you are happy: it is your instant rollback.
3. Make sure the compose file mounts the volume at `/var/lib/postgresql` (not `.../data`) for Postgres 18, then
   `stackctl release <stack>` and `stackctl update`. If the app must not start against the empty new database
   (for example it needs an intermediate version first), add an untracked `docker-compose.override.yml`
   with `profiles: ["migration-hold"]` on the app service, and delete it afterwards. stackctl never touches
   untracked files.
4. Restore into the new, empty database: `pg_restore -U <user> -d <db> --no-owner --no-acl --exit-on-error < dump`.
   If the app already created its own schema there, drop and recreate the database first.
5. Compare the row counts, then start the app. It runs its own migrations on your restored data.
6. For apps that must not skip major versions (Forgejo, Nextcloud), step through each required release,
   taking a fresh dump between steps.

### Recipe: data copied from another server

On rootless Docker, files copied as the plain Docker user are owned by root **inside** the containers. Containers that run as a
non-root user then fail with "not writable" or `Operation not permitted`. Postgres and apps that start as root
cope; images like Forgejo's rootless build (uid 1000) do not. Fix ownership **inside rootless Docker's
user namespace**, so it maps to the right sub-UID:

```bash
nsenter -U --preserve-credentials -t "$(cat /run/user/$(id -u)/docker.pid)" -- \
  chown -R 1000:1000 ~/stacks/forgejo/appdata/forgejo
```

On rootful Docker none of this is needed: a plain `chown -R 1000:1000` as root does it.

Use the uid the image runs as (`docker run --rm --entrypoint id <image>`). When you can, copy with ownership
preserved instead (rsync as root inside the namespace).

The stacks folder (`STACKS_DIR`) must contain your stacks at `<STACKS_DIR>/<stack>` (the same names as in the repo). If they
live elsewhere, copy them there with `cp -a`, keeping the originals until everything works.

Put your stacks in `STACKS_DIR` (the installer suggests `~/stacks`, or `/srv/stacks` for rootful), then record which ones
already match the repo, so the first hourly run doesn't restart them all:

```bash
stackctl adopt
```

Any stack listed as different from the repo will be backed up and updated on the first run. If you'd
rather it wasn't, commit the server's version of those files to Git first and run `adopt` again.
If the stacks folder is currently a Git clone, its `.git` folder is no longer used and can be removed
once everything works.

## Part 8: Start the timers

```bash
systemctl --user enable --now stackctl-nightly.timer stackctl-update.timer
systemctl --user enable --now stackctl-data.timer      # only if DATA_DIRS is set
```

Rootful: the same without `--user`.

Skip `stackctl-update.timer` to keep backups but deploy by hand with `stackctl update`.

## Part 9: Test

```bash
stackctl test
```

This checks the tools, that Docker is running in the mode you configured (plus the user namespace and lingering
for rootless), the timers, Git access, the backup target, a full backup and restore round trip, and sends a test
notification if ntfy is set up. It finishes with a
dry run of what the next update would do. Add `--no-notify` to skip the notification.

Run it again after any change to the server, keys or backup target.

## Rootful Docker

Everything above applies. What differs when stackctl runs as root against a normal (rootful) Docker install:

- Config `/etc/stackctl/stackctl.conf`, state `/var/lib/stackctl`, units in `/etc/systemd/system`, and `systemctl`
  without `--user`. Logs: `journalctl -u stackctl-update.service`.
- No user namespace: container-owned files are read and restored as root, with their numeric owners kept
  (`--numeric-ids` for Borg, `--numeric-owner` for tar). There is no `nsenter`, no lingering, and no `BORG_RSH` workaround
  (a plain `ssh -i KEY` works).
- `DOCKER_MODE` defaults to `auto`, which means rootful when run as root. The installer writes the mode into the config, and
  stackctl refuses to run if the user does not match it, so a rootless user cannot accidentally use root's config.

## Day to day

### See what's going on

```bash
stackctl status
journalctl --user -u stackctl-update.service -n 50      # rootful: journalctl -u ...
```

### Apply a merged change now instead of waiting

```bash
stackctl update
```

### Restore a stack

```bash
stackctl list app
stackctl restore app
```

The restore stops the stack, moves its current folder into `.stackctl-trash`, restores the backup, starts
it, and puts it **on hold**. To keep it on the restored version, revert the update in Git and then release it:

```bash
stackctl release app
```

If you release without reverting, the next run updates it to `main` again, taking a fresh backup first.
Once you're happy, remove the set-aside folders with `stackctl clean`.

### Get a single file back without touching the running stack

```bash
stackctl extract app app@nightly@2026-09-29T033012@a1b2c3d ~/restore-browse
```

### Pause updates for a stack

```bash
stackctl hold app "migrating database by hand"
stackctl release app
```

### Consistent nightly backups for stacks with databases

Add an empty `.backup-stop` file to the stack's folder, ideally committed to the repo. That stack is then
stopped briefly while it's backed up each night. Note that it restarts all of the stack's services afterwards.

### Back up a folder outside the stacks as its own job

Large data that lives outside the stack folders (for example Nextcloud's files on a mounted Hetzner volume)
is not covered by the per-stack backups. Give it its own Borg job: set the folder in `stackctl.conf` and enable `stackctl-data.timer`.

```bash
DATA_DIRS="/mnt/nextcloud-data"     # space-separated absolute paths
KEEP_DATA_DAILY=7                   # separate retention from the stacks
KEEP_DATA_WEEKLY=4
KEEP_DATA_MONTHLY=3
```

- It runs `stackctl data` from its own timer (`stackctl-data.timer`, 04:30, after the stack backups), once it is
  enabled and `DATA_DIRS` is set. Run it by hand with `stackctl data`.
- Each folder is its own archive series named after the folder: `nextcloud-data@data@<time>@none`. It never takes
  part in stack updates, stack pruning or `stackctl restore`. `lost+found` is excluded, and files owned by
  container users are read through rootless Docker's user namespace, like stack backups.
- Browse or recover with the normal commands:
  `stackctl list nextcloud-data` and `stackctl extract nextcloud-data <archive> <dir>`.
- `stackctl test` checks each folder is readable inside the user namespace.
- **Consistency:** the Nextcloud database is in the stack backups and its files are in this job, taken a
  little apart. For a strictly consistent copy, restore the database and files from the same night, then run
  `occ files:scan --all`. If you need an exact snapshot, put Nextcloud in maintenance mode
  (`occ maintenance:mode --on`) around the backup.

### Skip caches in backups

Borg skips any folder containing a `CACHEDIR.TAG` file with the standard signature, which is handy for
thumbnail or download caches. For example, for `app/data/cache`:

```bash
printf 'Signature: 8a477f597d28d172789f06886806bc55\n' > ~/stacks/app/data/cache/CACHEDIR.TAG
```

### Manual backups

```bash
stackctl backup app --stop
```

These are named `app@manual@...` and are never pruned. Delete them with `borg delete ::<archive>` (Borg) or by removing the file in `BACKUP_DIR/app/` (tar) when you no longer need them.

### Update stackctl itself

Run `./install.sh --upgrade` from the new release (it installs the script and the unit files and reloads systemd).
Your config, keys and passphrase are not touched. Check
[CHANGELOG.md](../CHANGELOG.md) first: a major version changes the config keys, paths or unit names.

### Test a real restore occasionally

The self-test proves Borg works, but it's worth restoring a real stack into a scratch folder with
`stackctl extract` every few months and checking the data opens.

## Idempotency

- `update`, `nightly`, `adopt`, `init`, `hold`, `release` and `test` are all safe to re-run. `update` does nothing when nothing has changed, and `init` skips creating a repo that already exists.
- `restore` is not idempotent by nature: each run sets the current folder aside and restores again.
- `backup` creates a new archive each time it runs.
- The ntfy commands report that the user or access rule already exists if repeated.
- `install.sh` is safe to re-run: it keeps an existing config unless you choose to redo it.
