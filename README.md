# Conejo

Forgejo and a Forgejo Actions runner for [bunny.net Magic Containers](https://bunny.net/magic-containers/), with hourly encrypted backups to S3.

- `ghcr.io/bussmann-io/conejo` is the official rootless Forgejo 15 LTS image plus a start script.
- `ghcr.io/bussmann-io/conejo-runner` is the official Forgejo runner image plus Node.js, npm, curl, jq and ssh for jobs.

Magic Containers keeps a volume on a single node, without snapshots, and has no shell into a running container. conejo handles that from environment variables:

- **Empty volume check:** Forgejo refuses to start when its database is missing, so a replaced disk never comes up as an empty forge.
- **Hourly backups:** a `forgejo dump`, encrypted with GnuPG and uploaded to any S3 storage. It keeps 24 hourly, 7 daily and 12 monthly copies.
- **Restore:** one variable restores a backup onto an empty volume.
- **Upgrade safety:** the database is copied before a version change. If the old version is deployed again before the new one became healthy, the copy is put back.
- **Administration:** The first admin user is automatically created from environment variables, no web-interface setup.
- **Runner:** A Forgejo Actions runner runs next to the main Forgejo instance, executing jobs defined in your repositories.

## Deploy on bunny.net

The steps use the [Bunny CLI](https://www.npmjs.com/package/@bunny.net/cli). Set up the [backup bucket](#backups) first.

1. Save this as `bunny.jsonc` in an empty folder:

   ```jsonc
   {
     "version": "2026-05-11",
     "app": {
       "name": "forgejo",
       "scaling": { "min": 1, "max": 1 },
       "regions": ["DE"],
       "containers": {
         "forgejo": {
           "image": "ghcr.io/bussmann-io/conejo:15.0.12",
           "endpoints": [
             { "type": "cdn", "ssl": true, "ports": [{ "public": 443, "container": 3000 }] },
             { "type": "anycast", "name": "ssh", "ports": [{ "public": 22, "container": 2222 }] }
           ],
           "volumes": [{ "name": "data", "mount": "/var/lib/gitea", "size": 20 }],
           "probes": {
             "startup": { "type": "http", "path": "/api/healthz", "port": 3000, "initialDelaySeconds": 5, "periodSeconds": 10, "timeoutSeconds": 5, "failureThreshold": 60, "successThreshold": 1 },
             "readiness": { "type": "http", "path": "/api/healthz", "port": 3000, "initialDelaySeconds": 1, "periodSeconds": 10, "timeoutSeconds": 5, "failureThreshold": 3, "successThreshold": 1 },
             "liveness": { "type": "http", "path": "/api/healthz", "port": 3000, "initialDelaySeconds": 1, "periodSeconds": 30, "timeoutSeconds": 10, "failureThreshold": 4, "successThreshold": 1 }
           }
         }
       }
     }
   }
   ```

2. Save the settings as `conejo.env` next to it, and keep this file out of git. Create the three secrets with `openssl rand -hex 32`, `openssl rand -base64 32` and `openssl rand -hex 20`.

   ```sh
   FORGEJO__server__DOMAIN=git.example.com
   FORGEJO__server__ROOT_URL=https://git.example.com/
   FORGEJO__server__SSH_DOMAIN=ssh.git.example.com
   FORGEJO__service__DISABLE_REGISTRATION=true
   FORGEJO__security__SECRET_KEY=<64 hex characters>
   CONEJO_EXPECT_DATA=false
   CONEJO_ADMIN_USERNAME=jane
   CONEJO_ADMIN_EMAIL=jane@example.com
   CONEJO_ADMIN_PASSWORD=<a password>
   CONEJO_BACKUP_URL=https://fsn1.your-objectstorage.com/forgejo-backups/git.example.com
   CONEJO_BACKUP_REGION=fsn1
   CONEJO_BACKUP_ACCESS_KEY_ID=<upload key id>
   CONEJO_BACKUP_SECRET_ACCESS_KEY=<upload key secret>
   CONEJO_BACKUP_PASSPHRASE=<44 base64 characters>
   CONEJO_RUNNER_SECRET=<40 hex characters>
   ```

3. Create the app, then send the settings:

   ```sh
   bunny apps deploy
   bunny apps env push conejo.env
   ```

4. Point your domain at the CDN endpoint, and `ssh.git.example.com` at the anycast IP.

5. Sign in as the admin. Then turn on the empty volume check and remove the admin variables, because they reset the password on every start:

   ```sh
   bunny apps env set CONEJO_EXPECT_DATA true
   bunny apps env remove CONEJO_ADMIN_USERNAME
   bunny apps env remove CONEJO_ADMIN_EMAIL
   bunny apps env remove CONEJO_ADMIN_PASSWORD
   ```

6. Create the runner from a second empty folder, because the CLI links each folder to one app. Save this as `bunny.jsonc`:

   ```jsonc
   {
     "version": "2026-05-11",
     "app": {
       "name": "forgejo-runner",
       "scaling": { "min": 1, "max": 1 },
       "regions": ["DE"],
       "containers": {
         "runner": { "image": "ghcr.io/bussmann-io/conejo-runner:13.2.2" }
       }
     }
   }
   ```

   Save this as `runner.env`, with the same runner secret as in `conejo.env`:

   ```sh
   CONEJO_FORGEJO_URL=https://git.example.com/
   CONEJO_RUNNER_SECRET=<40 hex characters>
   CONEJO_RUNNER_LABELS=bunny
   ```

   ```sh
   bunny apps deploy
   bunny apps env push runner.env
   ```

Workflows then run on the runner with `runs-on: bunny`:

```yaml
on: push
jobs:
  build:
    runs-on: bunny
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm run build
```

## Configuration

### conejo

- `FORGEJO__<section>__<KEY>` sets that key in Forgejo's `app.ini`, which is rebuilt on every start. `FORGEJO__security__SECRET_KEY` is required.
- `CONEJO_EXPECT_DATA` (default `true`) refuses to start without a database. Set it to `false` only for the first start of a new instance.
- `CONEJO_ADMIN_USERNAME`, `CONEJO_ADMIN_EMAIL` and `CONEJO_ADMIN_PASSWORD` create this admin, or set its password if it exists. `admin` is a reserved name in Forgejo.
- `CONEJO_RUNNER_SECRET` registers a runner for every repository. It is 40 lowercase hex characters. `CONEJO_RUNNER_NAME` names the runner (default `runner`).
- `CONEJO_BACKUP_URL` is the S3 address of the bucket, optionally with a folder.
- `CONEJO_BACKUP_REGION` is the S3 region, for example `fsn1`.
- `CONEJO_BACKUP_ACCESS_KEY_ID` and `CONEJO_BACKUP_SECRET_ACCESS_KEY` are a key that may upload. Setting the key ID turns backups on.
- `CONEJO_BACKUP_PASSPHRASE` encrypts the backups. Without it, nobody can open them.
- `CONEJO_BACKUP_PING_URL` is called after each backup, with `/fail` appended when it failed. It works with healthchecks.io.
- `CONEJO_RESTORE_FROM`, `CONEJO_RESTORE_ACCESS_KEY_ID` and `CONEJO_RESTORE_SECRET_ACCESS_KEY` restore a backup, see [Restore](#restore).

The image sets these defaults for Magic Containers:

- `FORGEJO__server__SSH_PORT=22` and `FORGEJO__server__SSH_LISTEN_PORT=2222`, because the anycast endpoint maps port 22 to 2222.
- `FORGEJO__server__APP_DATA_PATH=/var/lib/gitea/data` and `FORGEJO__lfs__PATH=/var/lib/gitea/data/lfs`, so a restore puts every file of a dump back in place.
- `FORGEJO__database__DB_TYPE=sqlite3`, `FORGEJO__database__SQLITE_JOURNAL_MODE=WAL` and `FORGEJO__security__INSTALL_LOCK=true`.
- `GITEA_APP_INI=/tmp/forgejo/app.ini`, so a removed variable really removes its setting.
- `GOMAXPROCS=4`, because Magic Containers shows Go all 32 or more host cores.

### conejo-runner

- `CONEJO_FORGEJO_URL` is the address of your Forgejo.
- `CONEJO_RUNNER_SECRET` is the same secret as on the conejo app.
- `CONEJO_RUNNER_LABELS` lists the labels for `runs-on`, separated by commas.
- `CONEJO_RUNNER_CAPACITY` (default `1`) is the number of jobs at once.
- `CONEJO_RUNNER_TIMEOUT` (default `1h`) is the longest a job may run.

Jobs run directly in the runner container, because Magic Containers has no Docker:

- `container:`, `services:` and Docker-based actions don't run.
- `actions/setup-node` downloads builds that don't run on Alpine. Use the installed Node.js 24.
- All repositories share the runner and its container. Only let trusted people change workflows.

## Backups

Every hour, conejo uploads one encrypted `forgejo dump` with all repositories, the database, and uploaded files such as attachments, LFS objects and packages:

- `hourly/forgejo-<hour>.tar.gz.gpg`, one per UTC hour.
- `daily/forgejo-<weekday>.tar.gz.gpg`, from the first backup of each UTC day.
- `monthly/forgejo-<month>.tar.gz.gpg`, from the first backup of each month.

Each backup overwrites its slot. Turn on versioning and object lock, so an overwrite keeps the previous copy, and no key can delete one for 7 days. Plan for about 250 times the size of one backup.

The container only gets a key that can upload. Hetzner Object Storage keys can reach every bucket in their own project, so the upload key comes from a second project, and a bucket policy lets it upload. Run these with a key of the bucket's project:

```sh
export AWS_ENDPOINT_URL=https://fsn1.your-objectstorage.com AWS_REGION=fsn1
aws s3api create-bucket --bucket forgejo-backups --object-lock-enabled-for-bucket
aws s3api put-object-lock-configuration --bucket forgejo-backups \
  --object-lock-configuration '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"COMPLIANCE","Days":7}}}'
aws s3api put-bucket-lifecycle-configuration --bucket forgejo-backups \
  --lifecycle-configuration '{"Rules":[{"ID":"old-copies","Status":"Enabled","Filter":{},"NoncurrentVersionExpiration":{"NoncurrentDays":8}}]}'
aws s3api put-bucket-policy --bucket forgejo-backups --policy '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": ["arn:aws:iam:::user/p<second project id>:<upload key id>"] },
    "Action": ["s3:PutObject"],
    "Resource": ["arn:aws:s3:::forgejo-backups/*"]
  }]
}'
```

Keep the key of the bucket's project in your password manager. It is the restore key.

## Restore

conejo restores only onto an empty volume. It never overwrites an existing database.

1. List the backups with the restore key:

   ```sh
   aws s3 ls s3://forgejo-backups/git.example.com/hourly/
   ```

2. Save the backup and the restore key as `restore.env`, and send it to the app:

   ```sh
   CONEJO_RESTORE_FROM=hourly/forgejo-07.tar.gz.gpg
   CONEJO_RESTORE_ACCESS_KEY_ID=<restore key id>
   CONEJO_RESTORE_SECRET_ACCESS_KEY=<restore key secret>
   ```

   ```sh
   bunny apps env push restore.env
   ```

   On the next start, conejo downloads and decrypts the backup, rebuilds the database, checks it and starts Forgejo. For an older copy of a slot, append its version, for example `hourly/forgejo-07.tar.gz.gpg?versionId=<id>`.

3. Once Forgejo is up, remove the three variables and delete `restore.env`:

   ```sh
   bunny apps env remove CONEJO_RESTORE_FROM
   bunny apps env remove CONEJO_RESTORE_ACCESS_KEY_ID
   bunny apps env remove CONEJO_RESTORE_SECRET_ACCESS_KEY
   ```

A large restore takes longer than the startup probe allows. Raise its `failureThreshold` first.

A backup is a plain Forgejo dump. To open one elsewhere:

```sh
gpg --decrypt forgejo-07.tar.gz.gpg | tar -xz
```

## Upgrades

- Images are tagged with the upstream version: `conejo:15.0.12` and `conejo-runner:13.2.2`. `latest` and `sha-<commit>` exist too.
- CI rebuilds both images every week, so Alpine security updates arrive without a new Forgejo release.
- To upgrade, change the tag in `bunny.jsonc` and run `bunny apps deploy`.
- Forgejo can't open a database that a newer version has migrated. Going back only works before the new version became healthy, because then conejo puts its copy back.

## Limits

- The volume attaches to one pod, so every change takes Forgejo offline for about a minute.
- Volumes read and write at most 10 MB/s.
- If a volume is lost, you lose up to an hour of changes.
- Magic Containers blocks outgoing mail ports (25, 465, 587 and 2525).
- conejo supports SQLite only.

## Development

```sh
docker build -t conejo:dev conejo
docker build -t conejo-runner:dev conejo-runner

test/e2e.sh conejo:dev conejo-runner:dev
```

## License

MIT for this repository. The images contain Forgejo and the Forgejo runner, which are GPL-3.0-or-later.
