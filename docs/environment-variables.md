# PasarGuard Environment Variables Reference

Complete reference for configuration parameters found in `/opt/pasarguard/.env` (Panel) and `/opt/pg-node/.env` (Worker Node).

---

## Table of Contents
- [Panel Core Settings](#panel-core-settings)
- [Database Configuration](#database-configuration)
- [PostgreSQL & PgBouncer Tuning](#postgresql--pgbouncer-tuning)
- [pgAdmin Management](#pgadmin-management)
- [SSL & HTTPS Configuration](#ssl--https-configuration)
- [Backup & Telegram Notifications](#backup--telegram-notifications)
- [Worker Node Settings (`pg-node`)](#worker-node-settings-pg-node)

---

## Panel Core Settings

| Variable | Description | Example | Default |
| :--- | :--- | :--- | :--- |
| `APP_NAME` | Identifier for the panel stack and compose project name. | `pasarguard` | `pasarguard` |
| `UVICORN_PORT` | HTTP/HTTPS port the panel server listens on. | `8000` | `8000` |
| `ALLOWED_ORIGINS` | Permitted CORS origins for API requests. | `["http://localhost:8000"]` | `*` |

---

## Database Configuration

| Variable | Description | Example |
| :--- | :--- | :--- |
| `SQLALCHEMY_DATABASE_URL` | SQLAlchemy connection string used by the backend. | `postgresql://user:pass@127.0.0.1:6432/pasarguard` |
| `DB_NAME` | Primary database name. | `pasarguard` |
| `DB_USER` | Primary database user. | `pasarguard` |
| `DB_PASSWORD` | Primary database user password. | `Secr3tP@ssw0rd!` |
| `MYSQL_ROOT_PASSWORD` | Root password for MySQL or MariaDB containers. | `RootP@ssw0rd!` |

---

## PostgreSQL & PgBouncer Tuning

*Applicable when using `--database postgresql` or `--database timescaledb`.*

| Variable | Description | Recommended Value | Default |
| :--- | :--- | :--- | :--- |
| `PG_MAX_CONNECTIONS` | Max backend connections for PostgreSQL. | `400` | `400` |
| `PG_SHARED_BUFFERS` | Dedicated database buffer cache. | `512MB` (or 25% of RAM) | `512MB` |
| `PG_WORK_MEM` | Memory allocated per query sort operation. | `16MB` | `16MB` |
| `PG_MAX_CLIENT_CONN` | Maximum incoming client connections handled by PgBouncer. | `600` | `600` |
| `PG_DEFAULT_POOL_SIZE` | Persistent server connection pool size in PgBouncer. | `50` | `50` |
| `PG_RESERVE_POOL_SIZE` | Emergency burst pool size for peak connection spikes. | `25` | `25` |

---

## pgAdmin Management

*Included with PostgreSQL and TimescaleDB stacks on port `8010`.*

| Variable | Description | Example |
| :--- | :--- | :--- |
| `PGADMIN_EMAIL` | Administrative login email for the pgAdmin web UI. | `admin@example.com` |
| `PGADMIN_PASSWORD` | Administrative password for pgAdmin web UI. | `AdminP@ssw0rd!` |

---

## SSL & HTTPS Configuration

| Variable | Description | Example |
| :--- | :--- | :--- |
| `UVICORN_SSL_CERTFILE` | Path to public SSL certificate or fullchain file. | `/var/lib/pasarguard/certs/fullchain.pem` |
| `UVICORN_SSL_KEYFILE` | Path to private SSL key file. | `/var/lib/pasarguard/certs/key.pem` |
| `UVICORN_SSL_CA_TYPE` | Type of Certificate Authority (`letsencrypt`, `custom`, `self-signed`). | `letsencrypt` |

---

## Backup & Telegram Notifications

Configured via `pasarguard backup-service` or directly in `.env`:

| Variable | Description | Example |
| :--- | :--- | :--- |
| `BACKUP_SERVICE_ENABLED` | Toggle automated recurring backup cron job. | `true` |
| `TELEGRAM_TOKEN` | Telegram Bot API token. | `123456789:ABCdefGHIjklMNO...` |
| `TELEGRAM_CHAT_ID` | Telegram chat ID, channel ID, or user ID for backup drops. | `-1001234567890` |
| `BACKUP_PROXY_ENABLED` | Route Telegram API calls through a local proxy. | `true` |
| `BACKUP_PROXY_URL` | SOCKS5 or HTTP proxy URL for Telegram requests. | `socks5://127.0.0.1:1080` |

---

## Worker Node Settings (`pg-node`)

Variables present in `/opt/pg-node/.env` (or `/opt/<custom-name>/.env`):

| Variable | Description | Example | Default |
| :--- | :--- | :--- | :--- |
| `API_KEY` | Secret token used to authenticate gRPC/REST commands from the panel. | `random-uuid-token` | Generated |
| `SERVICE_PORT` | Main inbound port for client proxy traffic. | `62050` | `62050` |
| `API_PORT` | Inbound port for node daemon synchronization. | `62051` | `62051` |
| `SSL_CERT_FILE` | Location of the node's TLS certificate. | `/var/lib/pg-node/certs/ssl_cert.pem` | - |
| `SSL_KEY_FILE` | Location of the node's private TLS key. | `/var/lib/pg-node/certs/ssl_key.pem` | - |
