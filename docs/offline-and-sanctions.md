# PasarGuard Offline & Sanctions Guide (Domestic Mirrors)

A guide for deploying PasarGuard in network-restricted environments, air-gapped servers, and hosts requiring domestic Iranian mirrors.

---

## Table of Contents
- [Overview](#overview)
- [Domestic Mirror Optimization (`mirror.sh`)](#domestic-mirror-optimization-mirrorsh)
  - [How Benchmarking Works](#how-benchmarking-works)
  - [Supported Mirror Providers](#supported-mirror-providers)
  - [Running the Benchmark Manually](#running-the-benchmark-manually)
- [Standalone / Air-Gapped Deployment](#standalone--air-gapped-deployment)
  - [Scenario 1: Host has Restricted Internet Access](#scenario-1-host-has-restricted-internet-access)
  - [Scenario 2: Completely Air-Gapped Host (No Internet)](#scenario-2-completely-air-gapped-host-no-internet)
- [Standalone Package Contents](#standalone-package-contents)
- [Persian Documentation Links](#persian-documentation-links)

---

## Overview

Due to international sanctions and network filtering, servers located in Iran often experience throttled, blocked, or high-latency connections to:
- Official Ubuntu/Debian APT mirrors (`archive.ubuntu.com`, `deb.debian.org`).
- Docker Hub (`registry-1.docker.io`).
- GitHub raw content and releases.

PasarGuard includes a dedicated subsystem under [`iran-sanction/`](../iran-sanction/) that solves this through automated mirror selection and pre-packaged standalone distributions.

---

## Domestic Mirror Optimization (`mirror.sh`)

[`iran-sanction/mirror.sh`](../iran-sanction/mirror.sh) is an automated benchmarking and configuration utility.

### How Benchmarking Works
When configuring a server in Iran:
1. **Latency Probing**: Measures round-trip time (`time_total`) to each domestic mirror endpoint using `curl`.
2. **Throughput Sampling**: Downloads multiple chunks (`SAMPLES=3`, `TIMEOUT=8s`) to determine real-world download speed (`speed_download`).
3. **Composite Scoring**: Calculates a weighted score:
   $$\text{Score} = (0.70 \times \text{Speed}) + (0.30 \times \text{Latency})$$
4. **Automated Application**:
   - Replaces APT repository mirrors with the fastest responsive HTTPS mirror in `/etc/apt/sources.list` (ensuring encrypted transport).
   - Adds registry mirrors to `/etc/docker/daemon.json` (`registry-mirrors`).
   - Reloads the Docker daemon (`systemctl daemon-reload && systemctl restart docker`).

### Supported Mirror Providers
- **ArvanCloud**: `mirror.arvancloud.ir`, `docker.arvancloud.ir`
- **HamDocker**: `hub.hamdocker.ir`
- **IranServer**: `mirror.iranserver.com`, `docker.iranserver.com`
- **MobinHost**: `mirror.mobinhost.com`, `docker.mobinhost.com`
- **Isfahan University of Technology (IUT)**: `repo.iut.ac.ir`

### Running the Benchmark Manually

To run the mirror selection test directly:
```bash
sudo bash iran-sanction/mirror.sh
```

To run in dry-run mode (tests speeds without writing configuration files):
```bash
DRY_RUN=true sudo bash iran-sanction/mirror.sh
```

---

## Standalone / Air-Gapped Deployment

Standalone packages include all required Compose templates, installer scripts, and helper libraries so they do not require fetching files from GitHub during installation.

### Scenario 1: Host has Restricted Internet Access

If the server can reach GitHub releases or domestic mirrors:
```bash
curl -LO https://github.com/PasarGuard/scripts/releases/latest/download/pasarguard-standalone.tar.gz
tar -xzf pasarguard-standalone.tar.gz
cd pasarguard-standalone
chmod +x iran-sanction/pasarguard-standalone.sh
sudo ./iran-sanction/pasarguard-standalone.sh install-script
sudo pasarguard install --database timescaledb
```

### Scenario 2: Completely Air-Gapped Host (No Internet)

Because air-gapped hosts have no internet connectivity and standalone bundles contain configuration templates and scripts rather than container images, required Docker images must be pre-provisioned:

1. Download the release bundle onto an external computer with internet access:
   - [pasarguard-standalone.tar.gz](https://github.com/PasarGuard/scripts/releases/latest/download/pasarguard-standalone.tar.gz)
   - [pg-node-standalone.tar.gz](https://github.com/PasarGuard/scripts/releases/latest/download/pg-node-standalone.tar.gz)

2. Pull and save the required Docker images on the connected machine (or push to an accessible local registry):
   ```bash
   # Panel stack image (example for default SQLite install):
   docker pull ghcr.io/pasarguard/panel:latest
   docker save ghcr.io/pasarguard/panel:latest -o pasarguard-images.tar
   ```

3. Transfer both the release bundle and image archive to the air-gapped host via `scp`, SFTP, or USB drive:
   ```bash
   scp pasarguard-standalone.tar.gz pasarguard-images.tar root@server-ip:/tmp/
   ```

4. Load Docker images and install on the server:
   ```bash
   # Import the container images into Docker
   docker load -i /tmp/pasarguard-images.tar

   # Extract and install standalone scripts
   cd /tmp
   tar -xzf pasarguard-standalone.tar.gz
   cd pasarguard-standalone
   sudo ./iran-sanction/pasarguard-standalone.sh install-script
   sudo pasarguard install
   ```

---

## Standalone Package Contents

The `pasarguard-standalone.tar.gz` bundle contains:
```
pasarguard-standalone/
├── pasarguard.sh
├── iran-sanction/
│   ├── pasarguard-standalone.sh
│   └── mirror.sh
├── lib/
│   ├── common.sh
│   ├── docker.sh
│   ├── env.sh
│   ├── github.sh
│   ├── pasarguard-backup.sh
│   ├── pasarguard-restore.sh
│   └── system.sh
└── docker-compose/
    ├── pasarguard-sqlite.yml
    ├── pasarguard-mysql.yml
    ├── pasarguard-mariadb.yml
    ├── pasarguard-postgresql.yml
    └── pasarguard-timescaledb.yml
```

---

## Persian Documentation Links
Native Persian (Farsi) documentation for standalone packages is available here:
- [راهنمای Pasarguard Standalone (Farsi)](../iran-sanction/README-pasarguard-standalone.fa.md)
- [راهنمای PgNode Standalone (Farsi)](../iran-sanction/README-pg-node-standalone.fa.md)
