# ubuntu/laravel-stack.sh

Installs **Nginx + PHP-FPM** on Ubuntu for running a Laravel application.

## What it installs

- Nginx (latest stable via nginx.org official repo)
- PHP-FPM (your chosen version via `ppa:ondrej/php`)
- PHP extensions required by Laravel (mbstring, xml, bcmath, curl, zip, gd, intl, opcache, redis, tokenizer + your chosen DB driver)
- Composer (optional)

## Interactive prompts

| Prompt | Options | Default |
|--------|---------|---------|
| PHP version | 7.4, 8.0, 8.1, 8.2, 8.3, 8.4 | 8.3 |
| Database driver | MySQL/MariaDB, PostgreSQL, SQLite | MySQL/MariaDB |
| PHP INI values | upload size, memory limit, timezone, OPcache, etc. | see below |
| Laravel directory name | any name | `laravel` |
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
opcache.revalidate_freq       = 2
```

## Install

> Requires Ubuntu 20.04 / 22.04 / 24.04. Must be run as root or with `sudo`.

```bash
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/ubuntu/laravel-stack.sh | sudo bash
```

Or download first and review before running:

```bash
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/ubuntu/laravel-stack.sh -o laravel-stack.sh
chmod +x laravel-stack.sh
sudo ./laravel-stack.sh
```

### Non-interactive mode

Pass `PHP_VERSION` as an environment variable to skip the PHP version prompt:

```bash
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/ubuntu/laravel-stack.sh | sudo PHP_VERSION=8.3 bash
```

## After installation

Deploy your Laravel application to `/var/www/<your-app-name>`, then set the correct permissions:

```bash
chown -R www-data:www-data /var/www/<your-app-name>
chmod -R 775 /var/www/<your-app-name>/storage
chmod -R 775 /var/www/<your-app-name>/bootstrap/cache
```

Update `server_name` in the Nginx config to your domain:

```bash
sudo nano /etc/nginx/sites-available/<your-app-name>
sudo nginx -t && sudo systemctl reload nginx
```

Optionally add a free SSL certificate:

```bash
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d yourdomain.com
```
