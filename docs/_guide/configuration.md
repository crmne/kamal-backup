---
title: Configuration
description: Required environment, restic repository choices, database settings, mounted file paths, retention, and scheduler flags.
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

## Core environment

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

## Local restore settings

`restore local` and `drill local` use the same core environment as backups:

- `RESTIC_REPOSITORY`
- `RESTIC_PASSWORD`
- `DATABASE_URL` or `SQLITE_DATABASE_PATH`
- `BACKUP_PATHS`

If the production file paths differ from the local ones, add:

```sh
LOCAL_RESTORE_SOURCE_PATHS=/data/storage
```

That tells `kamal-backup` which paths to look for inside the restored file snapshot before replacing your local `BACKUP_PATHS`.

Rare override:

```sh
KAMAL_BACKUP_ALLOW_PRODUCTION_RESTORE=true
```

That bypasses the guard that refuses production-looking local targets.
