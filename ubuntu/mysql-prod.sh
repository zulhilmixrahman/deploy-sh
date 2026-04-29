#!/usr/bin/env bash

set -euo pipefail

# ─── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
read_input() { read "$@" </dev/tty || true; }

# ─── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run this script as root or with sudo."

# ─── Detect total RAM (MB) for buffer pool default ─────────────────────────────
TOTAL_RAM_MB=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)
DEFAULT_BUFFER_POOL="${TOTAL_RAM_MB%.*}"
# Default to 70% of RAM, minimum 128M
DEFAULT_BUFFER_POOL=$(( DEFAULT_BUFFER_POOL * 70 / 100 ))
(( DEFAULT_BUFFER_POOL < 128 )) && DEFAULT_BUFFER_POOL=128
DEFAULT_BUFFER_POOL="${DEFAULT_BUFFER_POOL}M"

echo ""
echo "  ┌─────────────────────────────────────────────┐"
echo "  │   MySQL Community Installer + Tuning (Prod)  │"
echo "  └─────────────────────────────────────────────┘"
echo ""

# ─── MySQL version selection ───────────────────────────────────────────────────
echo "  Available MySQL versions:"
echo "    1) MySQL 8.0  (LTS)"
echo "    2) MySQL 8.4  (LTS)"
echo "    3) MySQL 9.1  (Innovation)"
echo ""
read_input -rp "  Select MySQL version [default: 2]: " ver_choice
echo ""

case "${ver_choice:-2}" in
    1) MYSQL_VER="8.0"  ; APT_SERIES="mysql-8.0"  ;;
    2) MYSQL_VER="8.4"  ; APT_SERIES="mysql-8.4"  ;;
    3) MYSQL_VER="9.1"  ; APT_SERIES="mysql-9.1"  ;;
    *) MYSQL_VER="8.4"  ; APT_SERIES="mysql-8.4"  ;;
esac

# Internal bootstrap password — used once to configure auth_socket, never shown to user
MYSQL_ROOT_PASS=$(openssl rand -base64 32 | tr -d '/+=')

# ─── Production tuning prompts ─────────────────────────────────────────────────
echo "  Production tuning (press Enter to keep default):"
echo "  Server RAM detected: ${TOTAL_RAM_MB}MB"
echo ""

read_input -rp "    innodb_buffer_pool_size  [${DEFAULT_BUFFER_POOL}]: " T_BUFFER_POOL
T_BUFFER_POOL="${T_BUFFER_POOL:-$DEFAULT_BUFFER_POOL}"

read_input -rp "    max_connections          [151]:  " T_MAX_CONN
T_MAX_CONN="${T_MAX_CONN:-151}"

read_input -rp "    innodb_log_file_size     [256M]: " T_LOG_FILE
T_LOG_FILE="${T_LOG_FILE:-256M}"

read_input -rp "    innodb_flush_log_at_trx_commit [1]: " T_FLUSH_LOG
T_FLUSH_LOG="${T_FLUSH_LOG:-1}"

read_input -rp "    slow_query_log           [ON]:   " T_SLOW_LOG
T_SLOW_LOG="${T_SLOW_LOG:-ON}"

read_input -rp "    long_query_time (seconds)[2]:    " T_LONG_QUERY
T_LONG_QUERY="${T_LONG_QUERY:-2}"

read_input -rp "    max_allowed_packet       [64M]:  " T_MAX_PACKET
T_MAX_PACKET="${T_MAX_PACKET:-64M}"

read_input -rp "    table_open_cache         [4000]: " T_TABLE_CACHE
T_TABLE_CACHE="${T_TABLE_CACHE:-4000}"

read_input -rp "    thread_cache_size        [8]:    " T_THREAD_CACHE
T_THREAD_CACHE="${T_THREAD_CACHE:-8}"

echo ""

# ─── Remote access ─────────────────────────────────────────────────────────────
read_input -rp "  Allow remote connections? [y/N]: " REMOTE_ACCESS
REMOTE_ACCESS="${REMOTE_ACCESS,,}"

BIND_ADDR="127.0.0.1"
REMOTE_USER=""
REMOTE_PASS=""
REMOTE_HOST="%"

