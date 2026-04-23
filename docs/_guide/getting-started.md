---
title: Getting Started
description: Add kamal-backup as a Kamal accessory, choose a restic repository, and run the first backup.
nav_order: 1
---

This guide assumes:

- you already deploy the app with Kamal;
- your database is PostgreSQL, MySQL/MariaDB, or SQLite;
- any file data you want to back up is available on a mounted path such as `/data/storage`.

In normal Kamal use, there is no app-host installation step for restic. The `kamal-backup` image already includes it.

## Choose a restic repository

Before you boot the accessory, decide where the backups will live. Common choices are:

- S3-compatible object storage;
- a restic REST server you run separately;
- a filesystem path for local development.

`kamal-backup` writes to that repository through restic. It does not manage the repository service for you.

## Add the accessory

Add a backup accessory to your Kamal deploy config:

```yaml
aliases:
  backup: accessory exec backup "kamal-backup backup"
  backup-list: accessory exec backup "kamal-backup list"
  backup-check: accessory exec backup "kamal-backup check"
  backup-evidence: accessory exec backup "kamal-backup evidence"
  backup-version: accessory exec backup "kamal-backup version"
  backup-schedule: accessory exec backup "kamal-backup schedule"
  backup-logs: accessory logs backup -f

accessories:
  backup:
    image: ghcr.io/crmne/kamal-backup:latest
    host: chatwithwork.com
    env:
      clear:
        APP_NAME: chatwithwork
        DATABASE_ADAPTER: postgres
        DATABASE_URL: postgres://chatwithwork@chatwithwork-db:5432/chatwithwork_production
        BACKUP_PATHS: /data/storage
        RESTIC_REPOSITORY: s3:https://s3.example.com/chatwithwork-backups
        RESTIC_INIT_IF_MISSING: "true"
        BACKUP_SCHEDULE_SECONDS: "86400"
      secret:
        - PGPASSWORD
        - RESTIC_PASSWORD
        - AWS_ACCESS_KEY_ID
        - AWS_SECRET_ACCESS_KEY
    volumes:
      - "chatwithwork_storage:/data/storage:ro"
```

Boot it:

```sh
bin/kamal accessory boot backup
bin/kamal accessory logs backup
```

## Run the first backup

The production interface is the accessory container. The image ships the `kamal-backup` executable, so you can run one-off commands through Kamal:

```sh
bin/kamal backup
bin/kamal backup-list
bin/kamal backup-check
bin/kamal backup-evidence
bin/kamal backup-version
bin/kamal backup-schedule
bin/kamal backup-logs
```

After the first run, inspect the snapshots and evidence:

```sh
bin/kamal backup-list
bin/kamal backup-evidence
```

Recommended aliases:

| Alias | Expands to | Use |
|---|---|---|
| `bin/kamal backup` | `accessory exec backup "kamal-backup backup"` | Run one backup immediately. |
| `bin/kamal backup-list` | `accessory exec backup "kamal-backup list"` | Show restic snapshots for the configured app. |
| `bin/kamal backup-check` | `accessory exec backup "kamal-backup check"` | Run `restic check` and store the latest check result. |
| `bin/kamal backup-evidence` | `accessory exec backup "kamal-backup evidence"` | Print redacted backup evidence JSON. |
| `bin/kamal backup-version` | `accessory exec backup "kamal-backup version"` | Print the running `kamal-backup` version. |
| `bin/kamal backup-schedule` | `accessory exec backup "kamal-backup schedule"` | Run the foreground scheduler loop manually. Mostly useful for debugging. |
| `bin/kamal backup-logs` | `accessory logs backup -f` | Tail the backup accessory logs. |

Once you have a scratch restore target configured, add a drill alias too:

```yaml
aliases:
  backup-drill: accessory exec backup "kamal-backup drill production latest --database app_restore_20260423 --files /restore/files --check 'test -d /restore/files/data/storage' --yes"
```

Only add that after you have picked a real scratch database name or SQLite path and a scratch file path for drills.

Deliberate restore commands are intentionally not aliased in the default block. Use `bin/kamal accessory exec backup "kamal-backup ..."` directly when you need `restore production`, and run `restore local` from your own machine.

## What the first backup creates

Each backup run creates:

- one database backup stored through restic stdin;
- one `type:files` restic snapshot containing all configured `BACKUP_PATHS` entries.

Database dump snapshots are tagged with `kamal-backup`, `app:<name>`, `type:database`, `adapter:<adapter>`, and `run:<timestamp>`. File snapshots use `type:files`, the same run tag, and informational `path:<label>` tags for the configured paths. Restore selects by `type:files`, not by one path tag.
