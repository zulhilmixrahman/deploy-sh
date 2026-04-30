# deploy-sh

Production-ready shell scripts for setting up linux servers. Each script is interactive, detects your hardware (RAM, CPU cores), and auto-calculates sensible defaults for tuning — no manual config editing required.

## Requirements

- Linux Server. Currently support: Ubuntu 20.04 / 22.04 / 24.04
- Must be run as `root` or with `sudo`

## Scripts

| Script | What it installs |
|--------|-----------------|
| [ubuntu/laravel-stack.sh](ubuntu/laravel-stack.sh) | Nginx + PHP-FPM (7.4–8.4) for Laravel — production |
| [ubuntu/laravel-fullstack-dev.sh](ubuntu/laravel-fullstack-dev.sh) | Nginx + PHP-FPM + MySQL — staging / development |
| [ubuntu/mysql-prod.sh](ubuntu/mysql-prod.sh) | MySQL (8.0 / 8.4 / 9.1, Ubuntu default repo) — production tuning |
| [ubuntu/postgresql-prod.sh](ubuntu/postgresql-prod.sh) | PostgreSQL (13–17) — production tuning |

## Usage

Run any script directly via `curl`. Replace `<script-name>` with the script filename:

```bash
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/ubuntu/<script-name>.sh | sudo bash
```

**Examples:**

```bash
# Laravel production stack (Nginx + PHP-FPM)
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/ubuntu/laravel-stack.sh | sudo bash

# Laravel fullstack for staging/dev (Nginx + PHP-FPM + MySQL)
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/ubuntu/laravel-fullstack-dev.sh | sudo bash

# MySQL production install
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/ubuntu/mysql-prod.sh | sudo bash

# PostgreSQL production install
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/ubuntu/postgresql-prod.sh | sudo bash
```

> To skip interactive prompts, set environment variables before piping (e.g. `PHP_VERSION=8.3`).

---

## Script details

### `laravel-stack.sh` — Laravel production (Nginx + PHP-FPM)

Installs and configures a production-grade Laravel web stack:

- **Nginx** from the nginx.org official repo with a hardened global config (gzip, security headers, static-asset caching, `server_tokens off`)
- **PHP-FPM** (choose 7.4–8.4) from the Ondřej Surý PPA with all Laravel-required extensions (`mbstring`, `xml`, `bcmath`, `curl`, `zip`, `gd`, `intl`, `opcache`, `redis`)

- **Database driver** — choose MySQL/MariaDB, PostgreSQL, or SQLite at install time
- **OPcache** tuned for production with JIT enabled (`opcache.jit=tracing`)
- **PHP INI** hardened: `expose_php=Off`, `display_errors=Off`, secure session cookies
- **Composer** (optional, checksum-verified)
- **Nginx site config** pre-written for Laravel with front-controller routing, PHP-FPM pass, and security headers

All pool sizes (PHP-FPM `pm.max_children`, etc.) are calculated from detected RAM. Every value is shown as a default and can be overridden interactively.

**Ports:** 80 (HTTP) — add SSL with `certbot --nginx -d yourdomain.com`

---

### `laravel-fullstack-dev.sh` — Laravel staging / development (Nginx + PHP-FPM + MySQL)

All-in-one installer for a local dev or staging environment:

- Everything from `laravel-stack.sh` (Nginx + PHP-FPM)
- **MySQL** (8.0 LTS / 8.4 LTS / 9.1 Innovation) from the Ubuntu default repository
- **Xdebug** installed and pre-configured in `develop` mode (switch to `xdebug.mode=debug` to activate step debugging on port 9003)
- `display_errors=On` and `display_startup_errors=On` for easier debugging
- MySQL tuned conservatively (30% RAM for buffer pool, slow query log, optional general log)
- Optionally creates a MySQL database and user during install
- `.env` hints printed at the end so you can configure Laravel immediately

---

### `mysql-prod.sh` — MySQL production install

Installs MySQL Server from the Ubuntu default repository with a production-hardened configuration:

- Chooses MySQL **8.0 LTS**, **8.4 LTS** (default), or **9.1 Innovation**
- **Non-interactive install** — Ubuntu's default `mysql-server` uses `auth_socket` for root out of the box; no bootstrap password required
- Removes anonymous users, test database, and remote root access
- Writes `/etc/mysql/conf.d/production.cnf` with tunable values:
  - `innodb_buffer_pool_size` (default: 70% of RAM)
  - `max_connections`, `innodb_log_file_size`, `innodb_flush_log_at_trx_commit`
  - `table_open_cache`, `thread_cache_size`
  - Slow query log enabled by default
- **Optional remote access**: configure `bind-address` and create a dedicated remote user in one step
- Config validated with `mysqld --validate-config` before restarting

---

### `postgresql-prod.sh` — PostgreSQL production install

Installs PostgreSQL from the official PGDG APT repository with a production-tuned config:

- Chooses PostgreSQL **13**, **14**, **15**, **16**, or **17** (default)
- **Storage type prompt** — SSD sets `random_page_cost=1.1` and `effective_io_concurrency=200`; HDD uses conservative values
- Writes `/etc/postgresql/<ver>/main/conf.d/production.conf` with tunable values:
  - `shared_buffers` (default: 25% RAM), `effective_cache_size` (75% RAM)
  - `maintenance_work_mem`, `work_mem`, `wal_buffers`, `checkpoint_completion_target`
  - Parallelism (`max_worker_processes`, `max_parallel_workers`) set to CPU core count
  - Slow query log via `log_min_duration_statement` (default: 1000 ms)
- **`pg_hba.conf`** updated to enforce `scram-sha-256` authentication
- **Optional remote access**: adds a `host` entry to `pg_hba.conf` and creates a remote user
- Performs a full restart only when `listen_addresses` changes; uses `reload` otherwise
