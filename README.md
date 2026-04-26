<div align="center">

<img src="docs/assets/images/logo.svg" alt="kamal-backup" height="96">

<h1>kamal-backup</h1>

<strong>The easiest way to run scheduled backups for a Rails app deployed with Kamal.</strong>

<br>
<br>

[![Gem Version](https://img.shields.io/gem/v/kamal-backup.svg)](https://rubygems.org/gems/kamal-backup)
[![CI](https://github.com/crmne/kamal-backup/actions/workflows/ci.yml/badge.svg)](https://github.com/crmne/kamal-backup/actions/workflows/ci.yml)
[![Docker Image](https://img.shields.io/badge/image-ghcr.io%2Fcrmne%2Fkamal--backup-blue)](https://github.com/crmne/kamal-backup/pkgs/container/kamal-backup)
[![Docs](https://img.shields.io/badge/docs-kamal--backup.dev-blue)](https://kamal-backup.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

---

`kamal-backup` is a Kamal accessory that backs up your Rails database and file-backed Active Storage files on a schedule, stores them in an encrypted restic repository, and gives you restore drills plus evidence you can hand to a security reviewer.

If you already deploy with Kamal, backups should feel like adding one more accessory, not designing a new operations system.

| 🕒 Scheduled | 🗄️ Rails data | 🔁 Restore proof | 📋 Review evidence |
|---|---|---|---|
| Runs as a Kamal accessory with `BACKUP_SCHEDULE_SECONDS`. | Backs up PostgreSQL, MySQL/MariaDB, SQLite, and file-backed Active Storage files. | Restores locally or into scratch production-side targets for drills. | Emits redacted JSON for security reviews like CASA. |

```mermaid
flowchart LR
  A[Kamal accessory] -->|schedule| B[Database dump]
  A -->|schedule| C[Active Storage files]
  B --> D[Encrypted restic repository]
  C --> D
  D --> E[Restore local]
  D --> F[Restore drill]
  F --> G[Evidence JSON]
```

That last part matters. Security reviews, customer questionnaires, and real incident prep need more than "we have backups." `kamal-backup evidence` produces a redacted JSON record with the latest snapshots, repository checks, restore drill result, retention settings, and tool versions.

## Why Rails teams use it

`kamal-backup` is for Rails developers who already use Kamal and want a simple answer to:

- "Is my database backed up every day?"
- "Are my Active Storage files backed up too?"
- "Can I restore production data locally?"
- "Can I run a restore drill without touching production?"
- "Can I show evidence for a security review like CASA?"

The common production shape is:

- the app is deployed with Kamal
- the database is PostgreSQL, MySQL/MariaDB, or SQLite
- Active Storage uses the disk service on a mounted volume such as `/data/storage`
- backups should run automatically on a schedule
- restore drills and evidence should be easy enough to run before a reviewer asks

If your app stores Active Storage blobs directly in S3, there may be no mounted Active Storage path for `BACKUP_PATHS` to capture. In that case, `kamal-backup` still covers the database side, but object-storage backup and retention are a separate concern.

## Quick Start

Add the gem to your Rails app:

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

For most Rails apps, that is enough local configuration. `restore local` and `drill local` can infer:

- the development database target from `config/database.yml`
- the local Active Storage target from `storage`
- the local drill state directory from `tmp/kamal-backup`

Only create `config/kamal-backup.local.yml` if you need to override those local defaults.

Local restore and drill also require the `restic` binary on your machine. The backup accessory image already includes `restic` for production-side commands.

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
      - "chatwithwork_backup_state:/var/lib/kamal-backup"
```

Boot it:

```sh
bin/kamal accessory boot backup
bin/kamal accessory logs backup
```

The container default command is `kamal-backup schedule`, so the accessory starts scheduled backups as soon as it boots. `BACKUP_SCHEDULE_SECONDS=86400` means once per day.

The `/var/lib/kamal-backup` volume preserves the latest `check` and restore drill records across accessory reboots. Keep it mounted if you want `kamal-backup evidence` to include recent operational proof after the container is recreated.

Run the first backup manually from your app checkout with the local gem and Kamal-style destination selection:

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

## Why restic is the backend

`kamal-backup` uses [restic](https://restic.net/) as the backup engine and repository format because Rails teams need boring, inspectable backup plumbing:

- encrypted repositories by default
- snapshots you can list, tag, check, and restore
- deduplication across backup runs
- retention and prune support
- S3-compatible object storage, restic REST server, and filesystem repository support
- one CLI and one repository format for database dumps and Active Storage files

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

Remote-backed commands require the local gem version and the backup accessory version to match. If they drift, `kamal-backup` fails fast and tells you to reboot the accessory so it pulls the current `latest` image. `version` is the diagnostic exception: from an app checkout with `config/deploy.yml`, it shows both versions and the sync status even without `-d`.

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

Use `kamal-backup help` for the command list. Use command `--help` for task-specific options, for example `kamal-backup drill production --help`.

## How a Backup Run Works

When `kamal-backup backup` runs, it does five things:

1. Validates the app name, restic repository, database settings, and `BACKUP_PATHS`.
2. Creates a database backup with the database-native export tool.
3. Streams that database backup into restic with tags such as `type:database`, `adapter:<adapter>`, and `run:<timestamp>`.
4. Runs one `restic backup` for all configured Active Storage paths in `BACKUP_PATHS`, tagged as `type:files` with the same `run:<timestamp>`.
5. Optionally runs `restic forget --prune` and `restic check`.

That shared `run:<timestamp>` tag lets you match the database backup and Active Storage file backup from the same run.

## Restore

`restore` means "put data back."

`restore local` runs on your machine. With `-d` or `-c`, it asks Kamal for the backup accessory config and uses that as the source of truth for:

- `APP_NAME`
- `DATABASE_ADAPTER`
- `RESTIC_REPOSITORY`
- `LOCAL_RESTORE_SOURCE_PATHS` from the accessory `BACKUP_PATHS`

For a normal Rails app, the local targets come from Rails conventions:

- the development database in `config/database.yml`
- `storage` as the local Active Storage target
- `tmp/kamal-backup` as the local drill state directory

You still provide the local secrets yourself in env:

- `RESTIC_PASSWORD`
- `PGPASSWORD` or `MYSQL_PWD` when needed
- `RESTIC_REPOSITORY` when it is not visible through `kamal config`

And you need `restic` installed locally and available on `PATH`.

Example:

```sh
bundle exec kamal-backup -d production restore local latest
```

`restore production` is the emergency path back into the live production database and live production Active Storage path:

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

Like `restore local`, this runs on your machine and requires a local `restic` install.

`drill production` restores into scratch targets on production infrastructure. It does not touch the live production database:

```sh
bundle exec kamal-backup -d production drill production latest \
  --database app_restore_20260423 \
  --files /restore/files \
  --check "test -d /restore/files/data/storage"
```

Every drill writes `last_restore_drill.json` under `KAMAL_BACKUP_STATE_DIR`, and `kamal-backup evidence` includes that latest result.

## Evidence for Security Reviews

`evidence` is the redacted JSON summary you can attach to an ops record or security review.

It includes:

- latest database and Active Storage file snapshots
- latest `restic check` result
- latest restore drill result
- retention settings
- tool versions

For many reviews, the useful sequence is:

1. scheduled backups
2. repository checks
3. a real restore drill
4. `kamal-backup evidence`

That reads much better to a reviewer than "we have backups."

## Configuration Highlights

Core accessory environment:

```sh
APP_NAME=chatwithwork
DATABASE_ADAPTER=postgres
RESTIC_REPOSITORY=s3:https://s3.example.com/chatwithwork-backups
RESTIC_PASSWORD=change-me
BACKUP_PATHS=/data/storage
KAMAL_BACKUP_STATE_DIR=/var/lib/kamal-backup
```

`BACKUP_PATHS` is where the accessory reads file-backed Active Storage files. Mount the production storage volume read-only when backing it up.

`KAMAL_BACKUP_STATE_DIR` stores the latest `restic check` result and latest restore drill result. The default is `/var/lib/kamal-backup`; mount that path as a persistent volume if you want evidence to survive accessory replacement.

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
