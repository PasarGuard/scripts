# PasarGuard CLI Command Reference

Comprehensive command-line interface documentation for **PasarGuard Panel** (`pasarguard.sh` / `pasarguard`) and **PasarGuard Node** (`pg-node.sh` / `pg-node`).

---

## Table of Contents
- [PasarGuard Panel (`pasarguard`)](#pasarguard-panel-pasarguard)
  - [Global Flags & Options](#panel-global-flags--options)
  - [Command Reference](#panel-command-reference)
  - [Directory Structure](#panel-directory-structure)
- [PasarGuard Node (`pg-node`)](#pasarguard-node-pg-node)
  - [Global Flags & Options](#node-global-flags--options)
  - [Command Reference](#node-command-reference)
  - [Systemd Service Commands](#node-systemd-service-commands)
  - [Directory Structure](#node-directory-structure)

---

## PasarGuard Panel (`pasarguard`)

The Panel CLI manages the core web interface, background orchestration, database engines, connection poolers, and disaster recovery.

```bash
pasarguard [command] [options]
```

### Panel Global Flags & Options

The following flags can be supplied when running `pasarguard install`:

| Flag | Argument | Description | Default |
| :--- | :--- | :--- | :--- |
| `--database` | `sqlite` \| `mysql` \| `mariadb` \| `postgresql` \| `timescaledb` | Database backend engine. (PostgreSQL and TimescaleDB require v1.0.0+) | `sqlite` |
| `--version` | `<tag>` (e.g. `v0.5.2`, `v1.0.0-beta.1`) | Install an explicit release tag. | `latest` |
| `--dev` | *(flag)* | Install the latest development build (only valid for v0.x releases). | Disabled |
| `--pre-release`| *(flag)* | Install the latest pre-release build (for v1.0.0 and later). | Disabled |
| `--ssl` | *(flag)* | Launch interactive SSL certificate setup during installation. | Enabled prompt |
| `--no-ssl` | *(flag)* | Skip SSL configuration. Panel binds to `localhost` / HTTP only. | - |
| `--ssl-domain` | `<domain>` (e.g. `panel.example.com`) | Automatically request Let's Encrypt SSL certificate for domain. | - |
| `--ssl-http-port` | `<port>` | Port to use for ACME HTTP-01 challenge verification. | `80` |

---

### Panel Command Reference

#### `install`
Installs PasarGuard Panel, sets up directories, downloads Compose configurations, configures database credentials, prompts for SSL, and starts the container stack.
```bash
sudo pasarguard install --database timescaledb --pre-release
```

#### `install-script`
Installs the `pasarguard` CLI command globally into `/usr/local/bin/pasarguard` and places shared libraries into `/usr/local/lib/pasarguard-scripts/lib/`.
```bash
sudo ./pasarguard.sh install-script
```

#### `install-node`
Helper shortcut that fetches and executes `pg-node.sh install` to set up a node instance on the current machine.
```bash
sudo pasarguard install-node
```

#### `up`
Starts all PasarGuard Docker Compose services in detached mode (`docker compose up -d`).
```bash
sudo pasarguard up
```

#### `down`
Stops and removes all running containers in the PasarGuard stack.
```bash
sudo pasarguard down
```

#### `restart`
Restarts the container stack. Prompts to follow service logs.
```bash
sudo pasarguard restart
```

#### `status`
Displays real-time container states, port bindings, database connectivity status, and disk usage for data directories.
```bash
sudo pasarguard status
```

#### `logs`
Streams live logs from all stack containers (or specific services). Press `Ctrl+C` to exit.
```bash
sudo pasarguard logs
```

#### `cli`
Opens an interactive CLI session inside the main PasarGuard panel container.
```bash
sudo pasarguard cli
```

#### `tui`
Launches the curses-based Terminal User Interface (TUI) for interactive stack management.
```bash
sudo pasarguard tui
```

#### `backup`
Executes an immediate manual backup of the PasarGuard database, configuration files, and data volumes into a compressed archive.
```bash
sudo pasarguard backup
```

#### `backup-service`
Opens the interactive configuration menu for automated recurring backups. Allows setting cron schedule intervals (from 5 minutes to daily), configuring Telegram bot token and chat ID, and enabling proxy routing for restricted networks.
```bash
sudo pasarguard backup-service
```

#### `restore`
Restores PasarGuard state from a previous backup archive (ZIP or tarball). Features pre-restore validation, atomic database replacements, and automated cross-version TimescaleDB upgrades.
```bash
sudo pasarguard restore
```

#### `update`
Pulls updated Docker images for the stack and recreates containers while preserving existing database and configuration state.
```bash
sudo pasarguard update
```

#### `uninstall`
Completely stops the container stack, optionally purges application data directories (`/opt/pasarguard`, `/var/lib/pasarguard`), and removes binary launchers.
```bash
sudo pasarguard uninstall
```

#### `edit`
Opens `/opt/pasarguard/docker-compose.yml` in `$EDITOR` (nano/vi) for manual configuration adjustments.
```bash
sudo pasarguard edit
```

#### `edit-env`
Opens `/opt/pasarguard/.env` in `$EDITOR` for adjusting environment variables and credentials.
```bash
sudo pasarguard edit-env
```

#### `version-script` / `script-version`
Prints the execution banner displaying the active script version and exact Git commit SHA.
```bash
pasarguard version-script
```

#### `completion`
Generates and installs tab-completion scripts into `/etc/bash_completion.d/pasarguard`.
```bash
sudo pasarguard completion
```

#### `help`
Displays the quick reference help screen.
```bash
pasarguard help
```

---

### Panel Directory Structure

| Path | Purpose |
| :--- | :--- |
| `/opt/pasarguard/` | Application root: houses `docker-compose.yml`, `.env`, and local backups. |
| `/opt/pasarguard/backup/` | Local backup storage directory for generated archives. |
| `/var/lib/pasarguard/` | Persistent state for panel assets, SQLite databases, and user configurations. |
| `/var/lib/postgresql/pasarguard/` | Dedicated database data volume when using PostgreSQL or TimescaleDB. |
| `/usr/local/bin/pasarguard` | System-wide executable symlink. |
| `/usr/local/lib/pasarguard-scripts/` | Shared libraries (`common.sh`, `system.sh`, `env.sh`, `pasarguard-backup.sh`, etc.). |
| `/etc/bash_completion.d/pasarguard` | Bash autocompletion configuration. |

---

## PasarGuard Node (`pg-node`)

The Node CLI manages remote proxy worker nodes, certificates, systemd background daemons, and Xray-core binaries.

```bash
pg-node [command] [options]
```

### Node Global Flags & Options

| Flag | Argument | Description | Default |
| :--- | :--- | :--- | :--- |
| `-y`, `--yes` | *(flag)* | Automatic confirmation. Answers default values to interactive prompts. | Off |
| `--name` | `<NAME>` | Target a custom node instance (enables multi-node on a single host). | `pg-node` |

---

### Node Command Reference

#### `install`
Installs or re-installs a worker node instance.

**Options:**
- `-v`, `--version <VERSION>`: Install specific node image version.
- `--pre-release`: Install latest pre-release image.
- `--name <NAME>`: Custom instance name (creates `/opt/<NAME>` and `/var/lib/<NAME>`).
- `--override`: Force overwrite existing node instance.
- `--api-key <KEY>`: Pre-configure API authentication key.
- `--use-grpc`: Connect to panel over gRPC protocol (default).
- `--use-rest`: Connect to panel over REST protocol.
- `--service-port <PORT>`: Port for proxy traffic.
- `--api-port <PORT>`: Port for node daemon API.
- `--self-signed`: Automatically generate self-signed TLS certificates with SAN.
- `--cert-path <PATH>`: Path to existing public TLS certificate.
- `--key-path <PATH>`: Path to existing private TLS key.
- `--san-entries <ENTRIES>`: Comma-separated list of IP/DNS SAN entries.
- `--install-service`: Automatically install and start the systemd unit.
- `--no-install-service`: Skip systemd service registration.

```bash
sudo pg-node install --name node-eu1 --use-grpc --self-signed
```

#### `up` / `down` / `restart`
Control the node container stack lifecycle.
- `restart` supports `-n, --no-logs` to avoid tailing logs and `--no-restart-service` to skip restarting the companion systemd unit.

#### `status`
Displays node IP address, active service port, certificate path, API key, and current Xray-core version.
```bash
sudo pg-node status
```

#### `logs`
Streams real-time container logs.
```bash
sudo pg-node logs
```

#### `core-update`
Updates or switches the underlying `Xray-core` binary using [install_core.sh](install_core.sh).
- `--version <TAG>`: Specify release tag (e.g. `v1.8.24` or `latest`).
```bash
sudo pg-node core-update --version latest
```

#### `geofiles`
Downloads and updates `geoip.dat` and `geosite.dat` routing assets from official distributions.
```bash
sudo pg-node geofiles
```

#### `renew-cert`
Regenerates self-signed SSL/TLS certificates and Subject Alternative Names (SANs) for the node.
```bash
sudo pg-node renew-cert
```

#### `edit` / `edit-env`
Edits the node's `docker-compose.yml` or `.env` file in the system default editor.

---

### Node Systemd Service Commands

The companion `pg-node-service` background daemon maintains synchronization and telemetry with the central panel.

| Command | Description |
| :--- | :--- |
| `service-install` | Installs the systemd unit (`pg-node-service.service`) and starts it. |
| `service-start` | Starts the systemd service. |
| `service-stop` | Stops the systemd service. |
| `service-restart` | Restarts the systemd service. |
| `service-status` | Displays systemctl status output for the service. |
| `service-logs` | Displays journalctl logs (`-n, --no-follow` displays without trailing). |
| `service-update` | Refreshes the `pg-node-service.sh` binary. |
| `service-uninstall` | Stops, disables, and removes the systemd unit. |

---

### Node Directory Structure

| Path | Purpose |
| :--- | :--- |
| `/opt/pg-node/` (or `/opt/<NAME>/`) | Node compose stack and environment files. |
| `/var/lib/pg-node/` (or `/var/lib/<NAME>/`) | Working directory for Xray configurations and SSL certificates. |
| `/var/lib/pg-node/certs/` | TLS certificates (`ssl_cert.pem`, `ssl_key.pem`). |
| `/usr/local/share/xray/` | Installed `geoip.dat` and `geosite.dat` databases. |
| `/usr/local/bin/xray` | Installed Xray-core binary. |
| `/etc/systemd/system/pg-node-service.service` | Systemd service unit. |
