## Installing pasarguard

### 🔧 Available options

| Option               | Description                                                                                |
| -------------------- | ------------------------------------------------------------------------------------------ |
| `--database`         | Optional. Choose from: `mysql`, `mariadb`, `postgres`, `timescaledb`. Default is `sqlite`. |
| `--version <vX.Y.Z>` | Install a specific version, including pre-releases (e.g., `v0.5.2`, `v1.0.0-beta.1`)       |
| `--dev`              | Install the latest development version (only for versions **before v1.0.0**)               |
| `--pre-release`      | Install the latest pre-release version (only for versions **v1.0.0 and later**)            |
| `--ssl`              | Enable SSL setup prompt during install (Domain/IP/Custom certificate).                      |
| `--no-ssl`           | Skip SSL setup during install (dashboard will bind to localhost only).                      |
| `--ssl-domain`       | Issue SSL cert directly for domain mode (example: `--ssl-domain panel.example.com`).        |
| `--ssl-http-port`    | ACME HTTP challenge port for SSL issuance (default: `80`).                                   |

> ℹ️ `postgres` and `timescaledb` are only supported in versions **v1.0.0 and later**.  
> ℹ️ Pre-release versions (e.g., `v1.0.0-beta.1`) can also be installed using `--version`.
> ℹ️ During install, SSL menu supports: Let's Encrypt Domain, Let's Encrypt IP (short-lived), Custom cert/key path, or No SSL.

---

### 📦 Examples

-   **Install pasarguard with SQLite**:

    ```bash
    curl -fsSLo /tmp/pg.sh https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh && sudo bash /tmp/pg.sh install
    ```

-   **Install pasarguard with MySQL**:

    ```bash
    curl -fsSLo /tmp/pg.sh https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh && sudo bash /tmp/pg.sh install --database mysql
    ```

-   **Install pasarguard with PostgreSQL**:

    ```bash
    curl -fsSLo /tmp/pg.sh https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh && sudo bash /tmp/pg.sh install --database postgresql
    ```

-   **Install pasarguard with TimescaleDB(v1+ only) and pre-release version**:

    ```bash
    curl -fsSLo /tmp/pg.sh https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh && sudo bash /tmp/pg.sh install --database timescaledb --pre-release
    ```

-   **Install pasarguard with MariaDB and Dev branch**:

    ```bash
    curl -fsSLo /tmp/pg.sh https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh && sudo bash /tmp/pg.sh install --database mariadb --dev
    ```

-   **Install pasarguard with MariaDB and Manual version**:

    ```bash
    curl -fsSLo /tmp/pg.sh https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh && sudo bash /tmp/pg.sh install --database mariadb --version v0.5.2
    ```

## Installing Node

### 📦 Examples (TTY-safe, short form)

-   **Install Node**
    ```bash
    curl -fsSLo /tmp/pg-node.sh https://github.com/PasarGuard/scripts/raw/main/pg-node.sh && sudo bash /tmp/pg-node.sh install
    ```
-   **Install Node Manual version:**
    ```bash
    curl -fsSLo /tmp/pg-node.sh https://github.com/PasarGuard/scripts/raw/main/pg-node.sh && sudo bash /tmp/pg-node.sh install --version 0.1.0
    ```
-   **Install Node pre-release version:**

    ```bash
    curl -fsSLo /tmp/pg-node.sh https://github.com/PasarGuard/scripts/raw/main/pg-node.sh && sudo bash /tmp/pg-node.sh install --pre-release
    ```

-   **Install Node with custom name:**

    ```bash
    curl -fsSLo /tmp/pg-node.sh https://github.com/PasarGuard/scripts/raw/main/pg-node.sh && sudo bash /tmp/pg-node.sh install --name Node2
    ```

    > 📌 **Tip:**  
    > The `--name` flag lets you install and manage multiple Node instances using this script.  
    > For example, running with `--name pg-node2` will create and manage a separate instance named `pg-node2`.  
    > You can then control each node individually using its assigned name.

-   **Update or Change Xray-core Version**:

    ```bash
    sudo pg-node core-update
    ```

Use `help` to view all commands:
`pg-node help`
