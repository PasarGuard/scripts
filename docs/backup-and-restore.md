# Backup and disaster recovery

[راهنمای فارسی](backup-and-restore.fa.md)

A recovery backup must contain the database, application configuration and the
versions required to run them. Recover those versions first; upgrade the panel
or database only after the restored installation is working.

## Quick recovery when the old server is gone

For a backup made by the updated script, copy the complete archive to a new
Linux server, for example `/root/backup_20261004120000.zip`. You do not need to
install the latest panel or create a new administrator first.

Install **only the management script**:

```bash
sudo bash -c "$(curl -fsSL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh)" @ install-script
```

Check the file and inspect the recorded source versions:

```bash
sudo pasarguard restore /root/backup_20261004120000.zip --check
```

For SQLite archives, install `sqlite3` before checking (on Debian/Ubuntu:
`sudo apt-get update && sudo apt-get install -y sqlite3`). `--check` extracts to a
temporary directory next to the archive, verifies checksums and database dump
completion/SQLite integrity, and removes staging afterwards. It does not require
Docker, import SQL, stop services or change destination configuration. It is not
a substitute for a complete restore drill.

Recover onto the empty server:

```bash
sudo pasarguard restore /root/backup_20261004120000.zip --fresh
```

After confirming, the script installs Docker/Compose if necessary, resolves the
source image digests, checks destination storage and fetches missing images. It
gives each recorded image the name the archived Compose file uses (for example
`pasarguard/panel:latest`) and installs that Compose file unchanged. It then
starts **only the database** and waits until it is ready: healthy when the
service has a Compose healthcheck, otherwise accepting TCP connections inside
its container. It imports the backup, restores application files and settings,
then starts the original panel and its dependencies. For SQLite, it validates and restores the consistent snapshot
before starting any panel services.

`--fresh` requires empty application/data directories, no existing containers in
the Compose project, and no existing database bind storage or named volumes.
The application directory may contain a `backup/` directory. It never removes
existing volumes to make recovery proceed. Use ordinary restore for an existing
installation. Official local SQLite/MySQL/MariaDB/PostgreSQL/TimescaleDB Compose
layouts are supported; remote databases and external volumes need manual setup.

On custom installations, paths and project name must match the recorded values:

```bash
sudo env APP_NAME=my-panel APP_DIR=/opt/my-panel DATA_DIR=/var/lib/my-panel \
  pasarguard restore /root/backup.zip --fresh
```

Keep the same host architecture unless the recorded digest supports the new
architecture. Network speed, image downloads, database size and disk speed set
the recovery time; recovery cannot be guaranteed to take a fixed number of minutes.

## What each backup contains

| Artifact | Purpose |
| --- | --- |
| `.env` | Application settings and secrets, including database connection fields |
| `docker-compose.yml` | Source deployment configuration |
| `pasarguard_data/` | Persistent application files, certificates and themes; database data directories and downloaded Xray binaries are excluded |
| SQLite snapshot or SQL dumps | Consistent database backup, not a copy of a running database data directory |
| `backup-runtime.tsv` | Format version, UTC creation time, source engine/server version, schema revision when available, source project/paths, and actual container image digests/image IDs |
| `backup-files.sha256` | SHA256 inventory of regular payload files, including configuration and recovery metadata |

Image references come from the actual containers, including stopped containers,
not from mutable `latest` or `lts` tags in the Compose template. If a service has
no container/image digest, the metadata reports `unavailable`; ordinary restore
still works, but `--fresh` refuses to substitute a guessed version. A locally
loaded original image ID can satisfy this requirement.

The inventory detects corruption; it does not authenticate who produced an
archive. Restore backups from your own trusted storage. ZIP archives are **not
encrypted by this script** and contain passwords/private keys. Store off-server
copies with appropriate access control or encryption. Archives and split parts
are created with private permissions; restored `.env` and Compose files are
restricted to their owner.

## Create and keep recoverable backups

```bash
sudo pasarguard backup
sudo pasarguard backup-service
```

Manual backups are created under `/opt/pasarguard/backup/`. The current backup
command removes previous local archives after successfully creating a new one;
keep multiple dated generations in a separate off-server location. A backup on
the same server does not protect against complete server loss.

