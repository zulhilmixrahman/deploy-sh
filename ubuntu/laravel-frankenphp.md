# ubuntu/laravel-frankenphp.sh

Installs **FrankenPHP** (with embedded Caddy) on Ubuntu for running a Laravel application — a single binary replacing Nginx + PHP-FPM, with optional Octane worker mode.

## What it installs

- FrankenPHP prebuilt binary (latest release, matched to your CPU arch — `x86_64` / `aarch64`, `-gnu` build on glibc systems)
- `systemd` service (`frankenphp.service`) running as `www-data` with `CAP_NET_BIND_SERVICE` (no root needed to bind port 80/443)
- Caddyfile pre-written for Laravel: front-controller routing, dotfile/`.env`/`.git` blocking, security headers, gzip/br/zstd compression, rolling access logs
- Automatic HTTPS via Let's Encrypt when a domain is provided
- Composer (optional, checksum-verified)

## Interactive prompts

| Prompt | Options | Default |
|--------|---------|---------|
| Is your domain ready (DNS already points here)? | y/N | N |
| Domain name *(if ready)* | any domain | none — plain HTTP on `:80` |
| Use Let's Encrypt for automatic HTTPS? *(if domain set)* | Y/n | Y |
| Email for Let's Encrypt renewal notices *(if using Let's Encrypt)* | any email | none |
| Laravel directory name | any name | `laravel` |
| Enable FrankenPHP worker mode (Octane) | y/N | N |
| Worker count *(if enabled)* | any number | 2× CPU cores |
| `num_threads` | any number | 2× CPU cores |
| `max_threads` | any number | same as `num_threads` |
| `max_requests` | any number | 500 |
| PHP INI values | upload size, memory limit, timezone, OPcache, etc. | see below |
| Install Composer | Y/n | Y |

## Default PHP INI values

```
upload_max_filesize           = 64M
post_max_size                 = 64M
memory_limit                  = 256M
max_execution_time            = 60
date.timezone                 = UTC
opcache.memory_consumption    = 128
opcache.max_accelerated_files = 10000
opcache.revalidate_freq       = 0
opcache.jit                   = tracing
opcache.jit_buffer_size       = 64M
```

## Worker mode (Laravel Octane)

Worker mode keeps the app booted in memory for much higher throughput but requires [Laravel Octane](https://laravel.com/docs/octane):

```bash
composer require laravel/octane
php artisan octane:install --server=frankenphp
```

When enabled, the Caddyfile's `frankenphp` block gets a `worker` directive pointing at `<project-root>/frankenphp-worker.php`.

## Install

> Requires Ubuntu 20.04 / 22.04 / 24.04, `x86_64` or `aarch64`. Must be run as root or with `sudo`.

```bash
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/ubuntu/laravel-frankenphp.sh | sudo bash
```

Or download first and review before running:

```bash
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/ubuntu/laravel-frankenphp.sh -o laravel-frankenphp.sh
chmod +x laravel-frankenphp.sh
sudo ./laravel-frankenphp.sh
```

### Non-interactive mode

Pass `DOMAIN`, `USE_LETSENCRYPT`, `ACME_EMAIL`, and/or `APP_DIR` as environment variables to skip those prompts:

```bash
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/ubuntu/laravel-frankenphp.sh | sudo DOMAIN=example.com USE_LETSENCRYPT=Y ACME_EMAIL=you@example.com APP_DIR=myapp bash
```

## After installation

Deploy your Laravel application to the project root printed at the end of the install (`/var/www/<APP_DIR>`), then set the correct permissions and restart:

```bash
chown -R www-data:www-data /var/www/<APP_DIR>
chmod -R 775 /var/www/<APP_DIR>/storage
systemctl restart frankenphp
```

Useful paths:

| What | Where |
|------|-------|
| Caddyfile | `/etc/frankenphp/Caddyfile` |
| Extra site blocks | `/etc/frankenphp/Caddyfile.d/*.caddyfile` (auto-imported) |
| PHP INI | `/etc/frankenphp/php.ini` |
| PHP error log | `/var/log/frankenphp/php-error.log` |
| Access log | `/var/log/frankenphp/<APP_DIR>-access.log` |
| Live logs | `journalctl -u frankenphp -f` |

If no domain was set at install time, re-run the script with `DOMAIN` set to enable automatic HTTPS.
