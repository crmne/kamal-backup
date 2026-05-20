---
title: Restore Drills
description: Practice Rails restores on your laptop or production infrastructure, run checks, and keep evidence for security reviews like CASA.
nav_order: 5
---

`drill` means "restore, check, and record the result."

Scheduled backups answer "did a backup run?" Restore drills answer the more important question: "can this Rails app actually come back from that backup?"

`kamal-backup` has two drill destinations:

- `drill local`: restore onto your machine, run an optional check, and write a drill record
- `drill production`: restore onto production infrastructure, but into scratch targets, then run an optional check and write a drill record

Every drill writes the latest result to `KAMAL_BACKUP_STATE_DIR/last_restore_drill.json`. `kamal-backup evidence` includes that latest drill record. In the accessory container, mount `/var/lib/kamal-backup` as a persistent volume if you want that record to survive accessory replacement.

## `drill local`

For a small Rails app, this is often the fastest proof that the backup is real:

```sh
bundle exec kamal-backup -d production drill local latest --check "bin/rails runner 'puts User.count'"
```

This runs on your machine, so it also requires a local `restic` install on `PATH`.

With `-d` or `-c`, `drill local` uses `config/kamal-backup.yml` for the source side:

- `app_name`
- `database_adapter`
- `restic_repository`
- source paths from production `backup_paths`

And for a normal Rails app it infers the local target side from Rails:

- the development database in `config/database.yml`
- `storage` as the local Active Storage target
- `tmp/kamal-backup` as the local drill state directory

You still provide local secrets in env.

It does the same restore work as `restore local`, then runs the optional check command and stores the result. If your local targets are nonstandard, override them in `config/kamal-backup.local.yml`.

For larger apps, treat `drill local` as a convenience. The main drill should usually be `drill production`.

## `drill production`

This is the production-side drill:

- restore the database into a scratch database or scratch SQLite file
- restore Active Storage files into a scratch path
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

## What to keep for a security review

The drill JSON is the machine-readable record.

The human-readable story should usually say:

- when the drill ran
- who ran it
- which snapshot was restored
- whether it was a local or production-side drill
- which scratch targets were used
- which verification command ran
- whether the result looked correct

That is much stronger than saying "we have backups."