SQLite uses the online `.backup` API and validates its snapshot with
`PRAGMA quick_check`. WAL/SHM/journal files from the running database are not the
restore authority. MySQL/MariaDB use the matching dump utility and verify its
completion marker. PostgreSQL/TimescaleDB attempt to dump cluster globals and
all user databases with per-database manifests; if that is unavailable, the
script falls back to the configured database. A fallback is **not** a backup of
unrelated databases on the server. Each PostgreSQL dump is internally consistent;
different databases are not captured at one common transaction instant.

Take backups when schema changes/DDL are not running. Database snapshots and
application-file copies are not one cross-filesystem transaction.

For automated Telegram delivery, configure through `backup-service` or use:

```env
BACKUP_SERVICE_ENABLED=true
BACKUP_TELEGRAM_BOT_KEY="123456789:example-token"
BACKUP_TELEGRAM_CHAT_ID="-1001234567890"
BACKUP_PROXY_ENABLED=false
# BACKUP_PROXY_URL="socks5://127.0.0.1:1080"
```

Supported minute intervals include 5, 15, 30, 60, 120, 360 and 1440. Sub-hour
intervals must divide 60 evenly; multi-hour intervals must be whole hours.
Download **all** backup parts and regularly run `--check` on the downloaded
copy. A Telegram upload alone is not proof that a backup can be imported.

## Restore an existing installation

```bash
sudo pasarguard restore /root/backup.zip
# Or select an archive from /opt/pasarguard/backup/ interactively:
sudo pasarguard restore
```

An explicit path avoids the numbered archive selection and also works when the
archive is outside the default backup directory. `--file /path/to/archive` is an
equivalent option. Automation may use `--yes` to skip confirmation; validation
still applies. Use `pasarguard restore --help` for the options.

Ordinary restore preserves the destination Compose file for server databases
and the provisioned destination database credentials/connection URL. It validates
payloads before stopping application writers. When source-version information is
available, it refuses MySQL-to-MariaDB/MariaDB-to-MySQL imports and database
version downgrades before executing the import. Restore to the original engine
and version when diagnosing an old backup. An allowed version comparison is not
a guarantee that every vendor-specific SQL statement is compatible.

Application/data files are saved before replacement, and SQLite receives a
pre-restore safety snapshot. Server SQL imports are **not transactional recovery
of the whole host**: an import can fail after changing data, and multi-database
restores can finish earlier databases before a later one fails. Take a separate
current backup before replacing an existing installation. Fresh recovery leaves
application services stopped on failure; it keeps provisioned storage for diagnosis
rather than destroying it or claiming automatic rollback. Once a failed fresh
recovery has provisioned Compose/configuration, diagnose the log and retry with
ordinary restore against that installation.

## Old backups without recovery metadata

`--check` accepts structurally valid legacy ZIP/tar.gz backups and reports that
source image digests and the checksum inventory are unavailable. An archive that
has `backup-runtime.tsv` but no `backup-files.sha256` is refused, because every
backup that records recovery metadata also writes the inventory. `--fresh` cannot infer the exact panel
version from a schema revision or a mutable image tag, so it refuses an archive
without recovery metadata.

1. Extract a **copy** of the backup and inspect `docker-compose.yml` and the dump
   headers (`-- Server version`, `-- Dumped from database version`). Keep the
   original archive unchanged.
2. Provision the source database engine/version and the original panel version
   if known. Pin exact image tags or digests in the destination Compose file.
   Do not assume installing the newest panel/database will accept an old dump.
3. Restore with the explicit archive path. For TimescaleDB, use the recorded
   extension version or the override below when it is known.
4. Validate the recovered installation, make a new backup, then plan upgrades.

Missing files, a truncated SQL dump, an unknown original panel version, or a
missing encryption key cannot be repaired by guessing SQL replacements. Never
blindly replace collations/DEFINER clauses or force an Alembic revision just to
hide an import error.

## TimescaleDB compatibility

The source extension version is recorded per database in `pg_dump/manifest.tsv`,
or in `db_backup.timescaledb-version` for a single-database fallback. For an
ordinary restore to a newer extension, the script attempts conversion in a
temporary compatibility container before changing the destination database.
That image must contain the source extension version and support its upgrade
path. PostgreSQL major-version downgrades are refused; extension conversion is
not an arbitrary PostgreSQL downgrade mechanism.

If a legacy single-database backup lacks extension metadata but you know its
exact source extension version:

```bash
sudo env TIMESCALEDB_BACKUP_VERSION=2.27.2 \
  pasarguard restore /root/legacy-backup.zip
```

