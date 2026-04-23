---
title: Commands
description: Command reference for the kamal-backup executable and the most common Kamal alias flows.
nav_order: 1
---

## CLI

Production-side commands normally run inside the backup accessory:

```sh
bin/kamal accessory exec backup "kamal-backup evidence"
```

With the recommended aliases from the getting-started guide, the same command becomes:

```sh
bin/kamal backup-evidence
```

Recommended Kamal aliases:

```yaml
aliases:
  backup: accessory exec backup "kamal-backup backup"
  backup-list: accessory exec backup "kamal-backup list"
  backup-check: accessory exec backup "kamal-backup check"
  backup-evidence: accessory exec backup "kamal-backup evidence"
  backup-version: accessory exec backup "kamal-backup version"
  backup-schedule: accessory exec backup "kamal-backup schedule"
  backup-logs: accessory logs backup -f
```

Optional drill alias after you have chosen scratch targets:

```yaml
aliases:
  backup-drill: accessory exec backup "kamal-backup drill production latest --database app_restore_20260423 --files /restore/files --check 'test -d /restore/files/data/storage' --yes"
```

The operator-facing command surface is:

```sh
kamal-backup backup
kamal-backup restore local [snapshot-or-latest]
kamal-backup restore production [snapshot-or-latest]
kamal-backup drill local [snapshot-or-latest]
kamal-backup drill production [snapshot-or-latest]
kamal-backup list
kamal-backup check
kamal-backup evidence
kamal-backup schedule
kamal-backup version
```

Use `kamal-backup help`, `kamal-backup help restore`, or `kamal-backup help drill` for task-specific usage.

## Commands

| Command | Description |
|---|---|
| `backup` | Create one database backup and one file snapshot for the current app. It runs `forget --prune` afterward unless `RESTIC_FORGET_AFTER_BACKUP=false`. |
| `restore local [snapshot-or-latest]` | Restore onto your machine: current local database plus current local `BACKUP_PATHS`. Prompts before overwriting local data. |
| `restore production [snapshot-or-latest]` | Restore back into the live production database and production `BACKUP_PATHS`. Prompts before overwriting production data. |
| `drill local [snapshot-or-latest]` | Restore onto your machine, optionally run `--check`, print JSON, and store the latest drill record under `KAMAL_BACKUP_STATE_DIR`. |
| `drill production [snapshot-or-latest]` | Restore into scratch targets on production infrastructure, optionally run `--check`, print JSON, and store the latest drill record. Use `--database` for PostgreSQL/MySQL or `--sqlite-path` for SQLite. |
| `list` | Show restic snapshots for the configured app tags. |
| `check` | Run `restic check` and store the latest result under `KAMAL_BACKUP_STATE_DIR`. |
| `evidence` | Print redacted JSON you can attach to ops records or security reviews, including latest snapshots, latest check result, latest drill result, retention, and tool versions. |
| `schedule` | Run the foreground scheduler loop used by the Docker image default command. |
| `version` | Print the running `kamal-backup` version. `--version` and `-v` do the same. |

## Notes

- `local` always means your machine, not "whatever environment the command is running in."
- `production` means the production-side accessory context.
- `drill production` restores into scratch targets on production infrastructure. It does not touch the live production database.
- Destructive restore commands prompt by default. Add `--yes` for automation.
