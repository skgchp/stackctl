# stackctl guide: setup and day-to-day use

`stackctl` deploys your Docker Compose stacks from a GitHub repo and backs them up to a Borg repo
(a Hetzner Storage Box). It runs as the Docker user against rootless Docker, from systemd user timers.
See the [README](../README.md) for the command reference.

On a server built with [debian-server-scripts](https://github.com/skgchp/debian-server-scripts), its
stage 85 does the install and key steps below for you: follow that repo's `docs/STACKCTL.md` for
those, and come back here for everything else.

## How it fits together

1. **Renovate** (the Mend Renovate GitHub App) opens a pull request in your stacks repo when a newer image is available.
2. **Trivy scan** (GitHub Actions) comments on the pull request with what the update fixes and introduces.
3. **Minor, patch and digest updates merge themselves** overnight once the Trivy check passes and the release is at least
   three days old (see `renovate.json` in the stacks repo). **Major updates never do**: you review and merge them. Postgres
   majors are not offered at all (they need a dump and restore), and Nextcloud majors arrive one PR per major, labelled
   `manual-migration`. Either way, anything on `main` goes live within the hour, so a direct push is as live as a merge.
4. **stackctl update** runs hourly on the VPS. For each stack whose folder changed, it:
   - pre-pulls the new images while the stack keeps running
   - stops the stack and backs it up to Borg, so the backup is consistent
   - writes out the new files, then runs `docker compose pull` and `docker compose up -d`
5. **stackctl nightly** backs up every stack each night, live unless the stack has a `.backup-stop` file, then prunes old archives.
6. You get an ntfy notification for updates and for anything that goes wrong.

The stacks repo is separate from this one: one top-level folder per stack, each with a `compose.yaml`
(or `compose.yml`, `docker-compose.yaml`, `docker-compose.yml`). Add `data/` and `.env` to its `.gitignore`.
Renovate and Trivy configuration (`renovate.json`, `.github/workflows/trivy-scan.yml`,
`.github/scripts/trivy-pr-scan.sh`) lives in that repo, not here. See Part 1.

### Why the VPS keeps a mirror rather than a working copy

`stackctl` keeps a private copy of the repo in `~/.local/state/stackctl/repo.git` and writes each stack's files individually, instead of running `git pull` in the stacks folder. This lets one stack sit on an older version (after a restore, or while on hold) while the others keep updating. Your data and `.env` files are never touched, because only files tracked in Git are written or removed.

### What happens when things go wrong

| Situation | What stackctl does |
|---|---|
| GitHub unreachable | Skips the run and notifies once, then again when it recovers |
| Pre-update backup fails | Restarts the stack unchanged, notifies, retries next hour |
| A tracked file was edited on the server | Skips that stack, puts it on hold, notifies with the file list |
| New version fails to start | Puts the stack on hold and notifies urgently. The pre-update backup is ready for `stackctl restore` |
| A stack is removed from the repo | Leaves it running and notifies you to take it down by hand |
| Nightly backup or prune fails | Notifies with the failed stacks |

A held stack is never touched by updates until you run `stackctl release <stack>`, so a broken update can't be retried hourly and push your good backups out of retention.

### What is and is not backed up

Borg archives each stack's **folder** (`~/stacks/<stack>`), including bind-mounted data under it.

> **Named Docker volumes are not backed up.** They live in `~/.local/share/docker/volumes`, outside the
> stack folder, so a restore would bring the stack back with empty volumes. Use bind mounts under the
> stack folder (`./data:/var/lib/...`) for anything you cannot lose.

## What you set up

| Step | Where |
|---|---|
| Add a read-only deploy key to the stacks repo | Part 3 |
| Create the Hetzner sub-account and install the Storage Box key | Part 4 |
| Create the ntfy user and token | Part 5 |
| Run `stackctl init`; copy the key export and passphrase off the server | Part 6 |
| Run `stackctl adopt` on a server with existing stacks | Part 7 |
| Enable the timers and run `stackctl test` | Parts 8 and 9 |

Everything below runs as the Docker user (`dockeruser` in debian-server-scripts), not root, unless it says otherwise.

## Part 1: GitHub (the stacks repo)

1. Create the private repo and push your stack folders, plus `renovate.json`, `.github/workflows/trivy-scan.yml` and `.github/scripts/trivy-pr-scan.sh`.
2. Check **Settings > Actions > General** allows actions to run. GitHub-hosted runners on a private repo come out of your free Actions minutes, which a scan every so often won't get near.
3. Install the Mend Renovate app from `github.com/apps/renovate` and choose **Only select repositories**. With `renovate.json` already in the repo, Renovate starts without an onboarding pull request. Your stacks repo's `renovate.json` can automerge minor, patch and digest updates (after Trivy and a release-age delay) and leave majors to you, which is how the live repo is set up. For approval on every update, drop the automerge rule.

Validate any change to `renovate.json` before merging it. A single invalid rule makes Renovate pause **all** pull requests: `npx --yes --package renovate -- renovate-config-validator renovate.json`.

On GitHub Free, private repos can't enforce branch protection. That's fine for a one-person repo, but remember that a direct push to `main` goes live within the hour just like a merge. With GitHub Pro you can require pull requests for `main`.

## Part 2: Install and configure

Follow [Manual install](../README.md#manual-install): put the binary at `/usr/local/bin/stackctl`, copy
`stackctl.conf.example` to `~/.config/stackctl/stackctl.conf` (mode 0600) and set at least:

```bash
GIT_REMOTE="git@github.com:YOUR-USER/YOUR-REPO.git"
BORG_REPO="ssh://u123456-sub1@u123456.your-storagebox.de:23/./backups/myhost"
```

Generate the two keys and the Borg passphrase, which must exist before the later parts:

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/github-deploy
ssh-keygen -t ed25519 -N '' -f ~/.ssh/storagebox
(umask 077 && head -c 32 /dev/urandom | base64 > ~/.config/stackctl/borg-passphrase)
cat github_known_hosts >> ~/.ssh/known_hosts      # GitHub's pinned host keys, from this repo
```

Do not enable the timers yet. Every option is documented in `stackctl.conf.example`.

## Part 3: GitHub deploy key

In the stacks repo, go to **Settings > Deploy keys > Add deploy key**, paste the `github-deploy` public key
(`cat ~/.ssh/github-deploy.pub`), and leave **Allow write access** unticked.

Test it:

```bash
ssh -i ~/.ssh/github-deploy -o IdentitiesOnly=yes -T git@github.com
```

It should greet you with the repo name and say shell access isn't provided. `github_known_hosts` already pinned
GitHub's host keys, so there is no trust-on-first-use prompt. They come from GitHub's published list
(`https://api.github.com/meta`).

## Part 4: Hetzner Storage Box

In the Hetzner console:

1. Create a **sub-account** for this VPS with its own base directory, for example `vps-borg`.
2. Enable **SSH support** for the sub-account, and **external reachability** if the VPS is outside Hetzner.
3. On the main Storage Box, turn on **automatic snapshots** (for example daily, keeping 7). The VPS can't delete these, so they protect you if the server is ever compromised.

Note the sub-account's username, which looks like `u123456-sub1`. Sub-accounts connect to the **main
account's hostname** (`u123456.your-storagebox.de`), with the sub-account username. Borg needs SSH on **port 23**.
Then install the `storagebox` key on it.
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

## Part 5: ntfy token

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
notifications once Traefik and ntfy are both up; until then alerts (including "Cannot reach GitHub") can't
be delivered. Consider also watching the server from somewhere else, since a notification about the server
dying can't be sent through the server.

## Part 6: Create the Borg repo

```bash
stackctl init
```

**Before going further,** copy the exported key file and the passphrase into your password manager,
then delete the export. Without both, the backups can't be restored if the VPS is lost:

```bash
cat ~/.local/state/stackctl/borg-key-export.txt
cat ~/.config/stackctl/borg-passphrase
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

Files copied as the plain Docker user are owned by root **inside** the containers. Containers that run as a
non-root user then fail with "not writable" or `Operation not permitted`. Postgres and apps that start as root
cope; images like Forgejo's rootless build (uid 1000) do not. Fix ownership **inside rootless Docker's
user namespace**, so it maps to the right sub-UID:

```bash
nsenter -U --preserve-credentials -t "$(cat /run/user/$(id -u)/docker.pid)" -- \
  chown -R 1000:1000 ~/stacks/forgejo/appdata/forgejo
```

Use the uid the image runs as (`docker run --rm --entrypoint id <image>`). When you can, copy with ownership
preserved instead (rsync as root inside the namespace).

The stacks folder must contain your stacks at `~/stacks/<stack>` (the same names as in the repo). If they
live elsewhere, copy them there with `cp -a`, keeping the originals until everything works.

`STACKS_DIR` is `~/stacks` by default. Put your stacks there, then record which ones
already match the repo, so the first hourly run doesn't restart them all:

```bash
stackctl adopt
```

Any stack listed as different from the repo will be backed up and updated on the first run. If you'd
rather it wasn't, commit the server's version of those files to GitHub first and run `adopt` again.
If the stacks folder is currently a Git clone, its `.git` folder is no longer used and can be removed
once everything works.

## Part 8: Start the timers

```bash
systemctl --user enable --now stackctl-nightly.timer stackctl-update.timer
systemctl --user enable --now stackctl-data.timer      # only if DATA_DIRS is set
```

Skip `stackctl-update.timer` to keep backups but deploy by hand with `stackctl update`.

## Part 9: Test

```bash
stackctl test
```

This checks the tools, rootless Docker and its user namespace, lingering, both timers, GitHub access,
the Borg repo, a full backup and restore round trip, and sends a test notification. It finishes with a
dry run of what the next update would do. Add `--no-notify` to skip the notification.

Run it again after any change to the server, keys or Storage Box.

## Day to day

### See what's going on

```bash
stackctl status
journalctl --user -u stackctl-update.service -n 50
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
it, and puts it **on hold**. To keep it on the restored version, revert the update in GitHub and then release it:

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

These are named `app@manual@...` and are never pruned. Delete them with `borg delete` when you no longer need them.

### Update stackctl itself

Install the new `stackctl` over `/usr/local/bin/stackctl`, and the unit files if they changed (then
`systemctl --user daemon-reload`). Your config, keys and passphrase are not touched. Check
[CHANGELOG.md](../CHANGELOG.md) first: a major version changes the config keys, paths or unit names.

### Test a real restore occasionally

The self-test proves Borg works, but it's worth restoring a real stack into a scratch folder with
`stackctl extract` every few months and checking the data opens.

## Idempotency

- `update`, `nightly`, `adopt`, `init`, `hold`, `release` and `test` are all safe to re-run. `update` does nothing when nothing has changed, and `init` skips creating a repo that already exists.
- `restore` is not idempotent by nature: each run sets the current folder aside and restores again.
- `backup` creates a new archive each time it runs.
- The ntfy commands report that the user or access rule already exists if repeated.
