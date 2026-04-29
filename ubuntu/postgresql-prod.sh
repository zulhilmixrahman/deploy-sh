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

# ─── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run this script as root or with sudo."

# Re-attach stdin to the terminal so read prompts work when piped via curl | bash
[[ -t 0 ]] || exec < /dev/tty

# ─── Detect RAM for tuning defaults ───────────────────────────────────────────
TOTAL_RAM_MB=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)

# shared_buffers = 25% RAM, min 128M
DEFAULT_SHARED_BUFFERS=$(( TOTAL_RAM_MB * 25 / 100 ))
(( DEFAULT_SHARED_BUFFERS < 128 )) && DEFAULT_SHARED_BUFFERS=128
DEFAULT_SHARED_BUFFERS="${DEFAULT_SHARED_BUFFERS}MB"

# effective_cache_size = 75% RAM
DEFAULT_CACHE_SIZE=$(( TOTAL_RAM_MB * 75 / 100 ))
(( DEFAULT_CACHE_SIZE < 128 )) && DEFAULT_CACHE_SIZE=128
DEFAULT_CACHE_SIZE="${DEFAULT_CACHE_SIZE}MB"

# maintenance_work_mem = 5% RAM, min 64M, max 2048M
DEFAULT_MAINT_MEM=$(( TOTAL_RAM_MB * 5 / 100 ))
(( DEFAULT_MAINT_MEM < 64   )) && DEFAULT_MAINT_MEM=64
(( DEFAULT_MAINT_MEM > 2048 )) && DEFAULT_MAINT_MEM=2048
DEFAULT_MAINT_MEM="${DEFAULT_MAINT_MEM}MB"

# max_worker_processes = number of CPU cores
DEFAULT_WORKERS=$(nproc 2>/dev/null || echo 2)

echo ""
echo "  ┌───────────────────────────────────────────────┐"
echo "  │   PostgreSQL Installer + Tuning (Production)   │"
echo "  └───────────────────────────────────────────────┘"
echo ""

# ─── PostgreSQL version selection ─────────────────────────────────────────────
echo "  Available PostgreSQL versions:"
echo "    1) PostgreSQL 13"
echo "    2) PostgreSQL 14"
echo "    3) PostgreSQL 15"
echo "    4) PostgreSQL 16"
echo "    5) PostgreSQL 17  (latest)"
echo ""
read -rp "  Select version [default: 5]: " ver_choice
echo ""

case "${ver_choice:-5}" in
    1) PG_VER="13" ;;
    2) PG_VER="14" ;;
    3) PG_VER="15" ;;
    4) PG_VER="16" ;;
    5) PG_VER="17" ;;
    *) PG_VER="17" ;;
esac

# ─── Storage type (affects I/O tuning) ────────────────────────────────────────
echo "  Storage type:"
echo "    1) SSD"
echo "    2) HDD"
echo ""
read -rp "  Select storage type [default: 1]: " storage_choice
echo ""

case "${storage_choice:-1}" in
    1) RANDOM_PAGE_COST="1.1"; EFFECTIVE_IO_CONCURRENCY="200" ;;
    2) RANDOM_PAGE_COST="4.0"; EFFECTIVE_IO_CONCURRENCY="2"   ;;
    *) RANDOM_PAGE_COST="1.1"; EFFECTIVE_IO_CONCURRENCY="200" ;;
esac

# ─── Production tuning prompts ────────────────────────────────────────────────
echo "  Production tuning (press Enter to keep default):"
echo "  Server RAM detected: ${TOTAL_RAM_MB}MB | CPUs: ${DEFAULT_WORKERS}"
echo ""

read -rp "    shared_buffers           [${DEFAULT_SHARED_BUFFERS}]: " T_SHARED_BUFFERS
T_SHARED_BUFFERS="${T_SHARED_BUFFERS:-$DEFAULT_SHARED_BUFFERS}"

read -rp "    effective_cache_size     [${DEFAULT_CACHE_SIZE}]: " T_CACHE_SIZE
T_CACHE_SIZE="${T_CACHE_SIZE:-$DEFAULT_CACHE_SIZE}"

read -rp "    maintenance_work_mem     [${DEFAULT_MAINT_MEM}]: " T_MAINT_MEM
T_MAINT_MEM="${T_MAINT_MEM:-$DEFAULT_MAINT_MEM}"

read -rp "    work_mem                 [4MB]:   " T_WORK_MEM
T_WORK_MEM="${T_WORK_MEM:-4MB}"

read -rp "    max_connections          [100]:   " T_MAX_CONN
T_MAX_CONN="${T_MAX_CONN:-100}"

read -rp "    max_worker_processes     [${DEFAULT_WORKERS}]:     " T_WORKERS
T_WORKERS="${T_WORKERS:-$DEFAULT_WORKERS}"

