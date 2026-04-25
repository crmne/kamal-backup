---
title: Getting Started
description: Install the gem, add the backup accessory, generate the shared config stub, and run the first backup with Kamal-style destination selection.
nav_order: 1
---

This guide assumes:

- you already deploy the app with Kamal;
- your database is PostgreSQL, MySQL/MariaDB, or SQLite;
- any file data you want to back up is available on a mounted path such as `/data/storage`.

In normal Kamal use, restic runs inside the backup accessory image. You do not install restic on the Rails app host.

## 1. Add the gem

In the Rails app:

```ruby
group :development do
  gem "kamal-backup"
end
```

Then install it and generate the shared config stub:

```sh
bundle install
bundle exec kamal-backup init
```

That creates:

- `config/kamal-backup.yml`

The shared file is where you name the accessory if it is not called `backup`.

For most Rails apps, `restore local` and `drill local` can infer the local development database, the `storage` path, and `tmp/kamal-backup` without a second file. Only create `config/kamal-backup.local.yml` when your local targets are nonstandard.

If you want to run `restore local` or `drill local`, install `restic` on your machine too. The backup accessory image already includes it for production-side commands.

## 2. Choose a restic repository

Before you boot the accessory, decide where the backups will live. Common choices are:

- S3-compatible object storage;
- a restic REST server you run separately;
- a filesystem path for local development.

`kamal-backup` writes to that repository through restic. It does not manage the repository service for you.

## 3. Add the accessory

Add a backup accessory to your Kamal deploy config:

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

That same accessory config becomes the source of truth for production-side commands, and for local restore or local drill when you pass `-d` or `-c`.

## 4. Boot the accessory

```sh
bin/kamal accessory boot backup
bin/kamal accessory logs backup
```

The container default command is `kamal-backup schedule`, so once the accessory is up it starts running the foreground scheduler loop.

When you update the local gem, production-side commands expect the accessory to be on the same `kamal-backup` version. If they drift, reboot the accessory so it pulls the current `latest` image:

```sh
bin/kamal accessory reboot backup
```

## 5. Run the first backup

From your app checkout, use the gem and let it shell out through Kamal:

```sh
bundle exec kamal-backup -d production backup
bundle exec kamal-backup -d production list
bundle exec kamal-backup -d production evidence
```

If you keep multiple deploy configs, pass `-c` the same way Kamal does:

```sh
bundle exec kamal-backup -c config/deploy.staging.yml -d staging backup
```

The same pattern works for the other production-side commands:

```sh
bundle exec kamal-backup -d production check
bundle exec kamal-backup -d production version
bundle exec kamal-backup -d production schedule
```

## What the first backup creates

Each backup run creates:

- one database backup stored through restic stdin;
- one `type:files` restic snapshot containing all configured `BACKUP_PATHS` entries.

Database dump snapshots are tagged with `kamal-backup`, `app:<name>`, `type:database`, `adapter:<adapter>`, and `run:<timestamp>`. File snapshots use `type:files`, the same run tag, and informational `path:<label>` tags for the configured paths. Restore selects by `type:files`, not by one path tag.
