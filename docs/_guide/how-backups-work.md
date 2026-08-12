---
title: How Backups Work
description: Why restic is the backend, what scheduled backup runs do, and how restore drills and evidence fit together.
nav_order: 2
---

## The model

`kamal-backup` runs as a Kamal accessory. In normal production use, the accessory runs `kamal-backup schedule`, wakes up on the configured interval, and creates one snapshot per configured database plus one file snapshot for configured paths.

The goal is simple: scheduled backups for Rails apps deployed with Kamal that are easy to restore, easy to drill, and easy to explain in a security review.

## Why restic

`kamal-backup` uses [restic](https://restic.net/) as the backup engine and repository format.

Restic is the right backend here because it provides:

- encrypted repositories by default;
- snapshots with stable tags, so database and file backups can be selected independently;
- deduplication across repeated backup runs;
- retention and prune commands;
- repository health checks;
- Restic's native repository backends plus rclone remotes; the accessory includes rclone and an SSH client.

That lets `kamal-backup` stay Rails- and Kamal-focused instead of inventing a custom backup format.

In normal Kamal use, you do not install restic on the Rails app host. The backup accessory image already contains the `restic` binary. You point that accessory at a restic repository, usually:

- S3-compatible object storage;
- an SFTP server reached with a dedicated SSH key;
- any configured rclone remote;
- a restic REST server;
- a filesystem path for local development.

If you choose a `rest:` repository, `kamal-backup` does not install or run that server for you. It is a separate service you operate yourself.

## What happens during a backup

When a backup run starts, `kamal-backup` does five things:

1. It validates the app name, restic repository, database settings, and file paths.
2. It creates database backups using the database-native export tool:
   PostgreSQL uses `pg_dump`, MySQL/MariaDB use `mariadb-dump` or `mysqldump`, and SQLite uses `sqlite3 .backup`.
3. It has restic run and capture each database export, then tags the snapshot with `type:database`,
   `database:<name>`, and `adapter:<adapter>`. If the export command fails, restic does not create a snapshot.
4. When `paths` is explicitly configured, it runs one `restic backup` for those paths and tags that snapshot with `type:files`. Path-level excludes and automatic SQLite database/WAL/SHM excludes apply only to this file snapshot.
5. It optionally prunes old snapshots and runs the same repository verification as `kamal-backup check`, depending on configuration.

The result is one database snapshot per database and, when paths are configured, one file snapshot per run. No file path is inferred from Rails.

## What gets backed up

`kamal-backup` is built for two data surfaces:

- your app database: PostgreSQL, MySQL/MariaDB, or SQLite;
- file-backed Active Storage files that live on mounted volumes.

If your Rails app already stores Active Storage blobs directly in S3, there may be no mounted file path to capture. In that case, `kamal-backup` still covers the database side, but S3 object backup and retention are a separate concern.

For SQLite apps that store the database under the same mounted volume as Active Storage, the database is backed up through `sqlite3 .backup`; the raw SQLite database, WAL, and shared-memory files are excluded from the file snapshot so a full restore does not overwrite the clean SQLite restore with live raw files.

## What the commands mean

- `schedule`: Run the foreground scheduler loop. This is the default accessory command.
- `backup`: Create one new snapshot per configured database and, when paths are configured, one file snapshot immediately.
- `restore local`: Pull the latest backup from restic onto your machine and restore it into your local development database and explicitly configured local file paths.
- `restore production`: Restore a backup back into the production database and production Active Storage path.
- `drill local`: Run a local restore plus an optional verification command, then record the result as JSON.
- `drill production`: Restore into a scratch database and scratch Active Storage path on production infrastructure, run an optional verification command, and record the result as JSON.
- `list`: Show restic snapshots for this app so you can see recent runs and snapshot IDs.
- `check`: Verify the restic repository and store the latest result in `KAMAL_BACKUP_STATE_DIR`, which defaults to `/var/lib/kamal-backup`.
- `unlock`: Clear stale restic repository locks.
- `prune`: Apply the configured retention policy and remove unneeded restic data.
- `evidence`: Print a redacted JSON summary with current backup settings, latest snapshots, latest check result, latest drill result, and tool versions. This is meant to be attached to internal ops records or security reviews.
- `validate`: Check required backup configuration without running a backup. From an app checkout with `config/deploy.yml`, it validates the backup accessory and `config/kamal-backup.yml` before the accessory has to be running.

## Snapshot tags

Database snapshots are tagged with:

- `kamal-backup`
- `app:<name>`
- `type:database`
- `database:<name>`
- `adapter:<adapter>`

Active Storage file snapshots are tagged with:

- `kamal-backup`
- `app:<name>`
- `type:files`
- `path:<label>` for each configured Active Storage path

Restic records each snapshot's time, so backup timestamps come from the repository metadata rather than a per-run tag.
