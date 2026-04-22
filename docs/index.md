---
layout: home
title: Home
description: Kamal-first encrypted backups for databases and mounted app files using restic.
permalink: /
hero:
  name: kamal-backup
  text: Encrypted backups for Kamal accessories
  tagline: Back up database dumps and mounted application files with restic, then restore and prove readiness from the same container.
  actions:
    - theme: brand
      text: Get Started
      link: /getting-started/
    - theme: alt
      text: Restore Drills
      link: /restore-drills/
    - theme: alt
      text: GitHub
      link: https://github.com/crmne/kamal-backup
  image:
    src: /assets/images/logo.svg
    alt: kamal-backup
    width: 256
    height: 256
features:
  - icon: 🗄️
    title: Logical Database Dumps
    details: PostgreSQL, MySQL/MariaDB, and SQLite backups use dump tools instead of raw database directories.
  - icon: 📁
    title: Mounted File Backups
    details: Back up Rails Active Storage and other mounted paths with restic path snapshots.
  - icon: 🔒
    title: Restore Safety Gates
    details: Restore commands require explicit environment flags and restore-specific database targets.
  - icon: ✅
    title: Audit Evidence
    details: Generate redacted operational evidence for backup readiness and security reviews.
---
