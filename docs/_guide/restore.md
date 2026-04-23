---
title: Restore
description: Restore backups onto your local machine or back into production, with clear expectations about what each command touches.
nav_order: 4
---

`restore` means "put data back."

`kamal-backup` has two restore destinations:

- `restore local`: run on your machine, restore into your local database and local file paths
- `restore production`: run from the backup accessory, restore back into the live production database and production file paths

That distinction matters. `local` means your machine. `production` means the production-side accessory and live production targets.

## `restore local`

This is the fast way to pull a production backup down into local development.

```sh
bundle exec exe/kamal-backup restore local latest
```

What it needs on your machine:

- access to the restic repository through `RESTIC_REPOSITORY` and `RESTIC_PASSWORD`
- local database settings through `DATABASE_URL` or `SQLITE_DATABASE_PATH`
- local file targets through `BACKUP_PATHS`

What it does:

- restores the latest database backup into your current local database
- restores the latest file snapshot into a temporary staging directory
- replaces the local `BACKUP_PATHS` with the restored copy

If the production file paths differ from your local file paths, set `LOCAL_RESTORE_SOURCE_PATHS` to the production path list and leave `BACKUP_PATHS` pointed at your local targets.

Example:

```sh
export APP_NAME=chatwithwork
export DATABASE_ADAPTER=postgres
export DATABASE_URL=postgres://localhost/chatwithwork_development
export BACKUP_PATHS=storage
export LOCAL_RESTORE_SOURCE_PATHS=/data/storage
export RESTIC_REPOSITORY=s3:https://s3.example.com/chatwithwork-backups
export RESTIC_PASSWORD=change-me

bundle exec exe/kamal-backup restore local latest
```

`restore local` refuses to run when `RAILS_ENV`, `RACK_ENV`, `APP_ENV`, or `KAMAL_ENVIRONMENT` is set to `production` unless you explicitly override that with `KAMAL_BACKUP_ALLOW_PRODUCTION_RESTORE=true`.

## `restore production`

This is the emergency path: restore back into the live production database and live production file paths.

Run it from the backup accessory:

```sh
bin/kamal accessory exec backup "kamal-backup restore production latest"
```

The command prompts for confirmation. For a scripted run, add `--yes`:

```sh
bin/kamal accessory exec backup "kamal-backup restore production latest --yes"
```

What it uses:

- the accessory's current `DATABASE_URL` or `SQLITE_DATABASE_PATH`
- the accessory's current `BACKUP_PATHS`
- the same restic repository the scheduled backups use

This is intentionally not a quiet operation. `restore production` is for real incident recovery.

## Prompts and Safety

`restore` no longer depends on a separate "allow restore" environment flag.

Instead, the safety model is:

- you must choose `local` or `production`
- destructive restores prompt for confirmation
- automation must pass `--yes`
- local restores refuse production-looking local targets unless you explicitly override them

That keeps the interface closer to Kamal itself: explicit command, explicit target, deliberate confirmation.
