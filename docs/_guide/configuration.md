---
title: Configuration
description: YAML-first setup, generated config, deploy mount, secrets, local overrides, and optional settings.
nav_order: 3
---

## Generate The Backup Config

Run:

```sh
bundle exec kamal-backup init
```

`init` creates `config/kamal-backup.yml` if it is missing, then prints the accessory block to add to `config/deploy.yml`. It does not edit `config/deploy.yml`, and it does not create `config/kamal-backup.local.yml`.

The generated backup config looks like this:

```yaml
accessory: backup
app_name: your-app
database_adapter: postgres
database_url: postgres://your-app@your-db:5432/your_app_production
backup_paths:
  - /data/storage
restic_repository: s3:https://s3.example.com/your-app-backups
restic_init_if_missing: true
backup_schedule_seconds: 86400
```
{: data-title="config/kamal-backup.yml"}

Edit that file for production. It is the main backup configuration: app name, database source, restic repository, file paths, and schedule.

## Default Options

- `accessory`: the Kamal accessory name. The default is `backup`.
- `app_name`: the app tag used on restic snapshots.
- `database_adapter`: `postgres`, `mysql`, or `sqlite`.
- `database_url`: the production database connection string. PostgreSQL can also use libpq variables such as `PGHOST`, `PGDATABASE`, and `PGUSER`; MySQL can use `MYSQL_*` or `MARIADB_*` variables.
- `backup_paths`: file-backed Active Storage paths to snapshot from mounted volumes.
- `restic_repository`: the restic repository location, such as S3-compatible storage, a restic REST server, or a filesystem path.
- `restic_init_if_missing`: run `restic init` when the repository has not been initialized yet.
- `backup_schedule_seconds`: how often the accessory runs backups. `86400` means once per day.

For MySQL, change the database settings:

```yaml
database_adapter: mysql
database_url: mysql2://app@app-mysql:3306/app_production
```
{: data-title="config/kamal-backup.yml"}

For SQLite, point at the database file inside the accessory:

```yaml
database_adapter: sqlite
sqlite_database_path: /data/storage/production.sqlite3
```
{: data-title="config/kamal-backup.yml"}

That path should be the live SQLite database file as mounted into the backup accessory. The SQLite adapter creates its own temporary backup file before sending it to restic, and handles the normal Rails WAL cases for read-only storage mounts.

## Add The Accessory

Copy the accessory block printed by `init` into your Kamal deploy config, then mount the generated backup config with `files:`.

```yaml
accessories:
  backup:
    image: ghcr.io/crmne/kamal-backup:latest
    host: chatwithwork.com
    files:
      - config/kamal-backup.yml:/app/config/kamal-backup.yml:ro
    env:
      secret:
        - PGPASSWORD
        - RESTIC_PASSWORD
        - AWS_ACCESS_KEY_ID
        - AWS_SECRET_ACCESS_KEY
    volumes:
      - "chatwithwork_storage:/data/storage:ro"
      - "chatwithwork_backup_state:/var/lib/kamal-backup"
```
{: data-title="config/deploy.yml"}

The `files:` line is what keeps non-secret backup settings out of environment variables. Kamal uploads `config/kamal-backup.yml` and mounts it read-only into the accessory.

## Secrets

Keep secrets in Kamal secrets:

```sh
RESTIC_PASSWORD=...
PGPASSWORD=...
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
```

If the repository URL contains credentials, keep `RESTIC_REPOSITORY` in Kamal secrets and omit `restic_repository` from YAML.

If you do not want the restic password value in the process environment, point restic at a mounted file instead:

```yaml
restic_password_file: /run/secrets/restic-password
```
{: data-title="config/kamal-backup.yml"}

The same works for the repository string when needed:

```yaml
restic_repository_file: /run/secrets/restic-repository
```
{: data-title="config/kamal-backup.yml"}

## Validate Before Boot

Run this before booting or rebooting the accessory:

```sh
bundle exec kamal-backup validate
```

With a normal `config/deploy.yml`, `validate` checks the backup accessory config before the accessory has to be running. It catches missing app, database, restic, backup path settings, and required Kamal secrets that resolve to empty values.

## Local Restores

For normal Rails apps, no local backup config is needed. `restore local` and `drill local` infer:

- production source settings from `config/kamal-backup.yml`
- local database settings from `config/database.yml`
- local Active Storage path from `storage`
- local state under `tmp/kamal-backup`

Only add `config/kamal-backup.local.yml` when your local targets are nonstandard:

```yaml
database_url: postgres://localhost/chatwithwork_development
backup_paths:
  - storage
state_dir: tmp/kamal-backup
```
{: data-title="config/kamal-backup.local.yml"}

## Useful Options

These options are supported but not included in the generated default config:

```yaml
restic_check_after_backup: true
restic_check_read_data_subset: 5%
restic_forget_after_backup: true
restic_keep_last: 7
restic_keep_daily: 7
restic_keep_weekly: 4
restic_keep_monthly: 6
restic_keep_yearly: 2
backup_start_delay_seconds: 0
```
{: data-title="config/kamal-backup.yml"}

`restic_forget_after_backup` defaults to enabled unless explicitly set to a falsey value such as `false`, `0`, `no`, `n`, or `off`.

Environment variables can still override YAML values when you need an emergency override, but the clean setup is YAML for configuration and Kamal secrets for secrets.