if [[ "$REMOTE_ACCESS" == "y" || "$REMOTE_ACCESS" == "yes" ]]; then
    read_input -rp "    bind-address (0.0.0.0 = all interfaces) [0.0.0.0]: " BIND_ADDR
    BIND_ADDR="${BIND_ADDR:-0.0.0.0}"

    read_input -rp "    Create a dedicated remote user? [y/N]: " CREATE_REMOTE_USER
    if [[ "${CREATE_REMOTE_USER,,}" == "y" || "${CREATE_REMOTE_USER,,}" == "yes" ]]; then
        read_input -rp "      Remote username [remoteuser]: " REMOTE_USER
        REMOTE_USER="${REMOTE_USER:-remoteuser}"
        read_input -rp "      Allowed host/IP ('%' = any host) [%]: " REMOTE_HOST
        REMOTE_HOST="${REMOTE_HOST:-%}"
        while true; do
            read_input -rsp "      Password for '${REMOTE_USER}': " REMOTE_PASS; echo ""
            read_input -rsp "      Confirm password: " REMOTE_PASS2; echo ""
            [[ "$REMOTE_PASS" == "$REMOTE_PASS2" ]] && break
            warn "Passwords do not match. Try again."
        done
        [[ -z "$REMOTE_PASS" ]] && error "Remote user password cannot be empty."
    fi
fi

echo ""

# ─── Prerequisites ─────────────────────────────────────────────────────────────
info "Installing prerequisites..."
apt-get update -qq
apt-get install -y -qq \
    curl \
    gnupg2 \
    ca-certificates \
    lsb-release \
    apt-transport-https \
    debconf-utils

# ─── MySQL APT repository ──────────────────────────────────────────────────────
if ! dpkg -l | grep -q "mysql-apt-config"; then
    info "Adding MySQL Community APT repository..."
    TMPDIR=$(mktemp -d)
    curl -fsSL "https://dev.mysql.com/get/mysql-apt-config_0.8.33-1_all.deb" -o "${TMPDIR}/mysql-apt-config.deb"

    # Pre-seed apt-config selection to avoid interactive prompt
    echo "mysql-apt-config mysql-apt-config/select-server select ${APT_SERIES}" \
        | debconf-set-selections
    echo "mysql-apt-config mysql-apt-config/select-product select Ok" \
        | debconf-set-selections

    DEBIAN_FRONTEND=noninteractive dpkg -i "${TMPDIR}/mysql-apt-config.deb"
    rm -rf "$TMPDIR"
    apt-get update -qq
    success "MySQL APT repository configured for MySQL ${MYSQL_VER}."
else
    info "MySQL APT repository already present."
fi

# ─── Install MySQL ─────────────────────────────────────────────────────────────
info "Installing MySQL ${MYSQL_VER} Community Server..."

# Pre-seed root password to avoid interactive prompt during install
debconf-set-selections <<< "mysql-community-server mysql-community-server/root-pass password ${MYSQL_ROOT_PASS}"
debconf-set-selections <<< "mysql-community-server mysql-community-server/re-root-pass password ${MYSQL_ROOT_PASS}"
debconf-set-selections <<< "mysql-server mysql-server/root_password password ${MYSQL_ROOT_PASS}"
debconf-set-selections <<< "mysql-server mysql-server/root_password_again password ${MYSQL_ROOT_PASS}"

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mysql-community-server

systemctl enable mysql
systemctl start mysql
success "MySQL ${MYSQL_VER} installed and running."

# ─── Secure installation (non-interactive) ────────────────────────────────────
info "Securing MySQL installation..."

mysql -uroot -p"${MYSQL_ROOT_PASS}" <<SQL
-- Remove anonymous users
DELETE FROM mysql.user WHERE User='';

-- Disallow remote root login
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');

-- Remove test database
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

-- Switch root to OS socket auth — no password needed when running as OS root
ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket;

FLUSH PRIVILEGES;
SQL

unset MYSQL_ROOT_PASS
success "MySQL secured. Root login uses OS socket auth (no password)."

# ─── Remote user ───────────────────────────────────────────────────────────────
if [[ -n "$REMOTE_USER" ]]; then
    info "Creating remote user '${REMOTE_USER}'@'${REMOTE_HOST}'..."
    mysql -uroot <<SQL
