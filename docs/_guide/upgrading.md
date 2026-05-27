---
title: Upgrading
description: Version-by-version upgrade notes for breaking changes and config migrations.
nav_order: 7
---

This page collects version-specific upgrade notes. Read the section for every version newer than the one you currently run.

## Upgrading to 0.3

0.3 changes the shape of `config/kamal-backup.yml`. The old flat YAML keys are no longer supported.

The goal is to make one Kamal deployment explicit: one app, multiple databases if needed, simple filesystem paths, restic settings, and one backup schedule.

## Config shape

Before 0.3:

```yaml
accessory: backup
app_name: chatwithwork
database_adapter: postgres
database_url: postgres://chatwithwork@chatwithwork-db:5432/chatwithwork_production
backup_paths:
  - /data/storage
restic_repository: s3:https://s3.example.com/chatwithwork-backups
restic_init_if_missing: true
backup_schedule_seconds: 86400
```
{: data-title="config/kamal-backup.yml"}

In 0.3:

```yaml
app: chatwithwork
accessory: backup

databases:
  - name: app
    adapter: postgres
    url: postgres://chatwithwork@chatwithwork-db:5432/chatwithwork_production
    password:
      secret: DATABASE_PASSWORD

paths:
  - /data/storage

restic:
  repository: s3:https://s3.example.com/chatwithwork-backups
  password:
    secret: RESTIC_PASSWORD
  init_if_missing: true

backup:
  schedule: 1d
```
{: data-title="config/kamal-backup.yml"}

## Key mapping

- `app_name` becomes `app`.
- `database_adapter` and `database_url` move under `databases`.
- `sqlite_database_path` becomes `databases[].path`.
- `backup_paths` becomes `paths`.
- `restic_repository` becomes `restic.repository`.
- `restic_init_if_missing` becomes `restic.init_if_missing`.
- `backup_schedule_seconds: 86400` becomes `backup.schedule: 1d`.
- `state_dir` becomes `state.path`.

Restic retention and check settings also move under `restic`:

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

## Secrets

0.3 keeps secret values out of `kamal-backup.yml`. The YAML names the env var, and Kamal provides the value through `env.secret`.

For database passwords:

```yaml
databases:
  - name: app
    adapter: postgres
    url: postgres://chatwithwork@chatwithwork-db:5432/chatwithwork_production
    password:
      secret: DATABASE_PASSWORD
```
{: data-title="config/kamal-backup.yml"}

Then pass that secret in Kamal:

```yaml
accessories:
  backup:
    env:
      secret:
        - DATABASE_PASSWORD
        - RESTIC_PASSWORD
        - AWS_ACCESS_KEY_ID
        - AWS_SECRET_ACCESS_KEY
```
{: data-title="config/deploy.yml"}

If the whole database URL is secret, use:

```yaml
databases:
  - name: app
    adapter: postgres
    url:
      secret: DATABASE_URL
```
{: data-title="config/kamal-backup.yml"}

The same pattern works for restic:

```yaml
restic:
  repository:
    secret: RESTIC_REPOSITORY
  password:
    secret: RESTIC_PASSWORD
```
{: data-title="config/kamal-backup.yml"}

## Multiple databases

0.3 supports multiple databases within the same Kamal deployment:

```yaml
databases:
  - name: app
    adapter: postgres
    url: postgres://chatwithwork@chatwithwork-db:5432/chatwithwork_production
    password:
      secret: APP_DATABASE_PASSWORD

  - name: solid_queue
    adapter: postgres
    url: postgres://chatwithwork@chatwithwork-db:5432/chatwithwork_queue_production
    password:
      secret: SOLID_QUEUE_DATABASE_PASSWORD
```
{: data-title="config/kamal-backup.yml"}

This is for multiple databases or accessories inside one Kamal deployment. It is not intended for one backup accessory to cross into separate Kamal deployments.

## Local overrides

If you had `config/kamal-backup.local.yml`, migrate it to the same shape:

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

If production paths differ from local paths and you are not running through Kamal with `-d` or `-c`, set `restore_from`:

```yaml
paths:
  - storage
restore_from:
  - /data/storage
```
{: data-title="config/kamal-backup.local.yml"}

## Validate

After changing the config, run:

```sh
bundle exec kamal-backup validate
```

If validation reports a legacy key such as `database_adapter`, `backup_paths`, or `restic_repository`, that key still needs to be moved into the 0.3 shape.
