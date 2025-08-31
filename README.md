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

-   **Install pasarguard with SQLite**:

    ```bash
    sudo bash -c "$(curl -sL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh)" @ install
    ```

-   **Install pasarguard with MySQL**:

    ```bash
    sudo bash -c "$(curl -sL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh)" @ install --database mysql
    ```

-   **Install pasarguard with PostgreSQL(v1+ only)**:

    ```bash
    sudo bash -c "$(curl -sL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh)" @ install --database postgresql
    ```

-   **Install pasarguard with TimescaleDB(v1+ only) and pre-release version**:

    ```bash
    sudo bash -c "$(curl -sL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh)" @ install --database timescaledb --pre-release
    ```

-   **Install pasarguard with MariaDB and Dev branch**:

    ```bash
    sudo bash -c "$(curl -sL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh)" @ install --database mariadb --dev
    ```

-   **Install pasarguard with MariaDB and Manual version**:

    ```bash
    sudo bash -c "$(curl -sL https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh)" @ install --database mariadb --version v0.5.2
    ```

## Installing Node

### 📦 Examples

-   **Install Node**
    ```bash
    sudo bash -c "$(curl -sL https://github.com/PasarGuard/scripts/raw/main/node-cli.sh)" @ install
    ```
-   **Install Node Manual version:**
    ```bash
    sudo bash -c "$(curl -sL https://github.com/PasarGuard/scripts/raw/main/node-cli.sh)" @ install --version 0.1.0
    ```
-   **Install Node pre-release version:**

    ```bash
    sudo bash -c "$(curl -sL https://github.com/PasarGuard/scripts/raw/main/node-cli.sh)" @ install --pre-release
    ```

-   **Install Node with custom name:**

    ```bash
    sudo bash -c "$(curl -sL https://github.com/PasarGuard/scripts/raw/main/node-cli.sh)" @ install --name Node2
    ```

    > 📌 **Tip:**  
    > The `--name` flag lets you install and manage multiple Node instances using this script.  
    > For example, running with `--name node-cli2` will create and manage a separate instance named `node-cli2`.  
    > You can then control each node individually using its assigned name.

-   **Update or Change Xray-core Version**:

    ```bash
    sudo node-cli core-update
    ```

Use `help` to view all commands:
`node-cli help`
