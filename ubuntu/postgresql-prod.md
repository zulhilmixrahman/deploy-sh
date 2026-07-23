# ubuntu/postgresql-prod.sh

Installs and hardens **PostgreSQL** on Ubuntu for production use.

## What it installs

- PostgreSQL (your chosen version via the official PGDG APT repository)
- Production-tuned config written to `/etc/postgresql/<ver>/main/conf.d/production.conf`

## Interactive prompts

| Prompt | Options | Default |
|--------|---------|---------|
| PostgreSQL version | 13, 14, 15, 16, 17 | 17 |
| Storage type | SSD, HDD | SSD |
| `shared_buffers` | any | 25% of RAM, min 128MB |
| `effective_cache_size` | any | 75% of RAM |
| `maintenance_work_mem` | any | 5% of RAM (64–2048MB) |
| `work_mem` | any | 4MB |
| `max_connections` | any | 100 |
| `max_worker_processes` | any | CPU core count |
| `log_min_duration_statement` (ms, -1 = off) | any | 1000 |
| `wal_buffers` | any | 16MB |
| `checkpoint_completion_target` | any | 0.9 |
| Allow remote connections | y / N | N |

### Remote access prompts (if enabled)

| Prompt | Options | Default |
|--------|---------|---------|
| `listen_addresses` | any IP or `*` | `*` |
| Allowed client CIDR | e.g. `10.0.0.0/8`, `0.0.0.0/0` | `0.0.0.0/0` |
| Create dedicated remote user | y / N | N |
| Remote username | any | `remoteuser` |
| Remote user password | — | — |

## Root authentication

The `postgres` superuser uses **peer authentication** — only the OS `postgres` user can connect locally without a password:

```bash
sudo -u postgres psql
```

All other local users authenticate via `scram-sha-256`.

## After installation

Connect as the postgres superuser (no password):

```bash
sudo -u postgres psql
```

Create a database and application user:

```sql
CREATE DATABASE myapp ENCODING 'UTF8';
CREATE USER myapp WITH ENCRYPTED PASSWORD 'strongpassword';
GRANT ALL PRIVILEGES ON DATABASE myapp TO myapp;
```

If remote access is enabled, open the firewall:

```bash
ufw allow 5432/tcp
ufw reload
```

## Production config

Written to `/etc/postgresql/<ver>/main/conf.d/production.conf`. Key defaults:

```
shared_buffers                 = 25% RAM
effective_cache_size           = 75% RAM
wal_compression                = on
min_wal_size                   = 1GB
max_wal_size                   = 4GB
log_checkpoints                = on
log_lock_waits                 = on
idle_in_transaction_session_timeout = 60000
lock_timeout                   = 30000
listen_addresses               = localhost   # * if remote enabled
```

Storage-type tuning:

| Setting | SSD | HDD |
|---------|-----|-----|
| `random_page_cost` | 1.1 | 4.0 |
| `effective_io_concurrency` | 200 | 2 |

## Install

> Requires Ubuntu 20.04 / 22.04 / 24.04. Must be run as root or with `sudo`.

```bash
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/ubuntu/postgresql-prod.sh | sudo bash
```

Or download first and review before running:

```bash
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/ubuntu/postgresql-prod.sh -o postgresql-prod.sh
chmod +x postgresql-prod.sh
sudo ./postgresql-prod.sh
```
