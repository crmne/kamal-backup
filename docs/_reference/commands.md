---
title: Commands
description: Command reference for scheduled backups, restores, drills, checks, evidence, and Kamal-style destination selection.
nav_order: 1
---

## Main shape

The local gem is the operator-facing interface.

Use `-d` and `-c` the same way you use them with Kamal:

```sh
bundle exec kamal-backup backup
bundle exec kamal-backup evidence
bundle exec kamal-backup -c config/deploy.staging.yml -d staging check
bundle exec kamal-backup restore local latest
```

From an app checkout with the default `config/deploy.yml`, `backup`, `list`, `check`, `evidence`, `validate`, and `version` infer the backup accessory and shell out through Kamal. Use `-d` and `-c` when you need an explicit Kamal destination or config file. Local commands run on your machine.

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
kamal-backup prune
kamal-backup evidence
kamal-backup validate
kamal-backup schedule
kamal-backup version
```

Use `kamal-backup help` for the command list. Use command `--help` for task-specific options:

```sh
kamal-backup restore local --help
kamal-backup drill production --help
```

## Common commands

| Command | Description |
|---|---|
| `init` | Create `config/kamal-backup.yml` with the normal YAML-first shape, then print an accessory snippet to add to `config/deploy.yml`. It does not edit `config/deploy.yml` or create `config/kamal-backup.local.yml`. Create the local file only when you need to override Rails local defaults. |
| `backup` | Run a backup when `backup.schedule` is due, or report when the latest backup is still current. Use `--force` to create an immediate snapshot anyway. From an app checkout with `config/deploy.yml`, or with `-d`/`-c`, it runs on production infrastructure through Kamal. Remote execution requires the local gem and accessory versions to match. |
| `restore local [snapshot-or-latest]` | Restore onto your machine: current local database plus current local Active Storage path. Prompts before overwriting local data. With `-d` or `-c`, the source-side defaults come from `config/kamal-backup.yml`. |
| `restore production [snapshot-or-latest]` | Restore back into the live production database and production Active Storage path from `config/kamal-backup.yml`. Requires typed confirmation before overwriting production data. With `-d` or `-c`, it shells out through Kamal and requires matching local/remote versions. |
| `drill local [snapshot-or-latest]` | Restore onto your machine, optionally run `--check`, print JSON, and store the latest drill record under `KAMAL_BACKUP_STATE_DIR`. With `-d` or `-c`, the source-side defaults come from `config/kamal-backup.yml`. |
| `drill production [snapshot-or-latest]` | Restore into scratch targets on production infrastructure, optionally run `--check`, print JSON, and store the latest drill record. Use `--database` for PostgreSQL/MySQL or `--sqlite-path` for SQLite. Use `--files` for the scratch Active Storage target; the default is `/restore/files`. Remote execution requires matching local/remote versions. |
| `list` | Show restic snapshots for the configured app tags. From an app checkout with `config/deploy.yml`, or with `-d`/`-c`, it runs through Kamal against the backup accessory and requires matching local/remote versions. |
| `check` | Verify the restic repository and store the latest result under `KAMAL_BACKUP_STATE_DIR`. From an app checkout with `config/deploy.yml`, or with `-d`/`-c`, it runs through Kamal against the backup accessory and requires matching local/remote versions. |
| `prune` | Apply `restic.retention` with `restic forget --prune`, scoped separately for each configured database and file snapshot group. From an app checkout with `config/deploy.yml`, or with `-d`/`-c`, it runs through Kamal against the backup accessory and requires matching local/remote versions. |
| `evidence` | Print redacted JSON for ops records or security reviews, including latest snapshots, latest check result, latest drill result, retention, and tool versions. From an app checkout with `config/deploy.yml`, or with `-d`/`-c`, it runs through Kamal against the backup accessory and requires matching local/remote versions. |
| `validate` | Validate the backup configuration without running a backup. From an app checkout with `config/deploy.yml`, it validates the backup accessory and `config/kamal-backup.yml` before the accessory has to be running. Use `-d` or `-c` for an explicit Kamal context. |
| `schedule` | Run the foreground scheduler loop that performs backups every `backup.schedule`. Normally the accessory container runs this by default, but you can also invoke it explicitly through `-d` or `-c` when debugging. Remote execution requires matching local/remote versions. |
| `version` | Print the running `kamal-backup` version. `--version` and `-v` print the local gem version. From an app checkout with `config/deploy.yml`, `version` also prints the accessory version and sync status; `-d` and `-c` still work when you need an explicit Kamal context. |

## Notes

- `local` always means your machine, not "whatever environment the command is running in."
- `restore local` and `drill local` require `restic` on your machine.
- `production` means the production-side accessory context.
- `validate` is a preflight check. It cannot prove that server-only files exist, but it catches missing required accessory settings and required Kamal secrets that resolve to empty values before boot.
- Remote-backed commands fail fast when the local gem version and accessory version drift. The fix is `bin/kamal accessory reboot backup`.
- `drill production` restores into scratch targets on production infrastructure. It does not touch the live production database.
- Destructive restore commands prompt by default. Add `--yes` for local restores and drills in automation. `restore production` deliberately ignores `--yes`; use `--confirm-production-restore` only for deliberate production restore automation.
