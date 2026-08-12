---
title: Security and Restore Safety
description: How kamal-backup handles secrets, subprocesses, database exports, Active Storage snapshots, and deliberate restores.
nav_order: 2
---

## Secrets

`kamal-backup` redacts secrets in evidence and command failure output. It treats values from keys containing words such as `password`, `secret`, `token`, `key`, and `credential` as sensitive.

Do not put cloud credentials in clear Kamal environment. Use Kamal secrets for:

- `RESTIC_PASSWORD`;
- `AWS_ACCESS_KEY_ID`;
- `AWS_SECRET_ACCESS_KEY`;
- database passwords such as `DATABASE_PASSWORD`, `PGPASSWORD`, or `MYSQL_PWD`.

Store a copy of `RESTIC_PASSWORD` outside the app repository and outside the S3 bucket. Restic repositories are encrypted with that password; without it, the backup data is not recoverable.

For SFTP repositories, use a dedicated SSH key restricted to the backup account and repository path. Mount only that
key and a verified `known_hosts` file into the accessory; do not expose the Kamal host's entire `.ssh` directory. The
SSH credential controls access to the repository host, while `RESTIC_PASSWORD` separately encrypts the repository.

## Subprocess execution

External tools are executed with argument arrays, not shell interpolation. The backup container does not need application source code.

## Database backups

Database backups use database-native export tools:

- PostgreSQL: `pg_dump --format=custom --no-owner --no-privileges`
- MySQL/MariaDB: `mariadb-dump` or `mysqldump` with transaction-safe defaults
- SQLite: `sqlite3 <db> ".backup ..."`

This is why the docs talk about database backups rather than raw database directories. `kamal-backup` is exporting application data with the tools Rails teams already use for dumps and restores.

## Active Storage backups

File-backed Active Storage files are backed up from configured mounted paths with `restic backup`. A backup-only
accessory can mount the production storage volume read-only so the container cannot modify it. `restore production`
requires that mount to be writable; remove `:ro` and reboot the accessory before restoring files.

SQLite is the exception when the live database is on that storage volume. Rails SQLite apps commonly use WAL mode, and live WAL backups need normal read-write access to the database, WAL, and shared-memory files. For the normal SQLite setup, mount the storage volume read-write and point the SQLite database `path` at the live database. If the backup accessory must have no write access to app storage, back up a writer-created WAL-less snapshot instead.

## Deliberate restores

Restore commands are explicit and deliberate:

- operators must choose `restore local`, `restore production`, `drill local`, or `drill production`
- destructive restore commands prompt for confirmation unless an explicit automation flag is passed
- `restore production` asks for typed confirmation and ignores the generic `--yes` shortcut
- local restores refuse production-looking local targets
- production drills restore into scratch targets, not the live production database
- production-side commands can be run from the local gem with `-d` or `-c`, but the destructive work still happens on the backup accessory with the same explicit command surface

Those checks are there to make restores deliberate. They also help when you need to explain to a reviewer that a restore drill cannot quietly point back at production by accident.
