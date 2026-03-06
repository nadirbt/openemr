# AWS ECS Fargate Deployment Notes (Aurora MySQL + EFS)

This file documents issues encountered when deploying OpenEMR 8.0.0 on AWS ECS Fargate
with Aurora Serverless v2 (MySQL) and EFS for persistent site files.

---

## Issue 1: SWARM_MODE required for fresh EFS volume

**Symptom**
Container crashes immediately with:
```
PHP Warning: require_once(.../sites/default/sqlconf.php): Failed to open stream: No such file or directory
PHP Fatal error: Uncaught Error: Failed opening required '.../sqlconf.php'
```

**Root cause**
The startup script (`openemr.sh`) unconditionally runs:
```sh
CONFIG=$(php -r "require_once('.../sites/default/sqlconf.php'); echo \$config;")
```
This line runs before `auto_setup()`. Without SWARM_MODE, the script never copies
the default `sites/` content from `/swarm-pieces/sites/` into the EFS volume, so
`sqlconf.php` does not exist and PHP crashes (exit 255), killing the script via `set -e`.

**Fix**
Set `SWARM_MODE=yes` in the container environment. This causes the startup script to
detect an empty `sites/` on the EFS and restore the defaults from `/swarm-pieces/sites/`
(including a placeholder `sqlconf.php` with `$config=0`) before proceeding.

This is safe to leave on permanently for any deployment where `sites/` is an external
volume (EFS, NFS, Kubernetes PVC).

---

## Issue 2: Do not pre-create the `openemr` database in Aurora

**Symptom**
After SWARM_MODE is enabled and `auto_setup()` runs, it fails with:
```
ERROR IN OPENEMR INSTALL: Unable to execute SQL:
  create database openemr character set utf8mb4 collate utf8mb4_general_ci
  due to: Can't create database 'openemr'; database exists
```
The container then crashes, and on restart the stale `docker-leader` lock on EFS
causes all subsequent containers to become swarm followers that wait forever for
`docker-completed`.

**Root cause**
The CDK stack passed `defaultDatabaseName: 'openemr'` to the Aurora MySQL cluster,
which pre-creates an empty `openemr` database. OpenEMR's `auto_configure.php` also
tries to CREATE the database, so the two conflict.

**Fix**
Remove `defaultDatabaseName` from the Aurora MySQL cluster definition. OpenEMR's
installer creates the database itself using the master credentials.

---

## Issue 3: Stale `docker-leader` lock after crash

**Symptom**
Every container logs:
```
Waiting for the docker-leader to finish configuration before proceeding.
```
indefinitely, never starting Apache.

**Root cause**
With SWARM_MODE, the startup script atomically creates
`sites/docker-leader` to elect itself leader. If the leader container crashes
mid-setup (before writing `sites/docker-completed`), the lock file persists on EFS.
All replacement containers fail to acquire the lock and wait forever for
`docker-completed`.

**Fix**
Ensure the first deployment completes cleanly (fixes Issues 1 and 2 above). If the
lock does get stuck during development, delete the EFS filesystem and let CDK create
a fresh one on the next deploy.

---

## Issue 4: `COPY . .` with mismatched source version triggers wrong upgrade path

**Symptom**
```
Plan to try an upgrade from 0 to 9
PHP Fatal error: Failed opening required '.../sqlconf.php'
```

**Root cause**
The startup script compares three version files:
- `/root/docker-version` — baked into the Docker base image (e.g. `9`)
- `/var/www/.../openemr/docker-version` — in the PHP source directory (e.g. `9`)
- `/var/www/.../openemr/sites/default/docker-version` — on EFS (fresh = `0`)

If `ROOT == CODE` and `ROOT > SITES`, the script prints "Plan to try an upgrade from
0 to 9" and sets `UPGRADE_YES=true`. The upgrade path requires `sqlconf.php` to already
exist, which it doesn't on a fresh EFS → crash.

When the Dockerfile uses `COPY . .`, the source's `docker-version` replaces the one
baked into the base image. As long as the source tag matches the base image tag
(e.g. both are `8.0.0`), the values are equal and this condition triggers on a fresh EFS.

SWARM_MODE (Issue 1 fix) resolves this by restoring `sites/default/docker-version`
from `/swarm-pieces/sites/` before the version comparison, so SITES == ROOT and the
upgrade is not triggered.

---

## Summary of required environment variables for ECS

| Variable          | Value                  | Reason |
|-------------------|------------------------|--------|
| `SWARM_MODE`      | `yes`                  | Restores default `sites/` on fresh EFS |
| `MYSQL_HOST`      | Aurora cluster endpoint| From Secrets Manager |
| `MYSQL_ROOT_USER` | `openemradmin`         | Aurora master user (no `root` on Aurora) |
| `MYSQL_ROOT_PASS` | (from Secrets Manager) | Aurora master password |
| `MYSQL_USER`      | `openemr`              | App user created by installer |
| `MYSQL_PASS`      | (from Secrets Manager) | App user password |
| `MYSQL_DATABASE`  | `openemr`              | Database name |
| `MYSQL_PORT`      | `3306`                 | Standard MySQL port |