CREATE USER IF NOT EXISTS '${REMOTE_USER}'@'${REMOTE_HOST}' IDENTIFIED BY '${REMOTE_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${REMOTE_USER}'@'${REMOTE_HOST}' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
    success "Remote user '${REMOTE_USER}'@'${REMOTE_HOST}' created."
fi

# ─── Production my.cnf tuning ─────────────────────────────────────────────────
MYCNF_PROD="/etc/mysql/conf.d/production.cnf"
info "Writing production config to ${MYCNF_PROD}..."

cat > "$MYCNF_PROD" <<CNF
[mysqld]
# ── Connections ──────────────────────────────────────────────────────────────
max_connections            = ${T_MAX_CONN}
max_allowed_packet         = ${T_MAX_PACKET}
thread_cache_size          = ${T_THREAD_CACHE}
table_open_cache           = ${T_TABLE_CACHE}
open_files_limit           = 65535

# ── InnoDB ───────────────────────────────────────────────────────────────────
innodb_buffer_pool_size         = ${T_BUFFER_POOL}
innodb_buffer_pool_instances    = 1
innodb_log_file_size            = ${T_LOG_FILE}
innodb_flush_log_at_trx_commit  = ${T_FLUSH_LOG}
innodb_flush_method             = O_DIRECT
innodb_file_per_table           = ON
innodb_stats_on_metadata        = OFF

# ── Query cache (disabled in 8.x, kept as no-op) ─────────────────────────────
# query_cache_type = 0

# ── Logging ──────────────────────────────────────────────────────────────────
slow_query_log         = ${T_SLOW_LOG}
slow_query_log_file    = /var/log/mysql/slow.log
long_query_time        = ${T_LONG_QUERY}
log_queries_not_using_indexes = ON
general_log            = OFF

# ── Character set ─────────────────────────────────────────────────────────────
character_set_server   = utf8mb4
collation_server       = utf8mb4_unicode_ci

# ── Temp tables ───────────────────────────────────────────────────────────────
tmp_table_size         = 64M
max_heap_table_size    = 64M

# ── Network ───────────────────────────────────────────────────────────────────
bind-address           = ${BIND_ADDR}
CNF

# Ensure slow log directory is writable
mkdir -p /var/log/mysql
chown mysql:mysql /var/log/mysql

# Validate and reload
mysqld --validate-config --defaults-extra-file="$MYCNF_PROD" 2>/dev/null \
    || error "MySQL config validation failed. Check ${MYCNF_PROD}."

systemctl restart mysql
success "Production config applied and MySQL restarted."

# ─── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │                   Installation complete                      │"
echo "  ├─────────────────────────────────────────────────────────────┤"
printf "  │  %-59s │\n" "MySQL version:       $(mysql --version)"
printf "  │  %-59s │\n" "Config file:         ${MYCNF_PROD}"
printf "  │  %-59s │\n" "Slow query log:      /var/log/mysql/slow.log"
printf "  │  %-59s │\n" "Buffer pool size:    ${T_BUFFER_POOL}"
printf "  │  %-59s │\n" "Max connections:     ${T_MAX_CONN}"
printf "  │  %-59s │\n" "Bind address:        ${BIND_ADDR}"
[[ -n "$REMOTE_USER" ]] && \
printf "  │  %-59s │\n" "Remote user:         ${REMOTE_USER}@${REMOTE_HOST}"
echo "  ├─────────────────────────────────────────────────────────────┤"
echo "  │  Next steps:                                                │"
echo "  │   1. Create a database and app user (as OS root):           │"
echo "  │      mysql -uroot                                           │"
echo "  │      CREATE DATABASE myapp CHARACTER SET utf8mb4;           │"
echo "  │      CREATE USER 'myapp'@'localhost' IDENTIFIED BY 'pass';  │"
echo "  │      GRANT ALL ON myapp.* TO 'myapp'@'localhost';           │"
if [[ "$BIND_ADDR" != "127.0.0.1" ]]; then
echo "  │   2. Open firewall port for remote access:                  │"
echo "  │      ufw allow 3306/tcp                                     │"
echo "  │      ufw reload                                             │"
else
echo "  │   2. To allow remote access, set bind-address in:           │"
printf "  │      %-55s │\n" "${MYCNF_PROD}"
fi
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
