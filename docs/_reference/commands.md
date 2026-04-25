---
title: Commands
description: Command reference for the kamal-backup executable, including Kamal-style destination selection for production-side commands.
nav_order: 1
---

## Main shape

The local gem is the operator-facing interface.

Use `-d` and `-c` the same way you use them with Kamal:

```sh
bundle exec kamal-backup -d production backup
bundle exec kamal-backup -d production evidence
bundle exec kamal-backup -c config/deploy.staging.yml -d staging check
bundle exec kamal-backup restore local latest
```

Production-side commands shell out through Kamal to the backup accessory. Local commands run on your machine.

The command surface is:

```sh
kamal-backup init
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

## Common commands

| Command | Description |
|---|---|
| `init` | Create `config/kamal-backup.yml`, then print an accessory snippet for `deploy.yml`. Create `config/kamal-backup.local.yml` only when you need to override Rails local defaults. |
| `backup` | Create one database backup and one file snapshot for the current app. With `-d` or `-c`, it runs on production infrastructure through Kamal. Remote execution requires the local gem and accessory versions to match. |
| `restore local [snapshot-or-latest]` | Restore onto your machine: current local database plus current local `BACKUP_PATHS`. Prompts before overwriting local data. With `-d` or `-c`, the source-side defaults come from the production accessory config. |
| `restore production [snapshot-or-latest]` | Restore back into the live production database and production `BACKUP_PATHS`. Prompts before overwriting production data. With `-d` or `-c`, it shells out through Kamal and requires matching local/remote versions. |
| `drill local [snapshot-or-latest]` | Restore onto your machine, optionally run `--check`, print JSON, and store the latest drill record under `KAMAL_BACKUP_STATE_DIR`. With `-d` or `-c`, the source-side defaults come from the production accessory config. |
| `drill production [snapshot-or-latest]` | Restore into scratch targets on production infrastructure, optionally run `--check`, print JSON, and store the latest drill record. Use `--database` for PostgreSQL/MySQL or `--sqlite-path` for SQLite. Remote execution requires matching local/remote versions. |
| `list` | Show restic snapshots for the configured app tags. With `-d` or `-c`, it runs through Kamal against the backup accessory and requires matching local/remote versions. |
| `check` | Run `restic check` and store the latest result under `KAMAL_BACKUP_STATE_DIR`. With `-d` or `-c`, it runs through Kamal against the backup accessory and requires matching local/remote versions. |
| `evidence` | Print redacted JSON for ops records or security reviews, including latest snapshots, latest check result, latest drill result, retention, and tool versions. With `-d` or `-c`, it runs through Kamal against the backup accessory and requires matching local/remote versions. |
| `schedule` | Run the foreground scheduler loop. Normally the accessory container runs this by default, but you can also invoke it explicitly through `-d` or `-c` when debugging. Remote execution requires matching local/remote versions. |
| `version` | Print the running `kamal-backup` version. `--version` and `-v` print the local gem version. `version` with `-d` or `-c` prints both the local gem version and the production accessory version, plus sync status. |

## Notes

- `local` always means your machine, not "whatever environment the command is running in."
- `restore local` and `drill local` require `restic` on your machine.
- `production` means the production-side accessory context.
- Remote-backed commands fail fast when the local gem version and accessory version drift. The fix is `bin/kamal accessory reboot backup`.
- `drill production` restores into scratch targets on production infrastructure. It does not touch the live production database.
- Destructive restore commands prompt by default. Add `--yes` for automation.
