## Installing pasarguard

### Standalone packages

- Farsi guide: [Pasarguard Standalone](iran-sanction/README-pasarguard-standalone.fa.md)
- Latest release file: [pasarguard-standalone.tar.gz](https://github.com/PasarGuard/scripts/releases/latest/download/pasarguard-standalone.tar.gz)

### 🔧 Available options

| Option               | Description                                                                                  |
| -------------------- | -------------------------------------------------------------------------------------------- |
| `--database`         | Optional. Choose from: `mysql`, `mariadb`, `postgres`, `timescaledb`. Default is `sqlite`. |
| `--version <vX.Y.Z>` | Install a specific version, including pre-releases (e.g., `v0.5.2`, `v1.0.0-beta.1`)       |
| `--dev`              | Install the latest development version (only for versions **before v1.0.0**)                |
| `--pre-release`      | Install the latest pre-release version (only for versions **v1.0.0 and later**)             |
| `--ssl`              | Enable SSL setup prompt during install (Domain/IP/Custom certificate).                      |
| `--no-ssl`           | Skip SSL setup during install (dashboard will bind to localhost only).                      |
| `--ssl-domain`       | Issue SSL cert directly for domain mode (example: `--ssl-domain panel.example.com`).        |
| `--ssl-http-port`    | ACME HTTP challenge port for SSL issuance (default: `80`).                                  |

> ℹ️ `postgres` and `timescaledb` are only supported in versions **v1.0.0 and later**.
> ℹ️ Pre-release versions (e.g., `v1.0.0-beta.1`) can also be installed using `--version`.
> ℹ️ During install, SSL menu supports: Let's Encrypt Domain, Let's Encrypt IP (short-lived), Custom cert/key path, or No SSL.

---

### 📦 Examples

- **Install pasarguard with SQLite**:

  ```bash
  sudo bash -c "$(curl -fsSL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh)" @ install
  ```

- **Install pasarguard with MySQL**:

  ```bash
  sudo bash -c "$(curl -fsSL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh)" @ install --database mysql
  ```

- **Install pasarguard with PostgreSQL**:

  ```bash
  sudo bash -c "$(curl -fsSL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh)" @ install --database postgresql
  ```

- **Install pasarguard with TimescaleDB(v1+ only) and pre-release version**:

  ```bash
  sudo bash -c "$(curl -fsSL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh)" @ install --database timescaledb --pre-release
  ```

- **Install pasarguard with MariaDB and Dev branch**:

  ```bash
  sudo bash -c "$(curl -fsSL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh)" @ install --database mariadb --dev
  ```

- **Install pasarguard with MariaDB and Manual version**:

  ```bash
  sudo bash -c "$(curl -fsSL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh)" @ install --database mariadb --version v0.5.2
  ```

## Installing Node

### Standalone packages

- Farsi guide: [PgNode Standalone](iran-sanction/README-pg-node-standalone.fa.md)
- Latest release file: [pg-node-standalone.tar.gz](https://github.com/PasarGuard/scripts/releases/latest/download/pg-node-standalone.tar.gz)

### 📦 Examples (TTY-safe, short form)

- **Install Node**

  ```bash
  sudo bash -c "$(curl -fsSL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh)" @ install
  ```

- **Install Node Manual version:**

  ```bash
  sudo bash -c "$(curl -fsSL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh)" @ install --version 0.1.0
  ```

- **Install Node pre-release version:**

  ```bash
  sudo bash -c "$(curl -fsSL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh)" @ install --pre-release
  ```

- **Install Node with custom name:**

  ```bash
  sudo bash -c "$(curl -fsSL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh)" @ install --name Node2
  ```

  > 📌 **Tip:**
  > The `--name` flag lets you install and manage multiple Node instances using this script.
  > For example, running with `--name pg-node2` will create and manage a separate instance named `pg-node2`.
  > You can then control each node individually using its assigned name.

- **Update or Change Xray-core Version**:

  ```bash
  sudo pg-node core-update
  ```

Use `help` to view all commands:
`pg-node help`

### node-serviced update safety

`service-install`, `service-update`, and `service-uninstall` serialize mutations with a persistent `flock` lock and require
Linux `setsid` (both normally provided by `util-linux`). Older `setsid` versions without `--wait` are supported. Update and
rollback probes also require Bash, `awk`, `curl`, and `openssl`; release installation requires `jq`, `tar`, and a SHA-256
tool (`sha256sum` or `shasum`).

`service-start`, `service-stop`, and `service-restart` take the same lock, so they cannot restart the service midway
through a binary swap. They wait `NODE_SERVICE_LIFECYCLE_LOCK_WAIT_SECONDS` (default `30`) for an update in progress
before giving up, and their `systemctl` call is time-bounded rather than able to hang indefinitely.

Readiness uses the same `.env` semantics as `node-serviced`: optional `export`, `=` or `:`, last duplicate wins, comments,
single- and double-quoted values (including values spanning several lines), double-quote escapes, and prior-key
expansion. The file is parsed as data and is never sourced or evaluated. A malformed entry is charged to its own key, so
it cannot hide the keys the probe actually reads. `NODE_SERVICE_READINESS_DEADLINE_SECONDS` bounds the complete readiness
loop (default `30`, matching the unit's `TimeoutStartSec`), while `NODE_SERVICE_READINESS_TIMEOUT_SECONDS` bounds an
individual authenticated HTTPS probe. Set `NODE_SERVICE_READINESS_ATTEMPTS` to cap the number of probes as well; by
default the deadline alone bounds the wait.

The probe needs `curl` 7.49 or newer for `--connect-to` and `openssl` 1.1.1 or newer for `x509 -ext subjectAltName`.
Where either is older, or where the certificate in `SSL_CERT_FILE` cannot be verified against what the running daemon
presents (during a renewal, for instance), the probe reports that it could not run. An update then falls back to the
systemd unit state with a warning instead of rolling back an installation that is working.
