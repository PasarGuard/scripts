# PasarGuard Database Configurations

A technical guide to selecting, configuring, and tuning database backends in PasarGuard.

---

## Supported Database Engines

| Database Engine | Recommended For | Supported Versions | Key Features | Default Port |
| :--- | :--- | :--- | :--- | :--- |
| **SQLite** | Small to medium deployments (< 500 active users) | All versions | Zero setup, embedded, WAL-mode checkpoints | File-based |
| **MySQL 8.0** | Traditional multi-service setups | All versions | phpMyAdmin on port 8010, ACID transactions | `3306` |
| **MariaDB (LTS)** | Open-source MySQL alternative | All versions | phpMyAdmin on port 8010, high concurrency | `3306` |
| **PostgreSQL 17** | High-traffic production deployments (1,000+ users) | `v1.0.0+` | Native async pooling, pgAdmin4, SCRAM-SHA-256 | `5432` |
| **TimescaleDB** | High-throughput telemetry & analytics | `v1.0.0+` | Hypertables, pgAdmin4, automatic time-series partitioning | `5432` |

---

## Selecting a Database During Installation

Specify the `--database` option when installing the panel:

```bash
# SQLite (default)
sudo pasarguard install

# MySQL
sudo pasarguard install --database mysql

# MariaDB
sudo pasarguard install --database mariadb

# PostgreSQL (Requires v1.0.0+)
sudo pasarguard install --database postgresql --pre-release

# TimescaleDB (Requires v1.0.0+)
sudo pasarguard install --database timescaledb --pre-release
```

---

## Engine-Specific Details

### 1. SQLite Configuration
SQLite requires zero container overhead and stores the database directly on disk:
- **Location**: `/var/lib/pasarguard/db.sqlite3`
- **Connection URL**:
  ```env
  SQLALCHEMY_DATABASE_URL="sqlite:////var/lib/pasarguard/db.sqlite3"
  ```
- **Journal Mode**: Configured in WAL (Write-Ahead Logging) mode for concurrent read operations without locking writers.

---

### 2. MySQL & MariaDB
MySQL and MariaDB run in dedicated Docker containers with optional phpMyAdmin access.
- **Docker Compose Stack**: `docker-compose/pasarguard-mysql.yml` or `pasarguard-mariadb.yml`
- **Port**: `3306` bound to `127.0.0.1` for local container communication.
- **phpMyAdmin**: Web GUI accessible on `http://<server-ip>:8010` (restricted or exposed per firewall).
- **Environment Variables**:
  ```env
  DB_NAME="pasarguard"
  DB_USER="pasarguard"
  DB_PASSWORD="your-strong-password"
  MYSQL_ROOT_PASSWORD="generated-root-password"
  SQLALCHEMY_DATABASE_URL="mysql+pymysql://pasarguard:your-strong-password@127.0.0.1:3306/pasarguard"
  ```

---

### 3. PostgreSQL & TimescaleDB (Production Tier)
For production environments with heavy concurrent user connections, PostgreSQL or TimescaleDB provides the highest performance and reliability.

#### Architecture
```
[ PasarGuard Panel ] ──(port 5432)──► [ TimescaleDB / PostgreSQL ]
                                        ▲
[ pgAdmin4 (Web GUI) ] ──(port 8010)────┘
```

#### Native Async Connection Pooling
PostgreSQL and TimescaleDB handle connections directly via the panel's built-in async connection pooling (`asyncpg` with SQLAlchemy `AsyncAdaptedQueuePool`). This ensures full compatibility with prepared statements, asynchronous transactions, and low latency:
- Panel connects directly to PostgreSQL / TimescaleDB on port `5432`.
- Native async pool manages persistent connections efficiently without requiring external proxy middleware.

#### Resource Tuning Parameters
In `/opt/pasarguard/.env`, you can customize PostgreSQL memory and concurrency limits:

```env
# PostgreSQL / TimescaleDB Core Tuning
PG_MAX_CONNECTIONS=400       # Maximum physical backend connections
PG_SHARED_BUFFERS=512MB      # Dedicated cache memory (recommended: 25% of RAM)
PG_WORK_MEM=16MB             # Memory used for internal sort operations
```

#### pgAdmin 4 Management Interface
- **Access**: `http://<server-ip>:8010`
- **Default Credentials**:
  - Email: `PGADMIN_EMAIL` (set during installation or in `.env`)
  - Password: `PGADMIN_PASSWORD` (set during installation or in `.env`)
- **Connecting to DB in pgAdmin**:
  - Host: `127.0.0.1`
  - Port: `5432`
  - Username: `pasarguard`
  - Password: `${DB_PASSWORD}`

---

## Database Migrations & Switching

To switch from an existing database engine (e.g. SQLite to TimescaleDB):
1. Execute a full backup:
   ```bash
   sudo pasarguard backup
   ```
2. Archive the backup file from `/opt/pasarguard/backup/`.
3. Stop and remove the current stack:
   ```bash
   sudo pasarguard down
   ```
4. Re-run `install` with your desired `--database` flag:
   ```bash
   sudo pasarguard install --database timescaledb --pre-release
   ```
5. Restore your database snapshot using `sudo pasarguard restore`.
