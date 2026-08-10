---
title: Migrating to a new host
description: Move a running app to a new server by restoring from your backup repository, using the migration as a real restore drill.
nav_order: 6
---

Moving an app to a new server is the same problem as recovering from losing one, minus the panic. If your backups are real, a migration is just a restore you chose to do. This guide walks the whole sequence, and calls out the one thing that will quietly corrupt your snapshot history if you get the order wrong.

## The trap: a fresh accessory backs up immediately

The backup accessory starts its schedule the moment it boots. On a new host that means it will snapshot an **empty database** into your repository before you have restored anything.

Nothing errors. You now have a legitimate-looking recent snapshot containing nothing, sitting at the top of `kamal-backup list`. If you later restore "the latest snapshot" during a real incident, you restore the empty one.

So the rule for the new host is: **do not let it back up until it holds the data.**

That is what `backup.enabled` is for.

```yaml
backup:
  schedule: 1d
  enabled: false
```
{: data-title="config/kamal-backup.yml on the new host"}

With `enabled: false` the accessory still boots and stays up, and `restore`, `list`, `check` and `evidence` all work through it. It simply never writes a backup. Flip it to `true` and redeploy once the restore is verified.

## Sequence

The old host keeps serving traffic throughout. Nothing is destructive until you change DNS, and even that is reversible.

### 1. Prepare the new host

Deploy the app as normal, but point it at a hostname that is not yet your production domain — `beta.example.com` works well, because it gets you a real TLS certificate and a real URL to click around in.

Boot every accessory **except** the backup one, or boot it with `enabled: false`. Do not boot a backup accessory that is both enabled and pointed at your production repository.

```yaml
backup:
  schedule: 1d
  enabled: false
```
{: data-title="config/kamal-backup.yml"}

Use `kamal setup`, not `kamal deploy`. Setup installs Docker if needed and boots the accessories as part
of the deploy; `deploy` assumes they already exist. On a new host `deploy` starts the app against a
database container that was never created, and it fails its health check with a name resolution error:

```sh
bin/kamal setup -d beta
```

It does not matter that the deploy runs `db:prepare` and creates an empty schema before you restore.
`restore production` drops and recreates the schema.

### 2. Take a fresh backup on the old host

```sh
bin/kamal accessory exec backup "kamal-backup backup --force"
bundle exec kamal-backup list
```

Confirm the snapshot you are about to restore is the one you just took.

### 3. Restore onto the new host

```sh
bundle exec kamal-backup restore production -d beta
```

`--yes` deliberately does not cover this command. For unattended runs pass `--confirm-production-restore`,
which exists to make the intent explicit rather than incidental.

Keep the local gem and the remote accessory on the same version. `kamal-backup` refuses to run when they
differ, which is usually a sign the accessory needs `bin/kamal accessory reboot backup`.

This restores the database and any configured file paths into the new host's live targets. Because the new host is not yet serving your domain, "production" here means the new machine's production database, which is exactly what you want.

The restore replaces the database, dropping and recreating the schema first, so it does not matter that the deploy already ran `db:prepare` and created an empty one.

Make sure the accessory's storage volume is **writable**. The documented default has no `:ro`; a backup-only accessory may append it, but then a file restore cannot write Active Storage contents back.

### 4. Verify before you commit to anything

Click through the beta hostname as a real user. Check row counts, uploaded files, and anything backed by Active Storage. This is the part people skip and then regret.

```sh
bundle exec kamal-backup evidence
```

Check the encrypted columns specifically. If your framework encrypts data at rest — Rails' Active Record
Encryption derives its keys from `RAILS_MASTER_KEY` — restored rows are only useful if the new host holds
the same secret. Row counts matching is not evidence of that; decrypting a value is:

```sh
bin/kamal app exec -d beta --reuse 'bin/rails runner "puts Credential.first.access_token.present?"'
```

A host with a different master key restores every byte and then fails to read any of it.

If you have OAuth or webhook integrations, remember their redirect URIs and callback URLs point at your production domain. Either register the beta hostname with those providers, or accept that you are verifying everything else now and those at cutover.

### 5. Cut over

Point DNS at the new host. Lower the TTL a day ahead so propagation is minutes rather than hours.

Two things bite immediately after the record changes, and neither looks like what it is.

**Clear the old host key.** Your hostname now resolves to a different machine, so the entry in
`~/.ssh/known_hosts` is the old server's. The next deploy builds and pushes the image, then dies at the
SSH connection with `Net::SSH::HostKeyMismatch`. Nothing in the output mentions DNS or the host move, so
it reads like a broken deploy:

```sh
ssh-keygen -R your-app.com
ssh-keyscan your-app.com >> ~/.ssh/known_hosts
```

Remove **every** key type for the name, not just the one in the error. A leftover RSA or ECDSA entry from
the old host fails the same way even once the ED25519 entry is correct.

**Deploy the default destination, not the staging one.** It is tempting to add the production hostname to
the staging destination that is already running, but the proxy rejects that with
`host settings conflict with another service`, because that service already claims the staging hostname.
Deploy the normal configuration instead. Now that DNS points at the new machine, the host entry in your
main `deploy.yml` resolves there, so a plain `kamal deploy` lands on the new server and claims the
production hostnames as a separate service:

```sh
bin/kamal deploy
```

Then remove the staging containers and its proxy route:

```sh
bin/kamal app stop -d beta
docker exec kamal-proxy kamal-proxy remove your-app-web-beta
```

If there was a window between your backup and the cutover where the old host accepted writes, take a final backup on the old host and restore again on the new one before flipping. For a quiet app this is often unnecessary; check rather than assume.

### 6. Swap which host backs up

This is the step that is easy to forget, and it matters: **two hosts must never back up to the same repository.** Divergent data in one repository makes the snapshot history ambiguous, which defeats the point of having it.

On the **new** host, enable backups:

```yaml
backup:
  schedule: 1d
  enabled: true
```
{: data-title="config/kamal-backup.yml"}

```sh
bin/kamal accessory reboot backup
bin/kamal accessory exec backup "kamal-backup backup --force"
bundle exec kamal-backup list
```

On the **old** host, disable them:

```yaml
backup:
  schedule: 1d
  enabled: false
```
{: data-title="config/kamal-backup.yml"}

```sh
bin/kamal accessory reboot backup
```

The old accessory stays up with its configuration intact, so you can still restore *from* the repository onto the old host if you need to roll back. It just stops writing to it.

If you plan to keep both hosts running for a while, give the old one its own repository path instead of disabling it, so both retain independent history.

## Rolling back

Point DNS back at the old host. It has been running the whole time and its data is only stale by whatever was written after the final backup. If you need that data, restore the newest snapshot from the new host onto the old one — the old accessory still has the configuration to do it.

## Why this is worth doing deliberately

A migration exercises the restore path with real production data and a real deadline. Most backup systems are never tested until the day they are needed, and that is a bad day to discover a problem.

Keep the `kamal-backup evidence` output from step 4. It records the snapshots restored, the check results and the tool versions, which is exactly the artifact a security review or a SOC 2 auditor asks for when they want proof that backups restore rather than merely run.
