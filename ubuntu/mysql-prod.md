# ubuntu/mysql-prod.sh

Installs and hardens **MySQL Server** on Ubuntu for production use.

## What it installs

- MySQL Server (your chosen version from the Ubuntu default repository)
- Production-tuned `my.cnf` written to `/etc/mysql/conf.d/production.cnf`

## Interactive prompts

| Prompt | Options | Default |
|--------|---------|---------|
| MySQL version | 8.0 (LTS), 8.4 (LTS), 9.1 (Innovation) | 8.4 |
| `innodb_buffer_pool_size` | any | 70% of RAM, min 128M |
| `max_connections` | any | 151 |
| `innodb_log_file_size` | any | 256M |
| `innodb_flush_log_at_trx_commit` | 0, 1, 2 | 1 |
| `slow_query_log` | ON / OFF | ON |
| `long_query_time` (seconds) | any | 2 |
| `max_allowed_packet` | any | 64M |
| `table_open_cache` | any | 4000 |
| `thread_cache_size` | any | 8 |
| Allow remote connections | y / N | N |

### Remote access prompts (if enabled)

| Prompt | Options | Default |
|--------|---------|---------|
| `bind-address` | any IP or `0.0.0.0` | `0.0.0.0` |
| Create dedicated remote user | y / N | N |
| Remote username | any | `remoteuser` |
| Allowed host / IP | any or `%` | `%` |
| Remote user password | — | — |

## Root authentication

Root login uses **OS socket authentication** (`auth_socket` plugin). No password is set or required — only the OS `root` user can connect:

```bash
mysql -uroot
```

## Security hardening

- Anonymous users removed
- Remote root login disabled
- Test database removed
- Root uses `auth_socket` by default (Ubuntu default package behaviour)

## After installation

Connect as root (no password):

```bash
mysql -uroot
```

Create a database and application user:

```sql
CREATE DATABASE myapp CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'myapp'@'localhost' IDENTIFIED BY 'strongpassword';
GRANT ALL ON myapp.* TO 'myapp'@'localhost';
FLUSH PRIVILEGES;
```

If remote access is enabled, open the firewall:

```bash
ufw allow 3306/tcp
ufw reload
```

## Production config

Written to `/etc/mysql/conf.d/production.cnf`. Key defaults:

```ini
innodb_buffer_pool_size        = 70% RAM
innodb_flush_method            = O_DIRECT
innodb_file_per_table          = ON
slow_query_log                 = ON
slow_query_log_file            = /var/log/mysql/slow.log
character_set_server           = utf8mb4
bind-address                   = 127.0.0.1   # 0.0.0.0 if remote enabled
```

## Install

> Requires Ubuntu 20.04 / 22.04 / 24.04. Must be run as root or with `sudo`.

```bash
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/ubuntu/mysql-prod.sh | sudo bash
```

Or download first and review before running:

```bash
curl -fsSL https://raw.githubusercontent.com/zulhilmixrahman/deploy-sh/main/ubuntu/mysql-prod.sh -o mysql-prod.sh
chmod +x mysql-prod.sh
sudo ./mysql-prod.sh
```
