# kamal-backup

`kamal-backup` gives Rails apps a clean backup and restore workflow for Kamal.

It backs up:

- PostgreSQL, MySQL/MariaDB, or SQLite
- file-backed Active Storage and other mounted app files

It restores in two clear modes:

- `restore local`: pull a production backup onto your machine
- `restore production`: restore back into live production

And it drills in two clear modes:

- `drill local`: prove the backup works on your machine
- `drill production`: restore into scratch targets on production infrastructure, run checks, and record evidence

Under the hood it uses [restic](https://restic.net/) for encrypted backup storage and repository management.

## Why Rails teams use it

`kamal-backup` is aimed at the common self-hosted Rails setup where:

- the app is deployed with Kamal
- the database is PostgreSQL, MySQL/MariaDB, or SQLite
- file data lives on a mounted volume
- you need real restore drills and evidence for CASA or another security review

If your app already stores Active Storage blobs directly in S3, there may be no local file path for `BACKUP_PATHS` to capture. In that case, `kamal-backup` still covers the database side, but object-storage backups are a separate concern.

## Quick Start

Add the gem in your Rails app:

```ruby
group :development do
  gem "kamal-backup"
end
```

Install it and generate the shared config stub:

```sh
bundle install
bundle exec kamal-backup init
```

That creates:

- `config/kamal-backup.yml`

For most Rails apps, that is enough. `restore local` and `drill local` can infer:

- the development database target from `config/database.yml`
- the local files target from `storage`
- the local drill state directory from `tmp/kamal-backup`

Only create `config/kamal-backup.local.yml` if you need to override those local defaults.

Then add the backup accessory to `config/deploy.yml`:

```yaml
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

Run the first backup from your app checkout with the local gem and Kamal-style destination selection:

```sh
bundle exec kamal-backup -d production backup
bundle exec kamal-backup -d production list
bundle exec kamal-backup -d production evidence
```

If you keep multiple deploy configs, pass `-c` the same way Kamal does:

```sh
bundle exec kamal-backup -c config/deploy.staging.yml -d staging backup
```

Examples live in:

- [examples/kamal-accessory.yml](examples/kamal-accessory.yml)
- [examples/kamal-backup.yml.example](examples/kamal-backup.yml.example)
- [examples/kamal-backup.local.yml.example](examples/kamal-backup.local.yml.example)

## What Restic Does Here

`kamal-backup` uses restic as the backup engine and repository format.

In the normal Kamal setup, you do not install restic on the Rails app host. The backup accessory image already includes it. You only point the accessory at a restic repository, usually:

- S3-compatible object storage
- a restic REST server
- a filesystem path for local development

If you choose a `rest:` repository, `kamal-backup` does not install or operate that server for you. It is a separate service.

## Commands

The operator-facing command surface is:

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

Production-side commands shell out through Kamal when you pass `-d` or `-c`. Local commands run on your machine.

Common examples:

```sh
bundle exec kamal-backup -d production backup
bundle exec kamal-backup -d production check
bundle exec kamal-backup -d production evidence
bundle exec kamal-backup -d production restore production latest
bundle exec kamal-backup -d production drill production latest --database app_restore_20260423 --files /restore/files
bundle exec kamal-backup -d production version
bundle exec kamal-backup restore local latest
bundle exec kamal-backup drill local latest --check "bin/rails runner 'puts User.count'"
```

Use `kamal-backup help`, `kamal-backup help restore`, or `kamal-backup help drill` for task-specific usage.

## How a Backup Run Works

When `kamal-backup backup` runs, it does five things:

1. Validates the app name, restic repository, database settings, and `BACKUP_PATHS`.
2. Creates a database backup with the database-native export tool.
3. Streams that database backup into restic with tags such as `type:database`, `adapter:<adapter>`, and `run:<timestamp>`.
4. Runs one `restic backup` for all configured `BACKUP_PATHS`, tagged as `type:files` with the same `run:<timestamp>`.
5. Optionally runs `restic forget --prune` and `restic check`.

That shared `run:<timestamp>` tag lets you match the database backup and file backup from the same run.

## Restore

`restore` means "put data back."

`restore local` runs on your machine. With `-d` or `-c`, it asks Kamal for the backup accessory config and uses that as the source of truth for:

- `APP_NAME`
- `DATABASE_ADAPTER`
- `RESTIC_REPOSITORY`
- `LOCAL_RESTORE_SOURCE_PATHS` from the accessory `BACKUP_PATHS`

For a normal Rails app, the local targets come from Rails conventions:

- the development database in `config/database.yml`
- `storage` as the local files target
- `tmp/kamal-backup` as the local drill state directory

You still provide the local secrets yourself in env:

- `RESTIC_PASSWORD`
- `POSTGRES_PASSWORD` or `MYSQL_PWD` when needed
- `RESTIC_REPOSITORY` when it is not visible through `kamal config`

Example:

```sh
bundle exec kamal-backup -d production restore local latest
```

`restore production` is the emergency path back into the live production database and live production file paths:

```sh
bundle exec kamal-backup -d production restore production latest
```

It prompts locally, then shells out through Kamal to the backup accessory.

## Restore Drills

`drill` means "restore, check, and record the result."

`drill local` is often the fastest proof for a small app:

```sh
bundle exec kamal-backup -d production drill local latest --check "bin/rails runner 'puts User.count'"
```

`drill production` restores into scratch targets on production infrastructure. It does not touch the live production database:

```sh
bundle exec kamal-backup -d production drill production latest \
  --database app_restore_20260423 \
  --files /restore/files \
  --check "test -d /restore/files/data/storage"
```

Every drill writes `last_restore_drill.json` under `KAMAL_BACKUP_STATE_DIR`, and `kamal-backup evidence` includes that latest result.

## Evidence for CASA and Similar Reviews

`evidence` is the JSON summary you can attach to an ops record or security review.

It includes:

- latest database and file snapshots
- latest `restic check` result
- latest restore drill result
- retention settings
- tool versions

For many reviews, the useful sequence is:

1. scheduled backups
2. repository checks
3. a real restore drill
4. `kamal-backup evidence`

That reads much better to a reviewer than "the backup job is green."

## Configuration Highlights

Core accessory environment:

```sh
APP_NAME=chatwithwork
DATABASE_ADAPTER=postgres
RESTIC_REPOSITORY=s3:https://s3.example.com/chatwithwork-backups
RESTIC_PASSWORD=change-me
BACKUP_PATHS=/data/storage
```

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

Optional local config files:

- `config/kamal-backup.yml`
- `config/kamal-backup.local.yml`

`config/kamal-backup.local.yml` is only for nonstandard local targets. Keep secrets such as `RESTIC_PASSWORD`, cloud credentials, and local DB passwords in environment variables, not in YAML files.

## Docs

Full docs live in [`docs/`](docs/):

- [`docs/_guide/getting-started.md`](docs/_guide/getting-started.md)
- [`docs/_guide/configuration.md`](docs/_guide/configuration.md)
- [`docs/_guide/restore.md`](docs/_guide/restore.md)
- [`docs/_guide/restore-drills.md`](docs/_guide/restore-drills.md)
- [`docs/_reference/commands.md`](docs/_reference/commands.md)
