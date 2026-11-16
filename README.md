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

### Node certificate management

New `pg-node install` runs default to Let's Encrypt IP certificates. Unattended
installation requires `--ssl-ip YOUR_PUBLIC_IPV4`; optionally add `--ssl-ipv6`.
Use `--ssl-domain DOMAIN`, paired `--cert-path`/`--key-path`, or explicit
`--self-signed` to choose another source. `--ssl-http-port` (`--ssl-port`) changes
the local HTTP-01 listener; public port 80 must still reach it.

`--no-ssl` is exclusively for private backends behind an external TLS web server.
The panel must use the web server's TLS endpoints for both node and maintenance
requests. API-key authentication stays required. Certificate source metadata is
stored under the instance data directory; `renew-cert` follows that source and
`show-cert` displays its identity, expiry, fingerprint and legacy PEM.

Old unattended commands relying on implicit self-signed certificates must add
`--self-signed`. Routine updates preserve certificate paths and files. See
[the node TLS deployment guide](https://github.com/PasarGuard/node/blob/main/docs/node-tls.md)
for nginx examples, verification fields, renewal, private bindings and rollback.
