---
title: Configuration
description: YAML-first setup, generated config, deploy mount, secrets, local overrides, and optional settings.
nav_order: 3
---

## Generate the backup config

Run:

```sh
bundle exec kamal-backup init
```

`init` creates `config/kamal-backup.yml` if it is missing, then prints the accessory block to add to `config/deploy.yml`. It does not edit `config/deploy.yml`, and it does not create `config/kamal-backup.local.yml`.

The generated backup config looks like this:

```yaml
app: your-app
accessory: backup
databases:
  - name: app
    adapter: postgres
    url: postgres://your-app@your-db:5432/your_app_production
    password:
      secret: DATABASE_PASSWORD
paths:
  - /data/storage
restic:
  repository: s3:https://s3.example.com/your-app-backups
  password:
    secret: RESTIC_PASSWORD
  init_if_missing: true
backup:
  schedule: 1d
```
{: data-title="config/kamal-backup.yml"}

Edit that file for production. It is the main backup configuration: app name, database sources, restic repository, file paths, and schedule.

`kamal-backup.yml` uses the grouped shape shown above. Older flat YAML keys such as `database_adapter`, `backup_paths`, and `restic_repository` are rejected so configuration stays explicit. See [Upgrading](/upgrading/) when moving from 0.2.

## Default options

- `accessory`: the Kamal accessory name. The default is `backup`.
- `app`: the app tag used on restic snapshots.
- `databases`: one or more PostgreSQL, MySQL/MariaDB, or SQLite databases to back up.
- `paths`: filesystem paths to snapshot from mounted volumes.
- `restic.repository`: the restic repository location, such as S3-compatible storage, a restic REST server, or a filesystem path.
- `restic.password.secret`: the Kamal secret env var that contains the restic password.
- `restic.init_if_missing`: run `restic init` when the repository has not been initialized yet.
- `backup.schedule`: how often the accessory runs backups. `1d` means once per day.

For MySQL, change the database settings:

```yaml
databases:
  - name: app
    adapter: mysql
    url: mysql2://app@app-mysql:3306/app_production
    password:
      secret: DATABASE_PASSWORD
```
{: data-title="config/kamal-backup.yml"}

For SQLite, point at the database file inside the accessory:

```yaml
databases:
  - name: app
    adapter: sqlite
    path: /data/storage/production.sqlite3
```
{: data-title="config/kamal-backup.yml"}

That path should be the live SQLite database file as mounted into the backup accessory. The SQLite adapter creates its own temporary backup file before sending it to restic.

For a live SQLite database in WAL mode, mount the storage volume read-write in the backup accessory so SQLite can open the database, WAL, and shared-memory files normally:

```yaml
volumes:
  - "your_app_storage:/data/storage"
  - "your_app_backup_state:/var/lib/kamal-backup"
```
{: data-title="config/deploy.yml"}

If you require the backup accessory to have no write access to app storage, do not point it at a live WAL database over a read-only mount. Have the writer create a WAL-less snapshot, then point the SQLite database `path` at that snapshot. That is an advanced hardening tradeoff, not the normal SQLite setup.

## Add the accessory

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
        - DATABASE_PASSWORD
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
DATABASE_PASSWORD=...
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
```

If the repository URL contains credentials, declare it as a secret reference instead:

```yaml
restic:
  repository:
    secret: RESTIC_REPOSITORY
```
{: data-title="config/kamal-backup.yml"}

If you do not want the restic password value in the process environment, point restic at a mounted file instead:

```yaml
restic:
  password:
    file: /run/secrets/restic-password
```
{: data-title="config/kamal-backup.yml"}

The same works for the repository string when needed:

```yaml
restic:
  repository_file: /run/secrets/restic-repository
```
{: data-title="config/kamal-backup.yml"}

## Validate before boot

Run this before booting or rebooting the accessory:

```sh
bundle exec kamal-backup validate
```

With a normal `config/deploy.yml`, `validate` checks the backup accessory config before the accessory has to be running. It catches missing app, database, restic, backup path settings, and required Kamal secrets that resolve to empty values.

## Local restores

For normal Rails apps, no local backup config is needed. `restore local` and `drill local` infer:

- production source settings from `config/kamal-backup.yml`
- local database settings from `config/database.yml`
- local Active Storage path from `storage`
- local state under `tmp/kamal-backup`

Only add `config/kamal-backup.local.yml` when your local targets are nonstandard:

```yaml
databases:
  - name: app
    adapter: postgres
    url: postgres://localhost/chatwithwork_development
paths:
  - storage
state:
  path: tmp/kamal-backup
```
{: data-title="config/kamal-backup.local.yml"}

## Useful options

These options are supported but not included in the generated default config:

```yaml
restic:
  check_after_backup: true
  check_read_data_subset: 5%
  forget_after_backup: true
  retention:
    keep_last: 7
    keep_daily: 7
    keep_weekly: 4
    keep_monthly: 6
    keep_yearly: 2
```
{: data-title="config/kamal-backup.yml"}

`restic.forget_after_backup` defaults to enabled unless explicitly set to a falsey value such as `false`, `0`, `no`, `n`, or `off`.

Environment variables can still override YAML values when you need an emergency override, but the clean setup is YAML for configuration and Kamal secrets for secrets.
