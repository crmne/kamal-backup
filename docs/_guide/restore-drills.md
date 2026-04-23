---
title: Restore Drills
description: Practice restores on your laptop or on production infrastructure, run checks, and keep evidence that reads like an operations record instead of a generic backup log.
nav_order: 5
---

`drill` means "restore, check, and record the result."

`kamal-backup` has two drill destinations:

- `drill local`: restore onto your machine, run an optional check, and write a drill record
- `drill production`: restore onto production infrastructure, but into scratch targets, then run an optional check and write a drill record

Every drill writes the latest result to `KAMAL_BACKUP_STATE_DIR/last_restore_drill.json`. `kamal-backup evidence` includes that latest drill record.

## `drill local`

For a small Rails app, this is often the fastest proof that the backup is real:

```sh
bundle exec kamal-backup -d production drill local latest --check "bin/rails runner 'puts User.count'"
```

With `-d` or `-c`, `drill local` uses the production accessory config for the source side:

- `APP_NAME`
- `DATABASE_ADAPTER`
- `RESTIC_REPOSITORY`
- `LOCAL_RESTORE_SOURCE_PATHS`

And for a normal Rails app it infers the local target side from Rails:

- the development database in `config/database.yml`
- `storage` as the local files target
- `tmp/kamal-backup` as the local drill state directory

You still provide local secrets in env.

It does the same restore work as `restore local`, then runs the optional check command and stores the result. If your local targets are nonstandard, override them in `config/kamal-backup.local.yml`.

For larger apps, treat `drill local` as a convenience. The main drill should usually be `drill production`.

## `drill production`

This is the production-side drill:

- restore the database into a scratch database or scratch SQLite file
- restore files into a scratch path
- run an optional verification command
- write the JSON result for evidence

It does **not** restore into the live production database.

PostgreSQL example:

```sh
bundle exec kamal-backup -d production drill production latest \
  --database app_restore_20260423 \
  --files /restore/files \
  --check "test -d /restore/files/data/storage"
```

MySQL/MariaDB example:

```sh
bundle exec kamal-backup -d production drill production latest \
  --database app_restore_20260423 \
  --files /restore/files \
  --check "test -d /restore/files/data/storage"
```

SQLite example:

```sh
bundle exec kamal-backup -d production drill production latest \
  --sqlite-path /restore/db/restore.sqlite3 \
  --files /restore/files \
  --check "test -f /restore/db/restore.sqlite3"
```

For PostgreSQL and MySQL, if you omit `--database` in an interactive session, `kamal-backup` asks for the scratch database name. Non-interactive runs should pass it explicitly.

## Scheduling

Production drills are usually worth scheduling, but separately from ordinary backups. They have different runtime, different failure semantics, and different cleanup needs.

A typical review-friendly cadence is:

1. scheduled backups
2. regular `check`
3. a deliberate `drill production`
4. `evidence`

## What to Keep for CASA or Another Review

The drill JSON is the machine-readable record.

The human-readable story should usually say:

- when the drill ran
- who ran it
- which snapshot was restored
- whether it was a local or production-side drill
- which scratch targets were used
- which verification command ran
- whether the result looked correct

That is much stronger than saying "the backup job is green."
