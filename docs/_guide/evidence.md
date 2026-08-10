---
title: Evidence for Security Reviews
description: Use scheduled backups, restore drills, kamal-backup checks, and evidence output to prepare for security reviews like CASA.
nav_order: 7
---

`kamal-backup evidence` exists for the moment when someone asks, "Show me how this Rails app's backups are configured today, whether they run on a schedule, and whether you have tested restores."

That might be:

- a reviewer for a security program like CASA;
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
- configured databases
- redacted restic repository
- configured file backup paths
- whether client-side forget/prune is enabled
- retention policy
- latest database and file snapshots
- last tracked `kamal-backup check` result
- last tracked restore drill result
- image version
- installed tool versions

Secrets, passwords, access keys, and database URL credentials are redacted before output.

## How to use this for a security review

`evidence` is not the entire story by itself. It is the machine-readable appendix that backs up the story you tell in the review.

A practical workflow looks like this:

1. Run backups on a schedule.
2. Run `kamal-backup check` on a schedule, or enable `restic.check_after_backup`.
3. Run `kamal-backup drill production` against a scratch target, or `kamal-backup drill local` for a smaller app.
4. Keep a short human note when you want operator context beyond the drill JSON:
   date, operator, snapshot restored, target used, and whether the app data looked correct.
5. Run `kamal-backup evidence` and include the JSON with the review packet.

For many reviews, that combination is what matters:

- current backup configuration
- recent backup timestamps
- `kamal-backup check` results
- a real restore drill, not just successful backup logs

## Repository checks

Run checks manually:

```sh
bin/kamal accessory exec backup "kamal-backup check"
```

Or enable checks after successful backups:

```sh
restic:
  check_after_backup: true
  check_read_data_subset: 5%
```

The latest check result is stored under `KAMAL_BACKUP_STATE_DIR` and included in evidence output when available. The latest restore drill result is stored there too.

In the accessory container, the default state directory is `/var/lib/kamal-backup`. Mount that path as a persistent volume if you want the latest check and restore drill records to survive accessory replacement.

## What reviewers usually want to hear

Avoid generic phrases like "we have backups." Say something concrete instead:

- backups run from a dedicated Kamal accessory on a defined schedule
- PostgreSQL, MySQL/MariaDB, or SQLite are backed up with database-native export tools
- file-backed Active Storage files are backed up from mounted volumes
- restores are explicit, prompted operations with separate local and production-side drill flows
- the team runs restore drills and keeps evidence output
