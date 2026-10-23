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

# Print a box sized to its longest row. Args: title, then rows; a "---" row
# draws a separator. Padding is computed by hand so the right border stays
# aligned regardless of row length.
print_box() {
    local title="$1"; shift
    local width=${#title} row rule
    for row in "$@"; do
        if (( ${#row} > width )); then width=${#row}; fi
    done
    rule=$(printf '─%.0s' $(seq 1 $(( width + 4 ))))
    local title_pad=$(( (width - ${#title}) / 2 ))

    echo "  ┌${rule}┐"
    printf "  │  %*s%s%*s  │\n" "$title_pad" '' "$title" $(( width - ${#title} - title_pad )) ''
    echo "  ├${rule}┤"
    for row in "$@"; do
        if [[ "$row" == "---" ]]; then
            echo "  ├${rule}┤"
        else
            printf "  │  %s%*s  │\n" "$row" $(( width - ${#row} )) ''
        fi
    done
    echo "  └${rule}┘"
}

# ─── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run this script as root or with sudo."

# ─── Re-run guard ──────────────────────────────────────────────────────────────
# A previous run leaves production.cnf behind. On a configured server, a re-run
# would overwrite tuning (incl. bind-address) and restart MySQL, so require an
# explicit confirmation and skip the steps that touch users and databases.
MYCNF_PROD="/etc/mysql/conf.d/production.cnf"
ALREADY_CONFIGURED=false

if [[ -f "$MYCNF_PROD" ]] && command -v mysql &>/dev/null; then
    ALREADY_CONFIGURED=true
    USER_DBS=$(mysql -uroot -N -e "SELECT schema_name FROM information_schema.schemata
        WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');" \
        2>/dev/null | paste -sd ' ' - || true)

    echo ""
    warn "MySQL has already been configured by this script on this server."
    warn "Existing config: ${MYCNF_PROD}"
    [[ -n "$USER_DBS" ]] && warn "Existing databases: ${USER_DBS}"
    echo ""
    echo "  Re-running will:"
    echo "    - overwrite ${MYCNF_PROD} with the values you enter (a backup is kept)"
    echo "    - restart MySQL, dropping all active connections"
    echo "  It will NOT touch existing users, grants or databases."
    echo ""
    read_input -rp "  Type 'yes' to continue: " RERUN_CONFIRM
    [[ "$RERUN_CONFIRM" == "yes" ]] || { info "Aborted. Nothing was changed."; exit 0; }
fi

# ─── Detect total RAM (MB) for buffer pool default ─────────────────────────────
TOTAL_RAM_MB=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)
DEFAULT_BUFFER_POOL="${TOTAL_RAM_MB%.*}"
# Default to 70% of RAM, minimum 128M
DEFAULT_BUFFER_POOL=$(( DEFAULT_BUFFER_POOL * 70 / 100 ))
(( DEFAULT_BUFFER_POOL < 128 )) && DEFAULT_BUFFER_POOL=128
DEFAULT_BUFFER_POOL="${DEFAULT_BUFFER_POOL}M"

echo ""
echo "  ┌─────────────────────────────────────────────┐"
echo "  │   MySQL Installer + Tuning (Prod)           │"
echo "  └─────────────────────────────────────────────┘"
echo ""

# ─── MySQL version selection ───────────────────────────────────────────────────
echo "  Available MySQL versions (Ubuntu default repo):"
echo "    1) MySQL 8.0  (LTS)"
echo "    2) MySQL 8.4  (LTS)"
echo "    3) MySQL 9.1  (Innovation)"
echo ""
read_input -rp "  Select MySQL version [default: 2]: " ver_choice
echo ""

case "${ver_choice:-2}" in
    1) MYSQL_VER="8.0" ;;
    2) MYSQL_VER="8.4" ;;
    3) MYSQL_VER="9.1" ;;
    *) MYSQL_VER="8.4" ;;
esac

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

# ─── Install MySQL ─────────────────────────────────────────────────────────────
# Each Ubuntu release ships a single MySQL series — check the chosen one exists
# before installing, otherwise fall back to the release's default mysql-server.
if apt-cache show "mysql-server-${MYSQL_VER}" &>/dev/null; then
    MYSQL_PKG="mysql-server-${MYSQL_VER}"
    info "Installing MySQL ${MYSQL_VER} from Ubuntu default repo..."
else
    MYSQL_PKG="mysql-server"
    warn "MySQL ${MYSQL_VER} is not available in this Ubuntu release's repo."
    info "Installing the default mysql-server package instead..."
fi

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$MYSQL_PKG"

systemctl enable mysql
systemctl start mysql
MYSQL_INSTALLED_VER=$(mysqld --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
success "MySQL ${MYSQL_INSTALLED_VER} installed and running."

# ─── Secure installation (non-interactive) ────────────────────────────────────
if $ALREADY_CONFIGURED; then
    info "Skipping secure installation (already done on a previous run)."
else
    info "Securing MySQL installation..."

    # Ubuntu's default mysql-server uses auth_socket for root — connect without password
    mysql -uroot <<SQL
-- Remove anonymous users
DELETE FROM mysql.user WHERE User='';

-- Disallow remote root login
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');

-- Remove test database
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

FLUSH PRIVILEGES;
SQL

    success "MySQL secured. Root login uses OS socket auth (sudo mysql or mysql as root)."
fi

# ─── Remote user ───────────────────────────────────────────────────────────────
REMOTE_USER_EXISTS=0
if [[ -n "$REMOTE_USER" ]]; then
    REMOTE_USER_EXISTS=$(mysql -uroot -N -e "SELECT COUNT(*) FROM mysql.user
        WHERE User='${REMOTE_USER}' AND Host='${REMOTE_HOST}';")
fi

if [[ -n "$REMOTE_USER" && "$REMOTE_USER_EXISTS" != "0" ]]; then
    warn "User '${REMOTE_USER}'@'${REMOTE_HOST}' already exists — leaving its password and grants unchanged."
elif [[ -n "$REMOTE_USER" ]]; then
    info "Creating remote user '${REMOTE_USER}'@'${REMOTE_HOST}'..."
    mysql -uroot <<SQL
CREATE USER IF NOT EXISTS '${REMOTE_USER}'@'${REMOTE_HOST}' IDENTIFIED BY '${REMOTE_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${REMOTE_USER}'@'${REMOTE_HOST}' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
    success "Remote user '${REMOTE_USER}'@'${REMOTE_HOST}' created."
fi

# ─── Production my.cnf tuning ─────────────────────────────────────────────────
if [[ -f "$MYCNF_PROD" ]]; then
    MYCNF_BACKUP="${MYCNF_PROD}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$MYCNF_PROD" "$MYCNF_BACKUP"
    info "Existing config backed up to ${MYCNF_BACKUP}"
fi

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

# Validate the full config mysqld will load (my.cnf includes conf.d/, so this
# covers production.cnf). --defaults-extra-file is not used here because mysqld
# only accepts it as the very first argument.
mysqld --validate-config --user=mysql \
    || error "MySQL config validation failed. Check ${MYCNF_PROD}."

systemctl restart mysql
success "Production config applied and MySQL restarted."

# ─── Summary ───────────────────────────────────────────────────────────────────
SUMMARY_ROWS=(
    "MySQL version:       $(mysql --version)"
    "Config file:         ${MYCNF_PROD}"
    "Slow query log:      /var/log/mysql/slow.log"
    "Buffer pool size:    ${T_BUFFER_POOL}"
    "Max connections:     ${T_MAX_CONN}"
    "Bind address:        ${BIND_ADDR}"
)
[[ -n "$REMOTE_USER" ]] && \
    SUMMARY_ROWS+=("Remote user:         ${REMOTE_USER}@${REMOTE_HOST}")
SUMMARY_ROWS+=(
    "---"
    "Next steps:"
    " 1. Create a database and app user (as OS root):"
    "    mysql -uroot"
    "    CREATE DATABASE myapp CHARACTER SET utf8mb4;"
    "    CREATE USER 'myapp'@'localhost' IDENTIFIED BY 'pass';"
    "    GRANT ALL ON myapp.* TO 'myapp'@'localhost';"
)
if [[ "$BIND_ADDR" != "127.0.0.1" ]]; then
    SUMMARY_ROWS+=(
        " 2. Open firewall port for remote access:"
        "    ufw allow 3306/tcp"
        "    ufw reload"
    )
else
    SUMMARY_ROWS+=(
        " 2. To allow remote access, set bind-address in:"
        "    ${MYCNF_PROD}"
    )
fi

echo ""
print_box "Installation complete" "${SUMMARY_ROWS[@]}"
echo ""
