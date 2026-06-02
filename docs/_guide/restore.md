---
title: Restore
description: Restore database and Active Storage backups onto your local machine or back into production.
nav_order: 4
---

Use `restore local` to inspect production data safely on your machine, and `restore production` only for deliberate incident recovery.

`kamal-backup` has two restore destinations:

- `restore local`: run on your machine, restore into your local database and local Active Storage path
- `restore production`: run on production infrastructure, restore back into the live production database and production Active Storage path

That distinction is strict. `local` means your machine. `production` means the production-side accessory context.

## `restore local`

This is the fast way to pull a production backup down into local development.

When you pass `-d` or `-c`, `kamal-backup` uses `config/kamal-backup.yml` as the production source of truth for:

- `app`
- the first configured database adapter
- `restic.repository`
- production file paths as local restore source paths

For a normal Rails app, the local targets come from Rails conventions:

- the development database in `config/database.yml`
- `storage` as the local Active Storage target
- `tmp/kamal-backup` as the local drill state directory

You still provide the local secrets yourself in env:

- `RESTIC_PASSWORD_FILE` or `RESTIC_PASSWORD`
- the database password env vars declared in your local config, or `PGPASSWORD`/`MYSQL_PWD` when using env-only settings

And you need the `restic` binary installed locally and available on `PATH`.

Example:

```sh
bundle exec kamal-backup -d production restore local latest
```

Without `-d` or `-c`, `restore local` reads from the local Rails app and env.

What it does:

- restores the latest database backup into your current local database
- restores the latest Active Storage file snapshot into a temporary staging directory
- replaces the local backup paths with the restored copy

If your local targets are nonstandard, create `config/kamal-backup.local.yml`:

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

This is the emergency path: restore back into the live production database and live production Active Storage path.

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

This is intentionally not a quiet operation. `restore production` is for real incident recovery.

`restore production` does not accept `--yes` as a confirmation shortcut. Interactive use asks you to type the app name and `RESTORE PRODUCTION`. Automation must pass the explicit `--confirm-production-restore` flag.

## Prompts and safety

The safety model is:

- you must choose `local` or `production`
- destructive restores prompt for confirmation
- `restore production` requires typed confirmation, or the explicit `--confirm-production-restore` automation flag
- local restores refuse production-looking local targets

That keeps the interface close to Kamal itself: explicit command, explicit target, deliberate confirmation.
