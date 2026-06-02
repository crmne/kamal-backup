<div align="center">

<img src="docs/assets/images/logo.svg" alt="kamal-backup" height="96">

<h1>kamal-backup</h1>

<strong>Add scheduled Rails backups to Kamal with one accessory.</strong>

[![Gem Version](https://img.shields.io/gem/v/kamal-backup.svg)](https://rubygems.org/gems/kamal-backup)
[![CI](https://github.com/crmne/kamal-backup/actions/workflows/ci.yml/badge.svg)](https://github.com/crmne/kamal-backup/actions/workflows/ci.yml)
[![Docker Image](https://img.shields.io/badge/image-ghcr.io%2Fcrmne%2Fkamal--backup-blue)](https://github.com/crmne/kamal-backup/pkgs/container/kamal-backup)
[![Docs](https://img.shields.io/badge/docs-kamal--backup.dev-blue)](https://kamal-backup.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

---

Backups for Rails apps deployed with Kamal should not become a separate ops project.

`kamal-backup` is one Kamal accessory that runs encrypted backups for your Rails database and file-backed Active Storage files on a schedule. It also gives you restore drills and redacted evidence for security reviews like CASA.

Run `kamal-backup init`, fill in one config file, add the accessory, then boot it. If you already deploy with Kamal, backups should feel like adding one more accessory.

## Why Rails teams use it

Most self-hosted Rails apps need the same things:

- scheduled backups for PostgreSQL, MySQL/MariaDB, or SQLite
- file-backed Active Storage backups from mounted volumes
- local restores for inspecting production data safely
- restore drills that do not touch the live production database
- evidence that says more than "the backup ran"

`kamal-backup` wraps that workflow in a small Ruby gem and a production accessory image backed by a restic repository.

## Quick start

Add the gem:

```rb
group :development do
  gem "kamal-backup"
end
```

Generate the config file and accessory snippet:

```sh
bundle install
bundle exec kamal-backup init
```

Add the accessory to `config/deploy.yml`:

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

For SQLite databases stored on the mounted storage volume, omit `:ro` from that volume.

Put the backup settings in `config/kamal-backup.yml`:

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

Boot it. The container runs `kamal-backup schedule` by default:

```sh
bundle exec kamal-backup validate
bin/kamal accessory boot backup
bin/kamal accessory logs backup
```

Run the first backup, check the repository, and print evidence. From an app checkout with `config/deploy.yml`, these commands shell out through Kamal to the backup accessory:

```sh
bundle exec kamal-backup backup
bundle exec kamal-backup list
bundle exec kamal-backup check
bundle exec kamal-backup evidence
```

## What you get

- **Scheduled backups:** the accessory runs continuously and backs up on `backup.schedule`.
- **Database and Active Storage coverage:** database dumps plus file-backed Active Storage files from mounted volumes.
- **Restic underneath:** encrypted, deduplicated snapshots in S3-compatible storage, a restic REST server, or a filesystem repository.
- **Local restores:** inspect production data safely in your local Rails app.
- **Restore drills:** restore into scratch production-side targets, run verification commands, and record the result.
- **Security review evidence:** `kamal-backup evidence` prints redacted JSON with latest snapshots, `kamal-backup check` results, drills, retention, and tool versions.

## Docs

Read the full documentation at **[kamal-backup.dev](https://kamal-backup.dev)**.

Start here:

- [Getting Started](https://kamal-backup.dev/getting-started/)
- [How Backups Work](https://kamal-backup.dev/how-backups-work/)
- [Configuration](https://kamal-backup.dev/configuration/)
- [Restore Drills](https://kamal-backup.dev/restore-drills/)
- [Commands](https://kamal-backup.dev/commands/)

## Releasing

Run the release helper from a clean `master` checkout:

```sh
bin/release 0.2.9
```

It updates `lib/kamal_backup/version.rb`, syncs `Gemfile.lock`, commits `Release 0.2.9`, and pushes `master`. CI runs the test suite and docs build, publishes the RubyGem and Docker image tags, then creates `v0.2.9`, the GitHub release, and the docs deployment from the release commit.

Use `bin/release 0.2.9 --no-push` to prepare the commit locally without publishing.

## License

MIT
