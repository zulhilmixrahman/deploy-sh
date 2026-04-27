# sh-scripts

A collection of shell scripts for server setup and configuration.

## Scripts

| Script | Description |
|--------|-------------|
| [ubuntu/laravel-stack.sh](ubuntu/laravel-stack.md) | Install Nginx + PHP-FPM for Laravel on Ubuntu |
| [ubuntu/laravel-fullstack-dev.sh](ubuntu/laravel-fullstack-dev.md) | Install Nginx + PHP-FPM + MySQL for Laravel — staging/development |
| [ubuntu/mysql-prod.sh](ubuntu/mysql-prod.md) | Install MySQL Community + production tuning on Ubuntu |
| [ubuntu/postgresql-prod.sh](ubuntu/postgresql-prod.md) | Install PostgreSQL + production tuning on Ubuntu |


## Installation

> Must be run as root or with `sudo`.

```bash
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/<distro-name>/<script-name>.sh | sudo bash
```