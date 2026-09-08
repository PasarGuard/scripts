<div align="center">

# PasarGuard Scripts

**Modern deployment, orchestration, and disaster recovery suite for PasarGuard Panel and Nodes.**

[![Unit Tests](https://github.com/PasarGuard/scripts/actions/workflows/command-tests.yml/badge.svg)](https://github.com/PasarGuard/scripts/actions/workflows/command-tests.yml)
[![Backup Restore Tests](https://github.com/PasarGuard/scripts/actions/workflows/backup-restore.yml/badge.svg)](https://github.com/PasarGuard/scripts/actions/workflows/backup-restore.yml)
[![Script Safety](https://github.com/PasarGuard/scripts/actions/workflows/script-update-safety.yml/badge.svg)](https://github.com/PasarGuard/scripts/actions/workflows/script-update-safety.yml)
[![License](https://img.shields.io/github/license/PasarGuard/scripts)](LICENSE)
[![Release](https://img.shields.io/github/v/release/PasarGuard/scripts)](https://github.com/PasarGuard/scripts/releases)

[English](README.md) • [راهنمای فارسی (Standalone)](iran-sanction/README-pasarguard-standalone.fa.md) • [راهنمای فارسی نود (Standalone)](iran-sanction/README-pg-node-standalone.fa.md)

</div>

---

## 📑 Table of Contents
- [Overview](#-overview)
- [Architecture](#-architecture)
- [System Requirements & OS Support](#-system-requirements--os-support)
- [Quick Start](#-quick-start)
  - [1. Installing PasarGuard Panel](#1-installing-pasarguard-panel)
  - [2. Installing a Worker Node](#2-installing-a-worker-node)
- [Installation Options](#-installation-options)
- [Master CLI Reference](#-master-cli-reference)
  - [Panel Commands (`pasarguard`)](#panel-commands-pasarguard)
  - [Node Commands (`pg-node`)](#node-commands-pg-node)
- [Database Support Matrix](#-database-support-matrix)
- [Backups & Disaster Recovery](#-backups--disaster-recovery)
- [SSL & TLS Security](#-ssl--tls-security)
- [Domestic Mirrors & Air-Gapped Networks](#-domestic-mirrors--air-gapped-networks)
- [Documentation Index](#-documentation-index)
- [Contributing & Testing](#-contributing--testing)

---

## 🌟 Overview

**PasarGuard Scripts** provides battle-tested automation for deploying and maintaining production-grade PasarGuard infrastructure:
- **PasarGuard Panel (`pasarguard.sh` / `pasarguard`)**: Orchestrates the web dashboard, database engines (SQLite, MySQL, MariaDB, PostgreSQL, TimescaleDB), PgBouncer connection pooling, admin web UIs (pgAdmin, phpMyAdmin), and disaster recovery.
- **PasarGuard Node (`pg-node.sh` / `pg-node`)**: Manages remote worker nodes, systemd background daemons (`pg-node-service`), Xray-core versions, routing geofiles, and TLS certificates.
- **Disaster Recovery**: Automated recurring backups to Telegram with proxy support, atomic multi-database dumps, and automatic cross-version TimescaleDB upgrades.
- **Domestic Mirror Optimization**: Benchmark and apply domestic Iranian mirrors for APT and Docker when deploying behind restricted network environments.

---

## 🏗️ Architecture

```
                               ┌─────────────────────────────────────────┐
                               │             PasarGuard Panel            │
                               │   (Web Dashboard & Background Tasks)    │
                               └──────┬──────────────────────┬───────────┘
                                      │                      │
                   ┌──────────────────┴────────┐      ┌──────┴────────────────────┐
                   ▼                           ▼      ▼                           ▼
          ┌─────────────────┐         ┌────────────────────┐            ┌───────────────────┐
          │  SQLite / MySQL │         │     PgBouncer      │            │ Automated Backup  │
          │    / MariaDB    │         │  (Port 6432 Pool)  │            │  (Telegram + Cron)│
          └─────────────────┘         └────────┬───────────┘            └───────────────────┘
                                               │
                                      ┌────────┴───────────┐
                                      │ PostgreSQL 17 /    │
                                      │   TimescaleDB      │
                                      └────────────────────┘
                                               ▲
                                               │ (Encrypted gRPC / REST)
                   ┌───────────────────────────┴───────────────────────────┐
                   ▼                                                       ▼
        ┌─────────────────────┐                                 ┌─────────────────────┐
        │  Worker Node: EU-1  │                                 │  Worker Node: AS-1  │
        │  (pg-node + Xray)   │                                 │  (pg-node + Xray)   │
        └─────────────────────┘                                 └─────────────────────┘
```

---

## 🖥️ System Requirements & OS Support

| Operating System | Package Manager | Status |
| :--- | :--- | :--- |
| **Ubuntu 20.04 / 22.04 / 24.04** | `apt-get` | Supported (Primary) |
| **Debian 11 / 12** | `apt-get` | Supported |
| **CentOS / RHEL 8+** | `dnf` / `yum` | Supported |
| **Rocky Linux / AlmaLinux 8+** | `dnf` | Supported |
| **Fedora 38+** | `dnf` | Supported |
| **Arch Linux** | `pacman` | Supported |
| **openSUSE Leap / Tumbleweed** | `zypper` | Supported |

**Prerequisites**:
- Linux x86_64 or ARM64
- Root or `sudo` privileges
- Docker and Docker Compose (automatically installed if absent)
- `curl`, `tar`, `gzip`

---

## 🚀 Quick Start

### 1. Installing PasarGuard Panel

Run the single-line installer on your main server:

```bash
# Default install (SQLite, interactive SSL)
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/PasarGuard/scripts/main/pasarguard.sh)" @ install

# High-concurrency production install (TimescaleDB + PgBouncer)
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/PasarGuard/scripts/main/pasarguard.sh)" @ install --database timescaledb --pre-release
```

Once installed, control the panel at any time using the global `pasarguard` command:
```bash
sudo pasarguard status
```

---

### 2. Installing a Worker Node

On each remote worker node, execute the node installer:

```bash
# Standard node installation
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/PasarGuard/scripts/main/pg-node.sh)" @ install

# Multi-instance node with custom name
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/PasarGuard/scripts/main/pg-node.sh)" @ install --name node-de1 --self-signed
```

Once installed, manage the node using the global `pg-node` command:
```bash
sudo pg-node status
```

---

## 🔧 Installation Options

The following flags can be supplied to `pasarguard install`:

| Option | Values | Description |
| :--- | :--- | :--- |
| `--database` | `sqlite`, `mysql`, `mariadb`, `postgresql`, `timescaledb` | Database backend engine. Default is `sqlite`. *(PostgreSQL and TimescaleDB require v1.0.0+)* |
| `--version <TAG>` | e.g. `v0.5.2`, `v1.0.0-beta.1` | Pin the installation to an explicit release version tag. |
| `--dev` | *(flag)* | Install latest development image *(v0.x releases only)*. |
| `--pre-release` | *(flag)* | Install latest pre-release image *(v1.0.0 and later)*. |
| `--ssl` | *(flag)* | Launch interactive SSL certificate configuration wizard during setup. |
| `--no-ssl` | *(flag)* | Skip SSL setup (panel binds to localhost for reverse proxy fronting). |
| `--ssl-domain <DOMAIN>` | e.g. `panel.example.com` | Automatically issue a Let's Encrypt SSL certificate for the domain. |
| `--ssl-http-port <PORT>` | e.g. `80` | Port used to verify ACME HTTP-01 challenge. Default: `80`. |

---

## ⌨️ Master CLI Reference

### Panel Commands (`pasarguard`)

| Command | Description |
| :--- | :--- |
| `pasarguard install` | Full panel setup wizard with database and SSL selection. |
| `pasarguard install-script` | Installs global `pasarguard` CLI command and shared libraries to system. |
| `pasarguard install-node` | Shortcut to download and launch the node installer. |
| `pasarguard up` | Starts all containers in the stack (`docker compose up -d`). |
| `pasarguard down` | Stops and tears down stack containers. |
| `pasarguard restart` | Restarts all containers and prompts to tail logs. |
| `pasarguard status` | Real-time container health, port mappings, and database status. |
| `pasarguard logs` | Live log streaming for all stack containers. |
| `pasarguard cli` | Launches interactive CLI session inside the panel container. |
| `pasarguard tui` | Opens curses-based Terminal User Interface (TUI). |
| `pasarguard backup` | Immediate manual backup of database, configuration, and state. |
| `pasarguard backup-service` | Configures automated recurring Telegram backups and cron schedule. |
| `pasarguard restore` | Restores panel state and database with cross-version compatibility. |
| `pasarguard update` | Pulls latest Docker images and recreates containers cleanly. |
| `pasarguard uninstall` | Removes containers, services, and optional application data directories. |
| `pasarguard edit` | Opens `/opt/pasarguard/docker-compose.yml` in default editor. |
| `pasarguard edit-env` | Opens `/opt/pasarguard/.env` in default editor. |
| `pasarguard completion` | Installs Bash/Zsh tab-completion scripts. |
| `pasarguard version-script` | Shows current script version and active Git commit SHA. |
| `pasarguard help` | Displays quick reference help banner. |

👉 *For an exhaustive breakdown of panel commands and options, see [docs/cli-reference.md](docs/cli-reference.md).*

---

### Node Commands (`pg-node`)

| Command | Description |
| :--- | :--- |
| `pg-node install` | Installs or reinstalls the worker node container and service. |
| `pg-node up` / `down` / `restart` | Controls the node container stack lifecycle. |
| `pg-node status` | Displays IP, active service port, certificate path, and Xray version. |
| `pg-node logs` | Streams live logs from the node container. |
| `pg-node core-update` | Updates or switches the installed Xray-core binary version. |
| `pg-node geofiles` | Downloads official `geoip.dat` and `geosite.dat` routing assets. |
| `pg-node renew-cert` | Regenerates self-signed TLS certificates with SAN entries. |
| `pg-node service-install` | Registers and enables the companion `systemd` service daemon. |
| `pg-node service-status` | Inspects systemd service status (`pg-node-service.service`). |
| `pg-node service-logs` | Tails journalctl logs for the background service. |
| `pg-node service-restart` | Restarts the background service daemon. |
| `pg-node service-uninstall` | Stops, disables, and removes the systemd service. |

👉 *Multi-node support: Pass `--name <NAME>` to any node command to manage multiple instances independently on a single server (e.g. `pg-node --name node2 status`).*

---

## 🗄️ Database Support Matrix

PasarGuard supports 5 database engines tailored for different workloads:

| Engine | Ideal Workload | Admin Web UI | Concurrency Mechanism |
| :--- | :--- | :--- | :--- |
| **SQLite** | Under 500 active users | Embedded | WAL mode (`PRAGMA wal_checkpoint`) |
| **MySQL 8.0** | General multi-service | phpMyAdmin (port 8010) | InnoDB transactions |
| **MariaDB** | High-performance open alternative | phpMyAdmin (port 8010) | Aria / InnoDB |
| **PostgreSQL 17** | 1,000+ concurrent clients | pgAdmin 4 (port 8010) | PgBouncer transaction pooling (port 6432) |
| **TimescaleDB** | High-throughput metrics & analytics | pgAdmin 4 (port 8010) | Hypertables + PgBouncer pooling |

👉 *Read the full database tuning guide in [docs/database-configurations.md](docs/database-configurations.md).*

---

## 💾 Backups & Disaster Recovery

PasarGuard features an automated disaster recovery engine:
1. **Atomic Dumps**: Creates consistent snapshots. SQLite WAL files are safely truncated, and PostgreSQL/TimescaleDB clusters are dumped with explicit table manifests and role permissions.
2. **Scheduled Telegram Dispatch**: Configure recurring cron intervals (from 5 minutes to daily) using `pasarguard backup-service`. Backups are dispatched directly to your Telegram chat or channel.
3. **Proxy Support**: Connect via SOCKS5 or HTTP proxy (`BACKUP_PROXY_URL`) to bypass Telegram network restrictions.
4. **TimescaleDB Compatibility Migrations**: The restore engine automatically detects cross-version TimescaleDB archives and provisions isolated `template0` staging containers to upgrade hypertable schemas without version locks.
5. **Fail-Safe Rollback**: Rejects truncated dumps and path traversal attacks before touching live data. If a restore encounters issues, diagnostics are logged to `/opt/pasarguard/backup/pasarguard_restore_error.log`.

👉 *Read the disaster recovery runbook in [docs/backup-and-restore.md](docs/backup-and-restore.md).*

---

## 🔒 SSL & TLS Security

PasarGuard provides 4 SSL operational modes:
- **Let's Encrypt Domain**: Fully automated HTTP-01 challenge verification via `acme.sh`.
- **Let's Encrypt IP**: Short-lived public IP certificates when no domain is configured.
- **Custom Certificate**: Bring your own CA-signed certificate chain and private key.
- **Node Self-Signed with SAN**: Automatic Subject Alternative Name (SAN) generation for remote nodes with private key permissions hardened to `0600`.

👉 *Read the full security and certificate guide in [docs/ssl-and-certificates.md](docs/ssl-and-certificates.md).*

---

## 🇮🇷 Domestic Mirrors & Air-Gapped Networks

For servers operating under Iranian network sanctions and international filtering:
- **`mirror.sh` Benchmark Suite**: Measures latency and throughput against domestic Debian, Ubuntu, and Docker Registry mirrors (ArvanCloud, HamDocker, IranServer, MobinHost, IUT) and automatically configures `/etc/apt/sources.list` and `/etc/docker/daemon.json`.
- **Standalone Offline Bundles**: Pre-packaged tarballs containing all required compose templates and offline scripts without requiring GitHub access during installation.
  - [pasarguard-standalone.tar.gz](https://github.com/PasarGuard/scripts/releases/latest/download/pasarguard-standalone.tar.gz)
  - [pg-node-standalone.tar.gz](https://github.com/PasarGuard/scripts/releases/latest/download/pg-node-standalone.tar.gz)

👉 *Read the English standalone guide in [docs/offline-and-sanctions.md](docs/offline-and-sanctions.md) or the [راهنمای فارسی](iran-sanction/README-pasarguard-standalone.fa.md).*

---

## 📚 Documentation Index

| Guide | Description |
| :--- | :--- |
| **[CLI Reference](docs/cli-reference.md)** | Full command syntax, options, directory paths, and exit codes for Panel and Node. |
| **[Backup & Disaster Recovery](docs/backup-and-restore.md)** | Backup architecture, Telegram automation, proxy routing, and TimescaleDB migrations. |
| **[Database Configurations](docs/database-configurations.md)** | Engine comparisons, PgBouncer pooling, pgAdmin/phpMyAdmin, and memory tuning. |
| **[SSL & TLS Certificates](docs/ssl-and-certificates.md)** | Let's Encrypt ACME setup, custom certs, SAN entries, and node TLS verification. |
| **[Offline & Sanctions Guide](docs/offline-and-sanctions.md)** | Domestic mirror benchmarking (`mirror.sh`) and air-gapped standalone deployment. |
| **[Environment Variables](docs/environment-variables.md)** | Complete `.env` configuration dictionary for Panel and Worker Nodes. |

---

## 🤝 Contributing & Testing

Contributions are welcome! Please review [CONTRIBUTING.md](CONTRIBUTING.md) for development workflows and coding standards.

### Running the Test Suite
PasarGuard includes a master test runner executing all unit and safety test suites:

```bash
bash tests/run_all.sh
```

---

## 📄 License

This project is licensed under the terms of the repository's open source license.
