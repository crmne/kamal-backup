# kamal-backup

`kamal-backup` is a backup accessory for Kamal and Rails apps. It backs up PostgreSQL, MySQL/MariaDB, or SQLite, plus Active Storage and other app files that live on mounted volumes, into an encrypted restic repository.

It is built for the common self-hosted Rails setup where:

- the database lives in PostgreSQL, MySQL/MariaDB, or SQLite;
- file data lives on a mounted volume;
- you want restore drills and evidence for CASA or another security review.

If your app already stores Active Storage blobs directly in S3, there may be no local file path for `BACKUP_PATHS` to capture. In that case, `kamal-backup` still covers the database side, but object-storage backups are a separate concern.

## What Restic Does Here

`kamal-backup` uses [restic](https://restic.net/) as the backup engine and repository format.

In the normal Kamal setup, you do not install restic on the Rails app host. The backup accessory image already includes it. You only need to point the accessory at a restic repository, usually:

- S3-compatible object storage;
- a restic REST server;
- a filesystem path for local development.

If you choose a `rest:` repository, `kamal-backup` does not install or operate that server for you. It is a separate service.

## What It Backs Up

Each run backs up two data surfaces:

1. the app database, using `pg_dump`, `mariadb-dump` or `mysqldump`, or `sqlite3 .backup`;
2. mounted app files such as file-backed Rails Active Storage.

The result is one database snapshot and one file snapshot per run.

## Quick Start With Kamal

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

Run the first backup:

```sh
bin/kamal backup
bin/kamal backup-list
bin/kamal backup-evidence
```

Alias reference:

| Alias | Expands to | Use |
|---|---|---|
| `bin/kamal backup` | `accessory exec backup "kamal-backup backup"` | Run one backup immediately. |
| `bin/kamal backup-list` | `accessory exec backup "kamal-backup list"` | Show restic snapshots for the configured app. |
| `bin/kamal backup-check` | `accessory exec backup "kamal-backup check"` | Run `restic check` and store the latest check result. |
| `bin/kamal backup-evidence` | `accessory exec backup "kamal-backup evidence"` | Print redacted backup evidence JSON. |
| `bin/kamal backup-version` | `accessory exec backup "kamal-backup version"` | Print the running `kamal-backup` version. |
| `bin/kamal backup-schedule` | `accessory exec backup "kamal-backup schedule"` | Run the foreground scheduler loop manually. Mostly useful for debugging. |
| `bin/kamal backup-logs` | `accessory logs backup -f` | Tail the backup accessory logs. |

Once you have a scratch restore target configured, it also makes sense to add a drill alias:

```yaml
aliases:
  backup-drill: accessory exec backup "kamal-backup drill production latest --database app_restore_20260423 --files /restore/files --check 'test -d /restore/files/data/storage' --yes"
```

That alias only belongs in `deploy.yml` after you have picked real scratch targets for drills.

Deliberate restore commands are intentionally not part of the default alias block. Run them directly when you need them:

```sh
bin/kamal accessory exec backup "kamal-backup restore production 19ce9f99"
```

## How a Backup Run Works

When `kamal-backup backup` runs, it does five things:

1. Validates the app name, restic repository, database settings, and `BACKUP_PATHS`.
2. Creates a database backup with the database-native export tool.
3. Streams that database backup into restic with tags such as `type:database`, `adapter:<adapter>`, and `run:<timestamp>`.
4. Runs one `restic backup` for all configured `BACKUP_PATHS`, tagged as `type:files` with the same `run:<timestamp>`.
5. Optionally runs `restic forget --prune` and `restic check`.

Database snapshots are tagged with `kamal-backup`, `app:<name>`, `type:database`, `adapter:<adapter>`, and `run:<timestamp>`.

File snapshots are tagged with `kamal-backup`, `app:<name>`, `type:files`, `run:<timestamp>`, and informational `path:<label>` tags.

That shared `run:<timestamp>` tag lets you match the database backup and the file backup from the same run.

## Commands

Commands usually run inside the production backup accessory with `bin/kamal accessory exec backup "kamal-backup <command>"`, or through Kamal aliases such as `bin/kamal backup`.

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

Use `kamal-backup help [command]` for command-specific usage and examples.

| Command | What it does |
|---|---|
| `backup` | Creates one database backup and one file snapshot for all configured `BACKUP_PATHS`. |
| `restore local [snapshot-or-latest]` | Restores the latest backup into your local development database and local `BACKUP_PATHS`. |
| `restore production [snapshot-or-latest]` | Restores the latest backup back into the live production database and production `BACKUP_PATHS`. |
| `drill local [snapshot-or-latest]` | Runs a local restore, optionally runs a verification command, and stores the latest drill result under `KAMAL_BACKUP_STATE_DIR`. |
| `drill production [snapshot-or-latest]` | Restores into scratch targets on production infrastructure, optionally runs a verification command, and stores the latest drill result. |
| `list` | Lists restic snapshots for the configured app tags. |
| `check` | Runs `restic check` and records the latest result for evidence output. |
| `evidence` | Prints redacted JSON with backup configuration, latest snapshots, latest check result, latest drill result, and tool versions. |
| `schedule` | Runs the foreground scheduler loop used by the container default command. |
| `version` | Prints the running `kamal-backup` version. `--version` and `-v` do the same. |

The default container command is:

```sh
kamal-backup schedule
```

## Configuration

Core environment:

```sh
APP_NAME=chatwithwork
DATABASE_ADAPTER=postgres
RESTIC_REPOSITORY=s3:https://s3.example.com/chatwithwork-backups
RESTIC_PASSWORD=change-me
BACKUP_PATHS=/data/storage
```

Repository examples:

```sh
RESTIC_REPOSITORY=s3:https://s3.example.com/chatwithwork-backups
RESTIC_REPOSITORY=rest:https://backup.example.com/chatwithwork
RESTIC_REPOSITORY=/var/backups/chatwithwork
```

`BACKUP_PATHS` accepts colon-separated or newline-separated paths. Every path must exist. Suspicious broad paths such as `/`, `/var`, `/etc`, and `/root` are refused unless `KAMAL_BACKUP_ALLOW_SUSPICIOUS_PATHS=true`.

Use `BACKUP_PATHS` for file data on mounted volumes, such as file-backed Active Storage.

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

For S3-compatible repositories, provide the standard restic/AWS variables as Kamal secrets:

```sh
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_DEFAULT_REGION=...
```

Retention defaults:

```sh
RESTIC_KEEP_LAST=7
RESTIC_KEEP_DAILY=7
RESTIC_KEEP_WEEKLY=4
RESTIC_KEEP_MONTHLY=6
RESTIC_KEEP_YEARLY=2
RESTIC_FORGET_AFTER_BACKUP=true
```

Set `RESTIC_FORGET_AFTER_BACKUP=false` for append-only repositories, such as a restic REST server started with `--append-only`. In that mode, run retention and prune from the backup server or another trusted maintenance process with delete permissions.

Scheduler and checks:

```sh
BACKUP_SCHEDULE_SECONDS=86400
BACKUP_START_DELAY_SECONDS=0
RESTIC_CHECK_AFTER_BACKUP=false
RESTIC_CHECK_READ_DATA_SUBSET=5%
```

## Restore

`restore` means "put data back."

`restore local` runs on your machine and restores into your local development database and local `BACKUP_PATHS`:

```sh
bundle exec exe/kamal-backup restore local latest
```

That command needs:

- local database settings through `DATABASE_URL` or `SQLITE_DATABASE_PATH`
- local file targets through `BACKUP_PATHS`
- access to the restic repository through `RESTIC_REPOSITORY` and `RESTIC_PASSWORD`

If the production file paths differ from the local ones, set `LOCAL_RESTORE_SOURCE_PATHS` to the production path list and keep `BACKUP_PATHS` pointed at the local targets.

`restore production` runs from the backup accessory and restores back into the live production database and production `BACKUP_PATHS`:

```sh
bin/kamal accessory exec backup "kamal-backup restore production latest"
```

Destructive restore commands prompt for confirmation. Add `--yes` for automation:

```sh
bin/kamal accessory exec backup "kamal-backup restore production latest --yes"
```

## Restore Drills

`drill` means "restore, check, and record the result."

For small apps, the fastest proof is often a local drill:

```sh
bundle exec exe/kamal-backup drill local latest --check "bin/rails runner 'puts User.count'"
```

`drill local` restores onto your machine, runs the optional verification command, and writes `last_restore_drill.json` under `KAMAL_BACKUP_STATE_DIR`.

For bigger apps, the main drill should usually be production-side and scratch-based:

```sh
bin/kamal accessory exec backup \
  "kamal-backup drill production latest --database app_restore_20260423 --files /restore/files --check 'test -d /restore/files/data/storage' --yes"
```

`drill production` restores into a scratch database and scratch file path on production infrastructure. It does not restore into the live production database.

For SQLite, use `--sqlite-path` instead of `--database`:

```sh
bin/kamal accessory exec backup \
  "kamal-backup drill production latest --sqlite-path /restore/db/restore.sqlite3 --files /restore/files --check 'test -f /restore/db/restore.sqlite3' --yes"
```

Run restore drills regularly and keep a short note with the result:

- when you ran it
- who ran it
- which snapshot you restored
- whether it was a local drill or a production-side drill
- which scratch targets you used
- whether the restored data looked correct

Production-looking local targets are refused unless `KAMAL_BACKUP_ALLOW_PRODUCTION_RESTORE=true`.

Every drill run also writes `last_restore_drill.json` under `KAMAL_BACKUP_STATE_DIR`, and `kamal-backup evidence` includes that latest result.

## Evidence for CASA and Security Reviews

`kamal-backup evidence` is meant to answer, "Show me how backups are configured today."

It prints a redacted JSON summary with:

- app name
- current time
- database adapter
- redacted restic repository
- configured file backup paths
- whether client-side forget/prune is enabled
- retention policy
- latest database and file snapshots
- last tracked `restic check` result
- last tracked restore drill result
- image version
- installed tool versions

Run it with:

```sh
bin/kamal accessory exec backup "kamal-backup evidence"
```

For CASA or another review, a practical workflow looks like this:

1. Run backups on a schedule.
2. Run `kamal-backup check` on a schedule, or enable `RESTIC_CHECK_AFTER_BACKUP=true`.
3. Run `kamal-backup drill production` against a scratch target, or `kamal-backup drill local` for a smaller app.
4. Save a short note about the drill if you want operator context beyond the JSON result.
5. Attach the `kamal-backup evidence` JSON plus that note to the review packet.

The JSON is not the whole story by itself. It is the machine-readable appendix that supports the operational story.

Secrets, passwords, access keys, and database URL credentials are redacted before output.

## Local Development

Install the CLI dependencies:

```sh
bundle install
```

Run tests:

```sh
bin/test
```

Run docs locally:

```sh
cd docs
bundle install
bundle exec jekyll serve --livereload
```

Published docs are configured for `https://kamal-backup.dev`.

Build the image:

```sh
docker build -t kamal-backup .
```

CI publishes container images to `ghcr.io/crmne/kamal-backup`. Pull requests build the image without pushing; branch, tag, SHA, default-branch `latest`, and default-branch version tags are pushed on non-PR builds. The version tag comes from `lib/kamal_backup/version.rb`, and default-branch pushes also create the matching GitHub release.

The Docker image installs the bundled gems and copies the Ruby CLI from `exe/` and `lib/`, which is why `kamal-backup` is on `PATH` inside the container.

In normal Kamal use, there is no installation step on the app host. Run the command inside the accessory:

```sh
bin/kamal accessory exec backup "kamal-backup evidence"
```

Run a local backup against a filesystem restic repository:

```sh
export APP_NAME=local-app
export DATABASE_ADAPTER=sqlite
export SQLITE_DATABASE_PATH=/tmp/app.sqlite3
export BACKUP_PATHS=/tmp/app-files
export RESTIC_REPOSITORY=/tmp/kamal-backup-restic
export RESTIC_PASSWORD=local-password
export RESTIC_INIT_IF_MISSING=true

bundle exec exe/kamal-backup backup
bundle exec exe/kamal-backup list
bundle exec exe/kamal-backup evidence
```

An example Docker Compose setup for local integration work is in `examples/docker-compose.integration.yml`.

## Container Contents

The image is based on Debian slim Ruby and includes:

- Ruby runtime
- `pg_dump` and `pg_restore`
- `mariadb-dump` or `mysqldump`, plus `mariadb` or `mysql`
- `sqlite3`
- `restic`
- CA certificates
- `tini`

## Security Notes

- Subprocesses are executed with argument arrays, not shell interpolation.
- The CLI redacts secrets in errors and evidence output.
- Database backups use database-native export tools.
- File data should be mounted read-only in the backup accessory.
- Restores are explicit, prompted operations with separate local and production-side drill flows.
- Object storage credentials should be least-privilege for the backup bucket or prefix.

## Non-Goals

- Not a hosted backup service.
- Not a replacement for database point-in-time recovery.
- Not a physical replication tool.
- Not a secret manager.

## License

MIT
