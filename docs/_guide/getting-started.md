---
title: Getting Started
description: Add one Kamal accessory that runs scheduled backups for your database and file-backed Active Storage files.
nav_order: 1
---

Run `kamal-backup init`, fill in one config file, add one Kamal accessory, then boot it. The accessory runs scheduled database and Active Storage backups from there.

This guide assumes:

- you already deploy the app with Kamal;
- your database is PostgreSQL, MySQL/MariaDB, or SQLite;
- file-backed Active Storage files are available on a mounted path such as `/data/storage`.

In normal Kamal use, restic runs inside the backup accessory image. You do not install restic on the Rails app host.

## 1. Add the gem

In the Rails app:

```ruby
group :development do
  gem "kamal-backup"
end
```
{: data-title="Gemfile"}

Then install it and generate the config file:

```sh
bundle install
bundle exec kamal-backup init
```

That creates `config/kamal-backup.yml`. Put the production backup settings in that file:

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

File backups are opt-in: only paths explicitly listed under `paths` are included. `kamal-backup` never infers `storage` from Rails. For local restores, Rails can still provide the development database and `tmp/kamal-backup`; when production file paths are configured, list their local targets in `config/kamal-backup.local.yml`.

## 2. Choose where backups live

Before you boot the accessory, decide where the encrypted restic repository will live. Common choices are:

- S3-compatible object storage;
- an SFTP server reached with a dedicated SSH key;
- a restic REST server you run separately;
- a filesystem path for local development.

`kamal-backup` chooses restic because it gives Rails teams encrypted snapshots, deduplication, retention, repository checks, and a portable restore format without inventing a new backup backend. It does not manage the repository service for you.

## 3. Add the accessory

Add a backup accessory to your Kamal deploy config:

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
      - "chatwithwork_storage:/data/storage"
      - "chatwithwork_backup_state:/var/lib/kamal-backup"
```
{: data-title="config/deploy.yml"}

Kamal uploads `config/kamal-backup.yml` and mounts it read-only into the accessory. Secrets still stay in Kamal secrets.

The storage volume is writable so `restore production` can replace its contents without replacing the mount point.
Writable access is also required when a live SQLite database is stored on that volume. For a backup-only accessory,
you can append `:ro`; remove it and reboot the accessory before a production file restore.

## 4. Boot the accessory

```sh
bundle exec kamal-backup validate
bin/kamal accessory boot backup
bin/kamal accessory logs backup
```

`validate` catches missing required backup settings before the accessory has to be running.

The container default command is `kamal-backup schedule`, so once the accessory is up it starts running scheduled backups. In the example above, `backup.schedule: 1d` means one backup per day.

The `/var/lib/kamal-backup` volume preserves the latest `check` and restore drill records across accessory reboots. Keep it mounted if you want `kamal-backup evidence` to include recent operational proof after the container is recreated.

When you update the local gem, production-side commands expect the accessory to be on the same `kamal-backup` version. If they drift, reboot the accessory so it pulls the current `latest` image:

```sh
bin/kamal accessory reboot backup
```

## 5. Run and inspect the first backup

From your app checkout, use the gem and let it shell out through Kamal:

```sh
bundle exec kamal-backup backup
bundle exec kamal-backup list
bundle exec kamal-backup evidence
```

`backup` respects the configured schedule and tells you when no backup is due. Use `bundle exec kamal-backup backup --force` to create an immediate snapshot.

With the default `config/deploy.yml`, `backup`, `list`, `check`, `unlock`, `evidence`, `validate`, and `version` infer the backup accessory. If you keep multiple deploy configs or destinations, pass `-c` or `-d` the same way Kamal does:

```sh
bundle exec kamal-backup -c config/deploy.staging.yml -d staging backup
```

The same pattern works for the other production-side commands:

```sh
bundle exec kamal-backup check
bundle exec kamal-backup unlock
bundle exec kamal-backup validate
bundle exec kamal-backup version
bundle exec kamal-backup -d production schedule
```

`kamal-backup version` is a quick diagnostic: it reads `config/deploy.yml`, checks the backup accessory version, and tells you whether the local gem and remote accessory are in sync.

## What the first backup creates

Each backup run creates:

- one restic stdin snapshot for each configured database;
- one `type:files` restic snapshot for the configured paths.

Database dump snapshots are tagged with `kamal-backup`, `app:<name>`, `type:database`, `database:<name>`, and `adapter:<adapter>`. File snapshots use `type:files` plus informational `path:<label>` tags for the configured paths. Restic stores the snapshot time separately.

The next useful step is a restore drill:

Local restore and drill commands need the `restic` binary installed on your machine. Production-side commands use the backup accessory image, which already includes it.

```sh
bundle exec kamal-backup -d production drill local latest --check "bin/rails runner 'puts User.count'"
bundle exec kamal-backup -d production evidence
```

That gives you a backup, a restore proof, and a redacted evidence packet for a security review like CASA.
