---
title: Restore
description: Restore backups onto your local machine or back into production, with the same local-vs-production meaning everywhere in the CLI and docs.
nav_order: 4
---

`restore` means "put data back."

`kamal-backup` has two restore destinations:

- `restore local`: run on your machine, restore into your local database and local file paths
- `restore production`: run on production infrastructure, restore back into the live production database and production file paths

That distinction is strict. `local` means your machine. `production` means the production-side accessory context.

## `restore local`

This is the fast way to pull a production backup down into local development.

When you pass `-d` or `-c`, `kamal-backup` asks Kamal for the backup accessory config and uses that as the source of truth for:

- `APP_NAME`
- `DATABASE_ADAPTER`
- `RESTIC_REPOSITORY`
- `LOCAL_RESTORE_SOURCE_PATHS` from the accessory `BACKUP_PATHS`

For a normal Rails app, the local targets come from Rails conventions:

- the development database in `config/database.yml`
- `storage` as the local files target
- `tmp/kamal-backup` as the local drill state directory

You still provide the local secrets yourself in env:

- `RESTIC_PASSWORD`
- `POSTGRES_PASSWORD` or `MYSQL_PWD` when needed
- `RESTIC_REPOSITORY` when it is not visible through `kamal config`

Example:

```sh
bundle exec kamal-backup -d production restore local latest
```

Without `-d` or `-c`, `restore local` reads from the local Rails app and env.

What it does:

- restores the latest database backup into your current local database
- restores the latest file snapshot into a temporary staging directory
- replaces the local `BACKUP_PATHS` with the restored copy

If your local targets are nonstandard, create `config/kamal-backup.local.yml`:

```yaml
database_url: postgres://localhost/chatwithwork_development
backup_paths:
  - storage
state_dir: tmp/kamal-backup
```

If the production file paths differ from your local file paths and you are not using `-d` or `-c`, set `LOCAL_RESTORE_SOURCE_PATHS` yourself.

`restore local` refuses to run when `RAILS_ENV`, `RACK_ENV`, `APP_ENV`, or `KAMAL_ENVIRONMENT` is set to `production` unless you explicitly override that guard.

## `restore production`

This is the emergency path: restore back into the live production database and live production file paths.

From your app checkout:

```sh
bundle exec kamal-backup -d production restore production latest
```

That command prompts locally, then shells out through Kamal to the backup accessory and runs:

```sh
kamal-backup restore production latest --yes
```

If you are already inside the accessory container, you can run the command directly there too.

This path uses:

- the accessory's current `DATABASE_URL` or `SQLITE_DATABASE_PATH`
- the accessory's current `BACKUP_PATHS`
- the same restic repository the scheduled backups use

This is intentionally not a quiet operation. `restore production` is for real incident recovery.

## Prompts and Safety

The safety model is:

- you must choose `local` or `production`
- destructive restores prompt for confirmation
- automation must pass `--yes`
- local restores refuse production-looking local targets unless you explicitly override them

That keeps the interface close to Kamal itself: explicit command, explicit target, deliberate confirmation.
