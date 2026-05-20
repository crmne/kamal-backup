---
layout: home
title: kamal-backup Documentation
description: "Add scheduled, encrypted backups to Rails apps deployed with Kamal: database dumps, Active Storage files, restore drills, and review evidence."
permalink: /
hero:
  name: kamal-backup
  text: Add scheduled Rails backups to Kamal
  tagline: Run encrypted database and Active Storage backups from one Kamal accessory, with restore drills and review evidence built in.
  actions:
    - theme: brand
      text: Install kamal-backup
      link: /getting-started/
    - theme: alt
      text: See How Backups Work
      link: /how-backups-work/
    - theme: alt
      text: View on GitHub
      link: https://github.com/crmne/kamal-backup
  image:
    src: /assets/images/logo.svg
    alt: kamal-backup
    width: 256
    height: 256
features:
  - icon: 🕒
    title: Scheduled backups from one accessory
    details: Run `kamal-backup init`, fill in the generated config, and boot the accessory. The container runs `kamal-backup schedule` by default.
  - icon: 🗄️
    title: Database and file snapshots
    details: Dump PostgreSQL, MySQL/MariaDB, or SQLite with native tools, then snapshot file-backed Active Storage volumes through restic.
  - icon: 🔒
    title: Restores you can rehearse
    details: Restore production backups locally or into scratch production-side targets, run verification commands, and record the result.
  - icon: ✅
    title: Evidence for reviews
    details: Emit redacted JSON with latest snapshots, `kamal-backup check` results, restore drills, retention settings, and tool versions for CASA-style security reviews.
---
