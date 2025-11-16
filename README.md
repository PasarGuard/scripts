## Installing pasarguard

### 🔧 Available options

| Option               | Description                                                                                |
| -------------------- | ------------------------------------------------------------------------------------------ |
| `--database`         | Optional. Choose from: `mysql`, `mariadb`, `postgres`, `timescaledb`. Default is `sqlite`. |
| `--version <vX.Y.Z>` | Install a specific version, including pre-releases (e.g., `v0.5.2`, `v1.0.0-beta.1`)       |
| `--dev`              | Install the latest development version (only for versions **before v1.0.0**)               |
| `--pre-release`      | Install the latest pre-release version (only for versions **v1.0.0 and later**)            |

> ℹ️ `postgres` and `timescaledb` are only supported in versions **v1.0.0 and later**.  
> ℹ️ Pre-release versions (e.g., `v1.0.0-beta.1`) can also be installed using `--version`.

---

### 📦 Examples

> ⚠️ The installation scripts are larger than many shells' command-line limits, so feed them through STDIN ( `curl ... | sudo bash -s --` ) instead of `sudo bash -c "$(curl ...)"` to avoid `Argument list too long`.

-   **Install pasarguard with SQLite**:

    ```bash
    curl -sL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh | sudo bash -s -- @ install
    ```

-   **Install pasarguard with MySQL**:

    ```bash
    curl -sL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh | sudo bash -s -- @ install --database mysql
    ```

-   **Install pasarguard with PostgreSQL(v1+ only)**:

    ```bash
    curl -sL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh | sudo bash -s -- @ install --database postgresql
    ```

-   **Install pasarguard with TimescaleDB(v1+ only) and pre-release version**:

    ```bash
    curl -sL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh | sudo bash -s -- @ install --database timescaledb --pre-release
    ```

-   **Install pasarguard with MariaDB and Dev branch**:

    ```bash
    curl -sL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh | sudo bash -s -- @ install --database mariadb --dev
    ```

-   **Install pasarguard with MariaDB and Manual version**:

    ```bash
    curl -sL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh | sudo bash -s -- @ install --database mariadb --version v0.5.2
    ```

## Installing Node

### 📦 Examples

> ⚠️ Use the same `curl ... | sudo bash -s --` invocation style for node installation to avoid command-length limits on some systems.

-   **Install Node**
    ```bash
    curl -sL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh | sudo bash -s -- @ install
    ```
-   **Install Node Manual version:**
    ```bash
    curl -sL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh | sudo bash -s -- @ install --version 0.1.0
    ```
-   **Install Node pre-release version:**

    ```bash
    curl -sL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh | sudo bash -s -- @ install --pre-release
    ```

-   **Install Node with custom name:**

    ```bash
    curl -sL https://github.com/PasarGuard/scripts/raw/main/pg-node.sh | sudo bash -s -- @ install --name Node2
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
