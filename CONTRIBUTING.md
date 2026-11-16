# Contributing to PasarGuard Scripts

Thank you for your interest in contributing to PasarGuard! This repository maintains the deployment, orchestration, and disaster recovery scripts for PasarGuard Panel and Nodes.

---

## Table of Contents
- [Development Setup](#development-setup)
- [Repository Structure](#repository-structure)
- [Running Tests](#running-tests)
- [Coding Standards](#coding-standards)
- [Commit Conventions](#commit-conventions)
- [Submitting Pull Requests](#submitting-pull-requests)

---

## Development Setup

1. Fork the repository on GitHub: `https://github.com/PasarGuard/scripts`.
2. Clone your fork locally:
   ```bash
   git clone https://github.com/<your-username>/scripts.git pasarguard-scripts
   cd pasarguard-scripts
   ```
3. Set upstream remote:
   ```bash
   git remote add upstream https://github.com/PasarGuard/scripts.git
   ```

---

## Repository Structure

```
├── pasarguard.sh         # Main panel orchestration script
├── pg-node.sh            # Worker node orchestration script
├── pg-node-service.sh    # Node background systemd service daemon
├── install_core.sh       # Xray-core binary installer
├── lib/                  # Shared modular libraries
│   ├── common.sh         # Utilities (paths, tempfiles, secrets, banners)
│   ├── system.sh         # OS detection, package managers, network helpers
│   ├── docker.sh         # Docker Compose and container management
│   ├── env.sh            # .env file manipulation helpers
│   ├── github.sh         # GitHub API lookup and self-updating
│   ├── pasarguard-backup.sh  # Backup archiving & Telegram delivery
│   └── pasarguard-restore.sh # Disaster recovery & TimescaleDB migration
├── docker-compose/       # Database-specific Compose stacks
├── iran-sanction/        # Domestic mirror benchmarks and standalone packages
├── tests/                # Automated test suites
└── docs/                 # Detailed architecture and operator guides
```

---

## Running Tests

Before submitting changes, ensure all unit tests pass:

```bash
# Run all unit tests
bash tests/run_all.sh
```

Or execute individual test suites:
```bash
bash tests/unit_pasarguard.sh
bash tests/unit_pgnode.sh
bash tests/unit_lib_common.sh
bash tests/unit_lib_env.sh
bash tests/unit_lib_github.sh
bash tests/unit_lib_system.sh
bash tests/unit_pgnode_service.sh
bash tests/unit_restore_archive_safety.sh
bash tests/test_script_update_safety.sh
```

### Full Integration Round-Trip Tests (Requires Docker)
To test complete backup and restore round-trips against live database containers:
```bash
# Test SQLite
bash tests/backup_restore_roundtrip.sh sqlite single

# Test PostgreSQL / TimescaleDB
bash tests/backup_restore_roundtrip.sh postgresql multipart
bash tests/backup_restore_roundtrip.sh timescaledb single
```

---

## Coding Standards

- **Bash Best Practices**:
  - Scripts must run cleanly on modern Bash (v4+ and v5+).
  - Use `set -euo pipefail` where applicable, or handle non-zero exits gracefully.
  - Always quote variable expansions (e.g. `"$target_file"`) to prevent word-splitting and globbing.
  - Avoid non-standard utilities or GNU-specific flags if POSIX equivalents exist.
- **ShellCheck**:
  - Code must pass `shellcheck -S error` with zero errors.
  - Fix any warnings that could cause variable leaking, unquoted expansions, or masked exit codes.
- **Error Handling & Logs**:
  - Always preserve logs in failure scenarios (e.g. `pasarguard_restore_error.log`).
  - Never suppress errors with `|| true` unless intentionally handling expected non-zero exits.
  - Clean up temporary directories using `trap` handlers on `EXIT`, `INT`, and `TERM`.

---

## Commit Conventions

We follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` New features or commands (e.g. `feat(backup): add S3 destination`)
- `fix:` Bug fixes (e.g. `fix(timescaledb): isolate compat db using template0`)
- `docs:` Documentation improvements (e.g. `docs: add disaster recovery guide`)
- `test:` Adding or improving test cases (e.g. `test(pgnode): add SAN validation tests`)
- `refactor:` Code restructuring without functional changes

---

## Submitting Pull Requests

1. Create a feature branch:
   ```bash
   git checkout -b fix/my-fix-description
   ```
2. Make your edits and commit following the conventions.
3. Push to your fork:
   ```bash
   git push origin fix/my-fix-description
   ```
4. Open a Pull Request against the `main` branch of `PasarGuard/scripts`.
5. Ensure all GitHub Actions CI checks pass (`Unit Tests`, `Script Update Safety`, `Backup Restore`).
