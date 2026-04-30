# ubuntu/laravel-fullstack-dev.sh

Installs a complete **Laravel fullstack environment** on Ubuntu for staging and development.  
Combines Nginx, PHP-FPM, and MySQL Server in a single interactive script with dev-friendly defaults.

## What it installs

- **Nginx** (nginx.org official repo) with a global tuning config
- **PHP-FPM** (Ondřej Surý PPA) — your chosen version, with common Laravel extensions and Xdebug
- **MySQL Server** (Ubuntu default repository) — your chosen version
- **Composer** (optional, with checksum verification)

## Interactive prompts

### Version selection

| Prompt | Options | Default |
|--------|---------|---------|
| PHP-FPM version | 7.4, 8.0, 8.1, 8.2, 8.3, 8.4 | 8.3 |
| MySQL version | 8.0 (LTS), 8.4 (LTS), 9.1 (Innovation) | 8.4 |

### Application

| Prompt | Default |
|--------|---------|
| Laravel directory name | `laravel` (webroot → `/var/www/laravel/public`) |
| Environment label | `staging` |
| Create MySQL database + user | Y |
| Database name | same as directory name |
| DB username | same as directory name |
| DB password | — |

### Nginx

| Prompt | Default |
|--------|---------|
| `client_max_body_size` | `64M` |
| `keepalive_timeout` | `65` |

### PHP-FPM pool

| Prompt | Default |
|--------|---------|
| `pm` | `dynamic` |
| `pm.max_children` | 50% RAM ÷ 50MB per process |
| `pm.start_servers` | 2 |
| `pm.min_spare_servers` | 1 |
| `pm.max_spare_servers` | half of max_children |
| `pm.max_requests` | 200 |

### PHP INI

| Prompt | Default |
|--------|---------|
| `upload_max_filesize` | `64M` |
| `post_max_size` | `64M` |
| `memory_limit` | `512M` |
| `max_execution_time` | `120` |
| `date.timezone` | `UTC` |

### MySQL

| Prompt | Default |
|--------|---------|
| `innodb_buffer_pool_size` | 30% of RAM, min 64M |
| `max_connections` | 50 |
| `max_allowed_packet` | `64M` |
| `slow_query_log` | `ON` |
| `long_query_time` (seconds) | 1 |
| Enable `general_log` | N |

## Dev / staging differences from production

| Setting | Dev/staging | Production |
|---------|------------|------------|
| `display_errors` | On | Off |
| `display_startup_errors` | On | Off |
| OPcache `validate_timestamps` | 1 (recheck every request) | 1 |
| OPcache JIT | disabled | enabled |
| Xdebug | installed (`mode=develop`) | not installed |
| `innodb_flush_log_at_trx_commit` | 2 (faster writes) | 1 (full ACID) |
| MySQL `general_log` | optional | Off |
| Nginx `error_log` level | `debug` | `warn` |
| PHP `memory_limit` default | 512M | 256M |
| PHP `max_execution_time` default | 120 | 60 |

## PHP extensions installed

`fpm`, `cli`, `common`, `mysql`, `mbstring`, `xml`, `bcmath`, `curl`, `zip`, `gd`, `intl`, `opcache`, `redis`, `tokenizer`, `xdebug`

## Root authentication (MySQL)

Root uses **OS socket authentication** — no password required when running as the OS root user:

```bash
mysql -uroot
```

## Xdebug

Installed with `xdebug.mode=develop` (shows enhanced error pages). To enable step debugging, edit `/etc/php/<version>/fpm/conf.d/20-xdebug.ini`:

```ini
xdebug.mode=debug
xdebug.start_with_request=yes
```

Then reload PHP-FPM:

```bash
systemctl reload php<version>-fpm
```

## After installation

```bash
# 1. Deploy your app
cd /var/www/laravel

# 2. Fix permissions
chown -R www-data:www-data /var/www/laravel
chmod -R 775 /var/www/laravel/storage /var/www/laravel/bootstrap/cache

# 3. Configure environment
cp .env.example .env
# Set DB_DATABASE, DB_USERNAME, DB_PASSWORD

# 4. Bootstrap Laravel
composer install
php artisan key:generate
php artisan migrate

# 5. Check FPM status
curl http://127.0.0.1/fpm-status
```

## Config files written

| File | Purpose |
|------|---------|
| `/etc/nginx/conf.d/global.conf` | Nginx global tuning |
| `/etc/nginx/sites-available/<app>` | Laravel site config |
| `/etc/php/<ver>/fpm/pool.d/www.conf` | PHP-FPM pool (patched in place) |
| `/etc/php/<ver>/fpm/php.ini` | PHP INI (patched in place) |
| `/etc/php/<ver>/fpm/conf.d/10-opcache.ini` | OPcache settings |
| `/etc/php/<ver>/fpm/conf.d/20-xdebug.ini` | Xdebug settings |
| `/etc/mysql/conf.d/dev.cnf` | MySQL dev/staging tuning |

## Install

> Requires Ubuntu 20.04 / 22.04 / 24.04. Must be run as root or with `sudo`.

```bash
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/ubuntu/laravel-fullstack-dev.sh | sudo bash
```

Or download first and review before running:

```bash
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/ubuntu/laravel-fullstack-dev.sh -o laravel-fullstack-dev.sh
chmod +x laravel-fullstack-dev.sh
sudo ./laravel-fullstack-dev.sh
```