For a destination on PostgreSQL 17 / TimescaleDB 2.28, for example, the compatible
image can be supplied explicitly:

```bash
sudo env TIMESCALEDB_COMPAT_IMAGE=timescale/timescaledb-ha:pg17-ts2.28-all \
  pasarguard restore /root/backup.zip
```

These are examples; choose versions from your backup and destination. If the
conversion fails or required versions are unavailable, the restore stops before
importing those incompatible dumps. Earlier completed databases are not rolled
back when a later database fails.

## Multipart archives and staging space

For `backup_*.part01.zip`, `.part02.zip`, etc., put every part in one directory.
Pass any part to `restore`; the script selects the initial part, checks the
sequence and combines it automatically. Individual parts are not standalone ZIPs.
For legacy `.z01`, `.z02`, ... plus `.zip`, keep the final `.zip` too; pass the
`.zip` file (a `.zNN` path is also normalized to it). Missing parts abort recovery.

Staging defaults to the archive directory. Allow room for archive recombination,
uncompressed files, SQL import and any current-data safety copies. Override the
staging directory when that filesystem is too small:

```bash
sudo env RESTORE_TMPDIR=/srv/recovery-staging pasarguard restore /root/backup.zip --fresh
```

`BACKUP_TMPDIR` similarly controls backup staging. Set it to a protected directory
with enough capacity; it defaults to the backup directory.

## Offline image preparation

Before losing access to the source, keep original images in a separate off-server
bundle when registry access cannot be relied on:

```bash
sudo docker image save -o /root/pasarguard-recovery-images.tar \
  $(sudo docker compose -f /opt/pasarguard/docker-compose.yml -p pasarguard ps -a -q \
    | xargs -r sudo docker inspect --format '{{.Image}}' | sort -u)
```

Store that file with the matching backup and an offline script bundle. On the
new host with Docker installed:

```bash
sudo docker image load -i /root/pasarguard-recovery-images.tar
sudo pasarguard restore /root/backup.zip --fresh
```

Loaded original image IDs are accepted even if `docker load` did not preserve
registry digests. The database archive itself does not include Docker images,
Docker installation packages or the management-script bundle; without preparing
those dependencies, a fully offline recovery is not guaranteed.

## After restoring

- Check `sudo pasarguard status` and `sudo pasarguard logs`; migrations must finish
  successfully before considering the panel healthy.
- Log in using the recovered administrator; check user counts, limits/usage,
  subscription URLs and a real client connection.
- Check each node's connection and its certificates/keys. The master backup does
  not replace backups of unrelated worker-node installations.
- Update the domain's DNS if the IP changed, check firewall/ports and TLS. Existing
  domain certificates may remain usable; IP certificates need replacement for the
  new IP. Re-establish automatic certificate renewal on the new host.
- Confirm the off-server backup schedule is active. Cron/acme services and DNS
  records outside the application directories are not restored by the archive.
- Make a new backup before upgrading. Fresh recovery runs the source images
  under the tags in your Compose file (for example `latest`), so the next
  `pasarguard update` pulls the current images for those tags. Choose the
  upgrade version deliberately.

## Troubleshooting

Errors are printed and persisted, when destination logging can be created, at:

```bash
sudo cat /opt/pasarguard/backup/pasarguard_restore_error.log
```

A `--check` failure prints diagnostics without creating a destination installation.
Redact passwords, tokens and full connection strings before sharing logs.

| Message / symptom | Action |
| --- | --- |
| Checksum failure / missing part | Download every original part again; do not edit the checksum inventory |
| No reproducible image | Load the original image bundle or provision explicit source versions for ordinary restore |
| Existing storage / containers | Use ordinary restore, or choose a genuinely empty recovery host; do not delete volumes containing needed data |
| Source and target engine differ / downgrade | Restore using the original engine and source version; upgrade afterwards |
| TimescaleDB conversion failed | Verify extension metadata, compatibility image and registry access; preserve the original dump |
| Unknown collation / SQL syntax | Compare source engine/version and dump-client version; reproduce the source before attempting a supported migration |
| Access denied / authentication failed | For ordinary restore, verify destination `.env` credentials against the live DB; changing `.env` does not change passwords in an existing DB volume |
| Database never ready / no disk space | Inspect DB container logs and available storage/staging capacity |
| Panel migration failed after import | Check the panel image version and Alembic revision; recover the original panel version before upgrading |
