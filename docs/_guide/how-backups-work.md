---
title: How Backups Work
description: Why restic is the backend, what scheduled backup runs do, and how restore drills and evidence fit together.
nav_order: 2
---

## The model

`kamal-backup` runs as a Kamal accessory. In normal production use, the accessory runs `kamal-backup schedule`, wakes up on the configured interval, and creates one database snapshot plus one Active Storage file snapshot per run.

The goal is simple: scheduled backups for Rails apps deployed with Kamal that are easy to restore, easy to drill, and easy to explain in a security review.

## Why restic

`kamal-backup` uses [restic](https://restic.net/) as the backup engine and repository format.

Restic is the right backend here because it provides:

- encrypted repositories by default;
- snapshots with tags, so one backup run can tie the database and Active Storage files together;
- deduplication across repeated backup runs;
- retention and prune commands;
- repository health checks;
- S3-compatible object storage, restic REST server, and filesystem repository support.

That lets `kamal-backup` stay Rails- and Kamal-focused instead of inventing a custom backup format.

In normal Kamal use, you do not install restic on the Rails app host. The backup accessory image already contains the `restic` binary. You point that accessory at a restic repository, usually:

- S3-compatible object storage;
- a restic REST server;
- a filesystem path for local development.

If you choose a `rest:` repository, `kamal-backup` does not install or run that server for you. It is a separate service you operate yourself.

## What happens during a backup

When a backup run starts, `kamal-backup` does five things:

1. It validates the app name, restic repository, database settings, and `backup_paths`.
2. It creates a database backup using the database-native export tool:
   PostgreSQL uses `pg_dump`, MySQL/MariaDB use `mariadb-dump` or `mysqldump`, and SQLite uses `sqlite3 .backup`.
3. It streams that database backup into restic and tags it with `type:database`, `adapter:<adapter>`, and `run:<timestamp>`.
4. It runs one `restic backup` for the configured Active Storage paths in `backup_paths` and tags that snapshot with `type:files` plus the same `run:<timestamp>`.
5. It optionally prunes old snapshots and runs the same repository verification as `kamal-backup check`, depending on configuration.

The result is one database snapshot and one Active Storage file snapshot per run.

## What gets backed up

`kamal-backup` is built for two data surfaces:

- your app database: PostgreSQL, MySQL/MariaDB, or SQLite;
- file-backed Active Storage files that live on mounted volumes.

If your Rails app already stores Active Storage blobs directly in S3, there may be no mounted Active Storage path for `backup_paths` to capture. In that case, `kamal-backup` still covers the database side, but S3 object backup and retention are a separate concern.

## What the commands mean

- `schedule`: Run the foreground scheduler loop. This is the default accessory command.
- `backup`: Create one new database snapshot and one new Active Storage file snapshot immediately.
- `restore local`: Pull the latest backup from restic onto your machine and restore it into your local development database and local Active Storage path.
- `restore production`: Restore a backup back into the production database and production Active Storage path.
- `drill local`: Run a local restore plus an optional verification command, then record the result as JSON.
- `drill production`: Restore into a scratch database and scratch Active Storage path on production infrastructure, run an optional verification command, and record the result as JSON.
- `list`: Show restic snapshots for this app so you can see recent runs and snapshot IDs.
- `check`: Verify the restic repository and store the latest result in `KAMAL_BACKUP_STATE_DIR`, which defaults to `/var/lib/kamal-backup`.
- `evidence`: Print a redacted JSON summary with current backup settings, latest snapshots, latest check result, latest drill result, and tool versions. This is meant to be attached to internal ops records or security reviews.
- `validate`: Check required backup configuration without running a backup. From an app checkout with `config/deploy.yml`, it validates the backup accessory and `config/kamal-backup.yml` before the accessory has to be running.

## Snapshot tags

Database snapshots are tagged with:

- `kamal-backup`
- `app:<name>`
- `type:database`
- `adapter:<adapter>`
- `run:<timestamp>`

Active Storage file snapshots are tagged with:

- `kamal-backup`
- `app:<name>`
- `type:files`
- `run:<timestamp>`
- `path:<label>` for each configured Active Storage path

The shared `run:<timestamp>` tag lets you correlate the database backup and the Active Storage file backup from the same run.
