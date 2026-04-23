---
title: Restore Drills
description: Practice restores on your laptop or on production infrastructure, run checks, and keep evidence a reviewer can understand.
nav_order: 5
---

`drill` means "restore, check, and record the result."

`kamal-backup` has two drill destinations:

- `drill local`: restore onto your machine, run an optional check, and write a drill record
- `drill production`: restore into scratch targets on production infrastructure, run an optional check, and write a drill record

Every drill writes the latest result to `KAMAL_BACKUP_STATE_DIR/last_restore_drill.json`. `kamal-backup evidence` includes that latest drill record.

## `drill local`

For a small Rails app, this is often the fastest proof that the backup is real:

```sh
bundle exec exe/kamal-backup drill local latest --check "bin/rails runner 'puts User.count'"
```

`drill local` uses:

- your local `DATABASE_URL` or `SQLITE_DATABASE_PATH`
- your local `BACKUP_PATHS`
- the configured restic repository

It does the same restore work as `restore local`, then runs the optional check command and stores the result.

If the production file paths differ from local ones, set `LOCAL_RESTORE_SOURCE_PATHS` to the production path list and keep `BACKUP_PATHS` pointed at the local paths.

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
bin/kamal accessory exec backup \
  "kamal-backup drill production latest --database app_restore_20260423 --files /restore/files --check 'test -d /restore/files/data/storage' --yes"
```

MySQL/MariaDB example:

```sh
bin/kamal accessory exec backup \
  "kamal-backup drill production latest --database app_restore_20260423 --files /restore/files --check 'test -d /restore/files/data/storage' --yes"
```

SQLite example:

```sh
bin/kamal accessory exec backup \
  "kamal-backup drill production latest --sqlite-path /restore/db/restore.sqlite3 --files /restore/files --check 'test -f /restore/db/restore.sqlite3' --yes"
```

For PostgreSQL and MySQL, if you omit `--database` in an interactive session, `kamal-backup` will ask for the scratch database name. Non-interactive runs should pass it explicitly.

## Scheduling

Once you have settled on a scratch database name or SQLite path, it is reasonable to add a Kamal alias:

```yaml
aliases:
  backup-drill: accessory exec backup "kamal-backup drill production latest --database app_restore_20260423 --files /restore/files --check 'test -d /restore/files/data/storage' --yes"
```

That alias belongs in `deploy.yml` only after the scratch targets are real.

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

For many reviews, that is the useful sequence:

1. scheduled backups
2. repository checks
3. a real restore drill
4. `kamal-backup evidence`

That is much stronger than saying "the backup job is green."
