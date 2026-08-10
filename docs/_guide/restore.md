---
title: Restore
description: Restore database and Active Storage backups onto your local machine or back into production.
nav_order: 4
---

Use `restore local` to inspect production data safely on your machine, and `restore production` only for deliberate incident recovery.

`kamal-backup` has two restore destinations:

- `restore local`: run on your machine, restore into your local database and explicitly configured local file paths
- `restore production`: run on production infrastructure, restore back into the live production database and configured production file paths

That distinction is strict. `local` means your machine. `production` means the production-side accessory context.

## `restore local`

This is the fast way to pull a production backup down into local development.

When you pass `-d` or `-c`, `kamal-backup` uses `config/kamal-backup.yml` as the production source of truth for:

- `app`
- the first configured database adapter
- `restic.repository`
- production file paths as local restore source paths

For a normal Rails app, Rails conventions provide:

- the development database in `config/database.yml`
- `tmp/kamal-backup` as the local drill state directory

File paths are never inferred. If production has configured `paths`, create `config/kamal-backup.local.yml` and list the corresponding local targets in the same order:

```yaml
paths:
  - storage
```
{: data-title="config/kamal-backup.local.yml"}

If production has no configured paths, the command restores only the database.

You still provide the local secrets yourself in env:

- `RESTIC_PASSWORD`
- the database password env vars declared in your local config, or `PGPASSWORD`/`MYSQL_PWD` when using env-only settings

And you need the `restic` binary installed locally and available on `PATH`.

Example:

```sh
bundle exec kamal-backup -d production restore local latest
```

Without `-d` or `-c`, `restore local` reads from the local Rails app and env.

What it does:

- restores the latest database backup into your current local database
- when paths are configured, restores the latest file snapshot into a temporary staging directory
- replaces the explicitly configured local paths with the restored copy

You can also configure local database and state targets in `config/kamal-backup.local.yml`:

```yaml
databases:
  - name: app
    adapter: postgres
    url: postgres://localhost/chatwithwork_development
paths:
  - storage
state:
  path: tmp/kamal-backup
```
{: data-title="config/kamal-backup.local.yml"}

If the production file paths differ from your local file paths and you are not using `-d` or `-c`, set `restore_from` in the local config.

`restore local` refuses to run when `RAILS_ENV`, `RACK_ENV`, `APP_ENV`, or `KAMAL_ENVIRONMENT` is set to `production`.

## `restore production`

This is the emergency path: restore back into the live production database and explicitly configured production file paths.

From your app checkout:

```sh
bundle exec kamal-backup -d production restore production latest
```

That command prompts locally, then shells out through Kamal to the backup accessory and runs:

```sh
kamal-backup restore production latest --confirm-production-restore
```

If you are already inside the accessory container, you can run the command directly there too.

This path uses:

- the accessory's current configured databases
- the accessory's current paths
- the same restic repository the scheduled backups use

The storage volume must be mounted read-write for a production file restore. The restore replaces the contents of
an existing mounted directory while preserving the mount point itself, then restores databases. Restoring files
first prevents a failed or read-only file restore from leaving the database at a different point in time.

This is intentionally not a quiet operation. `restore production` is for real incident recovery.

`restore production` does not accept `--yes` as a confirmation shortcut. Interactive use asks you to type the app name and `RESTORE PRODUCTION`. Automation must pass the explicit `--confirm-production-restore` flag.

## Prompts and safety

The safety model is:

- you must choose `local` or `production`
- destructive restores prompt for confirmation
- `restore production` requires typed confirmation, or the explicit `--confirm-production-restore` automation flag
- local restores refuse production-looking local targets

That keeps the interface close to Kamal itself: explicit command, explicit target, deliberate confirmation.
