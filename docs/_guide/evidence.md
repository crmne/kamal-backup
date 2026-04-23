---
title: Evidence for Security Reviews
description: Use the evidence command, restore drills, and restic checks to prepare for CASA and other security assessments.
nav_order: 6
---

`kamal-backup evidence` exists for the moment when someone asks, "Show me how backups are configured today."

That might be:

- a CASA reviewer;
- a customer security questionnaire;
- your own internal ops review;
- an incident retrospective after a restore drill.

The command prints a redacted JSON summary:

```sh
bin/kamal accessory exec backup "kamal-backup evidence"
```

The JSON includes:

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

Secrets, passwords, access keys, and database URL credentials are redacted before output.

## How to use this for CASA or another review

`evidence` is not the entire story by itself. It is the machine-readable appendix that backs up the story you tell in the review.

A practical workflow looks like this:

1. Run backups on a schedule.
2. Run `kamal-backup check` on a schedule, or enable `RESTIC_CHECK_AFTER_BACKUP=true`.
3. Run `kamal-backup drill production` against a scratch target, or `kamal-backup drill local` for a smaller app.
4. Keep a short human note when you want operator context beyond the drill JSON:
   date, operator, snapshot restored, target used, and whether the app data looked correct.
5. Run `kamal-backup evidence` and include the JSON with the review packet.

For many reviews, that combination is what matters:

- current backup configuration
- recent backup timestamps
- repository health checks
- a real restore drill, not just successful backup logs

## Restic checks

Run checks manually:

```sh
bin/kamal accessory exec backup "kamal-backup check"
```

Or enable checks after successful backups:

```sh
RESTIC_CHECK_AFTER_BACKUP=true
RESTIC_CHECK_READ_DATA_SUBSET=5%
```

The latest check result is stored under `KAMAL_BACKUP_STATE_DIR` and included in evidence output when available. The latest restore drill result is stored there too.

## What reviewers usually want to hear

Avoid generic phrases like "we have backups." Say something concrete instead:

- backups run from a dedicated Kamal accessory
- PostgreSQL, MySQL/MariaDB, or SQLite are backed up with database-native export tools
- file-backed Active Storage is backed up from mounted volumes
- restores are explicit, prompted operations with separate local and production-side drill flows
- the team runs restore drills and keeps evidence output