read -rp "    log_min_duration_statement (ms, -1=off) [1000]: " T_SLOW_MS
T_SLOW_MS="${T_SLOW_MS:-1000}"

read -rp "    wal_buffers              [16MB]:  " T_WAL_BUFFERS
T_WAL_BUFFERS="${T_WAL_BUFFERS:-16MB}"

read -rp "    checkpoint_completion_target [0.9]: " T_CHECKPOINT
T_CHECKPOINT="${T_CHECKPOINT:-0.9}"

echo ""

# ─── Remote access ─────────────────────────────────────────────────────────────
read -rp "  Allow remote connections? [y/N]: " REMOTE_ACCESS
REMOTE_ACCESS="${REMOTE_ACCESS,,}"

LISTEN_ADDR="localhost"
REMOTE_CIDR=""
REMOTE_USER=""
REMOTE_PASS=""

if [[ "$REMOTE_ACCESS" == "y" || "$REMOTE_ACCESS" == "yes" ]]; then
    read -rp "    listen_addresses ('*' = all interfaces) [*]: " LISTEN_ADDR
    LISTEN_ADDR="${LISTEN_ADDR:-*}"

    read -rp "    Allowed client CIDR (e.g. 10.0.0.0/8, 0.0.0.0/0 = any) [0.0.0.0/0]: " REMOTE_CIDR
    REMOTE_CIDR="${REMOTE_CIDR:-0.0.0.0/0}"

    read -rp "    Create a dedicated remote user? [y/N]: " CREATE_REMOTE_USER
    if [[ "${CREATE_REMOTE_USER,,}" == "y" || "${CREATE_REMOTE_USER,,}" == "yes" ]]; then
        read -rp "      Remote username [remoteuser]: " REMOTE_USER
        REMOTE_USER="${REMOTE_USER:-remoteuser}"
        while true; do
            read -rsp "      Password for '${REMOTE_USER}': " REMOTE_PASS; echo ""
            read -rsp "      Confirm password: " REMOTE_PASS2; echo ""
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
    apt-transport-https

# ─── PostgreSQL APT repository ────────────────────────────────────────────────
if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
    info "Adding PostgreSQL APT repository..."
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg

    echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list

    apt-get update -qq
    success "PostgreSQL APT repository configured."
else
    info "PostgreSQL APT repository already present."
fi

# ─── Install PostgreSQL ────────────────────────────────────────────────────────
info "Installing PostgreSQL ${PG_VER}..."
apt-get install -y -qq "postgresql-${PG_VER}" "postgresql-client-${PG_VER}"

systemctl enable postgresql
systemctl start postgresql
success "PostgreSQL ${PG_VER} installed and running."

# ─── Remote user ───────────────────────────────────────────────────────────────
if [[ -n "$REMOTE_USER" ]]; then
    info "Creating remote user '${REMOTE_USER}'..."
    su -c "psql -c \"CREATE USER ${REMOTE_USER} WITH ENCRYPTED PASSWORD '${REMOTE_PASS}';\"" postgres
    success "Remote user '${REMOTE_USER}' created."
fi

# ─── Enforce password authentication (replace peer/trust with scram) ──────────
PG_HBA="/etc/postgresql/${PG_VER}/main/pg_hba.conf"
info "Configuring pg_hba.conf for password authentication..."

# Back up original
cp "${PG_HBA}" "${PG_HBA}.bak"

# Keep peer for postgres OS user; enforce scram-sha-256 for all others
sed -i \
    -e 's/^\(local\s\+all\s\+all\s\+\)peer/\1scram-sha-256/' \
    -e 's/^\(host.*\s\+\)trust/\1scram-sha-256/' \
    "$PG_HBA"

if [[ -n "$REMOTE_CIDR" ]]; then
    echo "host    all             all             ${REMOTE_CIDR}          scram-sha-256" >> "$PG_HBA"
    info "Remote CIDR ${REMOTE_CIDR} added to pg_hba.conf."
fi

success "pg_hba.conf updated."

# ─── Production config ─────────────────────────────────────────────────────────
PG_CONF_DIR="/etc/postgresql/${PG_VER}/main/conf.d"
mkdir -p "$PG_CONF_DIR"
PROD_CONF="${PG_CONF_DIR}/production.conf"

info "Writing production config to ${PROD_CONF}..."

cat > "$PROD_CONF" <<CONF
# ── Memory ────────────────────────────────────────────────────────────────────
shared_buffers                 = ${T_SHARED_BUFFERS}
effective_cache_size           = ${T_CACHE_SIZE}
maintenance_work_mem           = ${T_MAINT_MEM}
work_mem                       = ${T_WORK_MEM}

# ── Connections ───────────────────────────────────────────────────────────────
listen_addresses               = '${LISTEN_ADDR}'
max_connections                = ${T_MAX_CONN}

