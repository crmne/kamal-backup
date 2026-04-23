---
title: Configuration
description: Required environment, optional local config files, restic repository choices, database settings, mounted file paths, retention, and scheduler flags.
nav_order: 3
---

## Restic in normal Kamal use

`kamal-backup` uses restic under the hood.

In the normal Kamal setup, restic runs inside the backup accessory container. You do not install restic on the Rails app host. You only configure a restic repository for the accessory to use.

Repository examples:

```sh
RESTIC_REPOSITORY=s3:https://s3.example.com/chatwithwork-backups
RESTIC_REPOSITORY=rest:https://backup.example.com/chatwithwork
RESTIC_REPOSITORY=/var/backups/chatwithwork
```

If you use a `rest:` repository, the restic REST server is a separate service. `kamal-backup` talks to it, but does not install or operate it for you.

## Core accessory environment

```sh
APP_NAME=chatwithwork
DATABASE_ADAPTER=postgres
RESTIC_REPOSITORY=s3:https://s3.example.com/chatwithwork-backups
RESTIC_PASSWORD=change-me
BACKUP_PATHS=/data/storage
```

`BACKUP_PATHS` accepts colon-separated or newline-separated paths. Every configured path must exist before a backup starts.

Use `BACKUP_PATHS` for file data that lives on mounted volumes, such as file-backed Rails Active Storage.

If your app stores Active Storage blobs directly in S3, there may be no local path to include here.

## Database settings

PostgreSQL:

```sh
DATABASE_ADAPTER=postgres
DATABASE_URL=postgres://app@app-db:5432/app_production
PGPASSWORD=change-me
```

MySQL/MariaDB:

```sh
DATABASE_ADAPTER=mysql
DATABASE_URL=mysql2://app@app-mysql:3306/app_production
MYSQL_PWD=change-me
```

SQLite:

```sh
DATABASE_ADAPTER=sqlite
SQLITE_DATABASE_PATH=/data/db/production.sqlite3
```

If `DATABASE_ADAPTER` is omitted, `kamal-backup` tries to detect the adapter from `DATABASE_URL` or `SQLITE_DATABASE_PATH`.

## S3-compatible storage and secrets

`kamal-backup` passes standard restic environment through unchanged. For S3-compatible repositories, configure credentials as Kamal secrets:

```sh
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_DEFAULT_REGION=...
```

Use object storage credentials scoped to the backup bucket or prefix. They should not have access to unrelated buckets.

## Local config files

`bundle exec kamal-backup init` creates:

- `config/kamal-backup.yml`

`config/kamal-backup.yml` is the shared app-level file. Right now the main use is naming the accessory when it is not called `backup`:

```yaml
accessory: backup
```

For most Rails apps, no second file is needed. `kamal-backup` can infer local-machine targets from Rails conventions:

- the development database from `config/database.yml`
- the local files path as `storage`
- the local state directory as `tmp/kamal-backup`

If your local setup is nonstandard, create `config/kamal-backup.local.yml` and override the inferred targets there:

```yaml
database_url: postgres://localhost/chatwithwork_development
backup_paths:
  - storage
state_dir: tmp/kamal-backup
```

Environment variables still win over file values. That lets you keep non-secret defaults in the file and keep secrets in env, `direnv`, or another local secret manager.

## Local restore and drill source defaults

When you run `restore local` or `drill local` with `-d` or `-c`, `kamal-backup` reads the production-side source settings from `kamal config`:

- `APP_NAME`
- `DATABASE_ADAPTER`
- `RESTIC_REPOSITORY`
- `BACKUP_PATHS`, remapped to `LOCAL_RESTORE_SOURCE_PATHS`

That means the accessory clear env should contain the source-of-truth values for the backup repository and source file paths.

Local overrides belong in `config/kamal-backup.local.yml` only when needed:

- `DATABASE_URL` or `SQLITE_DATABASE_PATH`
- `BACKUP_PATHS`
- optional `state_dir`

And you still keep secrets in env:

- `RESTIC_PASSWORD`
- cloud credentials
- local DB passwords

If you do not pass `-d` or `-c`, you can set `RESTIC_REPOSITORY` and `LOCAL_RESTORE_SOURCE_PATHS` locally too.

## Retention and pruning

Defaults:

```sh
RESTIC_KEEP_LAST=7
RESTIC_KEEP_DAILY=7
RESTIC_KEEP_WEEKLY=4
RESTIC_KEEP_MONTHLY=6
RESTIC_KEEP_YEARLY=2
RESTIC_FORGET_AFTER_BACKUP=true
```

After a successful backup, `kamal-backup` runs `restic forget --prune` with the configured retention policy.

Set `RESTIC_FORGET_AFTER_BACKUP=false` for append-only repositories, such as a restic REST server started with `--append-only`. Retention and prune should then run from the backup server or another trusted maintenance process with delete permissions.

## Scheduler and checks

The default container command is:

```sh
kamal-backup schedule
```

Scheduler settings:

```sh
BACKUP_SCHEDULE_SECONDS=86400
BACKUP_START_DELAY_SECONDS=0
RESTIC_CHECK_AFTER_BACKUP=false
RESTIC_CHECK_READ_DATA_SUBSET=5%
```

## Rare overrides

For local safety guards, a rare override still exists:

```sh
KAMAL_BACKUP_ALLOW_PRODUCTION_RESTORE=true
```

That bypasses the guard that refuses production-looking local targets.