# ── WAL / Checkpoints ─────────────────────────────────────────────────────────
wal_buffers                    = ${T_WAL_BUFFERS}
checkpoint_completion_target   = ${T_CHECKPOINT}
wal_compression                = on
min_wal_size                   = 1GB
max_wal_size                   = 4GB

# ── Parallelism ───────────────────────────────────────────────────────────────
max_worker_processes           = ${T_WORKERS}
max_parallel_workers           = ${T_WORKERS}
max_parallel_workers_per_gather = $(( T_WORKERS / 2 > 0 ? T_WORKERS / 2 : 1 ))
max_parallel_maintenance_workers = $(( T_WORKERS / 2 > 0 ? T_WORKERS / 2 : 1 ))

# ── Planner ───────────────────────────────────────────────────────────────────
random_page_cost               = ${RANDOM_PAGE_COST}
effective_io_concurrency       = ${EFFECTIVE_IO_CONCURRENCY}
default_statistics_target      = 100

# ── Logging ───────────────────────────────────────────────────────────────────
log_min_duration_statement     = ${T_SLOW_MS}
log_checkpoints                = on
log_connections                = off
log_disconnections             = off
log_lock_waits                 = on
log_temp_files                 = 0
log_autovacuum_min_duration    = 250ms
log_line_prefix                = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '

# ── Character set ─────────────────────────────────────────────────────────────
lc_messages                    = 'en_US.UTF-8'
lc_monetary                    = 'en_US.UTF-8'
lc_numeric                     = 'en_US.UTF-8'
lc_time                        = 'en_US.UTF-8'

# ── Misc ──────────────────────────────────────────────────────────────────────
idle_in_transaction_session_timeout = 60000
lock_timeout                   = 30000
CONF

# Ensure conf.d is included — postgresql.conf should already include it in pg16+
# Add include_dir if missing
PG_MAIN_CONF="/etc/postgresql/${PG_VER}/main/postgresql.conf"
if ! grep -q "include_dir.*conf.d" "$PG_MAIN_CONF"; then
    echo "" >> "$PG_MAIN_CONF"
    echo "include_dir = 'conf.d'" >> "$PG_MAIN_CONF"
    info "Added include_dir = 'conf.d' to postgresql.conf."
fi

# listen_addresses requires a full restart; reload suffices for everything else
if [[ -n "$REMOTE_CIDR" ]]; then
    su -c "pg_ctlcluster ${PG_VER} main restart" postgres
    success "Production config applied and PostgreSQL restarted."
else
    su -c "pg_ctlcluster ${PG_VER} main reload" postgres
    success "Production config applied and PostgreSQL reloaded."
fi

# ─── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │                   Installation complete                      │"
echo "  ├─────────────────────────────────────────────────────────────┤"
printf "  │  %-59s │\n" "PostgreSQL version:  $(psql --version)"
printf "  │  %-59s │\n" "Config file:         ${PROD_CONF}"
printf "  │  %-59s │\n" "pg_hba.conf:         ${PG_HBA}"
printf "  │  %-59s │\n" "shared_buffers:      ${T_SHARED_BUFFERS}"
printf "  │  %-59s │\n" "effective_cache_size:${T_CACHE_SIZE}"
printf "  │  %-59s │\n" "max_connections:     ${T_MAX_CONN}"
printf "  │  %-59s │\n" "Slow query log:      >= ${T_SLOW_MS}ms"
printf "  │  %-59s │\n" "listen_addresses:    ${LISTEN_ADDR}"
[[ -n "$REMOTE_CIDR"  ]] && printf "  │  %-59s │\n" "Remote CIDR:         ${REMOTE_CIDR}"
[[ -n "$REMOTE_USER"  ]] && printf "  │  %-59s │\n" "Remote user:         ${REMOTE_USER}"
echo "  ├─────────────────────────────────────────────────────────────┤"
echo "  │  Next steps:                                                │"
echo "  │   1. Create a database and app user (as OS postgres):       │"
echo "  │      sudo -u postgres psql                                  │"
echo "  │      CREATE DATABASE myapp ENCODING 'UTF8';                 │"
echo "  │      CREATE USER myapp WITH ENCRYPTED PASSWORD 'pass';      │"
echo "  │      GRANT ALL PRIVILEGES ON DATABASE myapp TO myapp;       │"
if [[ -n "$REMOTE_CIDR" ]]; then
echo "  │   2. Open firewall port for remote access:                  │"
echo "  │      ufw allow 5432/tcp                                     │"
echo "  │      ufw reload                                             │"
else
echo "  │   2. To allow remote access, edit listen_addresses in:      │"
printf "  │      %-55s │\n" "${PG_MAIN_CONF}"
echo "  │      and add a host entry in pg_hba.conf                    │"
fi
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
