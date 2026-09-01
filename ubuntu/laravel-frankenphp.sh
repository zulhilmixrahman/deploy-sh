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

# ─── RAM / CPU detection for defaults ─────────────────────────────────────────
TOTAL_RAM_MB=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)
CPU_CORES=$(nproc 2>/dev/null || echo 1)

# FrankenPHP: num_threads defaults to 2x CPU cores (same as FrankenPHP's own default)
DEFAULT_NUM_THREADS=$(( CPU_CORES * 2 ))
(( DEFAULT_NUM_THREADS < 2 )) && DEFAULT_NUM_THREADS=2

echo ""
echo "  ┌───────────────────────────────────────────────┐"
echo "  │   Laravel Stack Installer (FrankenPHP)         │"
echo "  └───────────────────────────────────────────────┘"
echo "  RAM: ${TOTAL_RAM_MB}MB  |  CPUs: ${CPU_CORES}"
echo ""

info "Installing FrankenPHP for Laravel on Ubuntu"
echo ""

# ─── System update ─────────────────────────────────────────────────────────────
info "Updating package lists..."
apt-get update -qq

info "Installing prerequisites..."
apt-get install -y -qq \
    curl \
    ca-certificates \
    unzip \
    git \
    libcap2-bin

# ─── FrankenPHP binary ─────────────────────────────────────────────────────────
FRANKENPHP_BIN="/usr/local/bin/frankenphp"
ARCH="$(uname -m)"

case "$ARCH" in
    x86_64)  ASSET="frankenphp-linux-x86_64" ;;
    aarch64) ASSET="frankenphp-linux-aarch64" ;;
    *) error "Unsupported architecture '${ARCH}'. FrankenPHP prebuilt binaries only support x86_64 and aarch64." ;;
esac

# Ubuntu ships glibc — use the "-gnu" build (mostly static, supports dynamic extension loading)
if getconf GNU_LIBC_VERSION >/dev/null 2>&1; then
    ASSET="${ASSET}-gnu"
fi

DOWNLOAD_URL="https://github.com/php/frankenphp/releases/latest/download/${ASSET}"

info "Downloading FrankenPHP (${ASSET})..."
curl -fL --retry 3 --retry-delay 2 -o "$FRANKENPHP_BIN" "$DOWNLOAD_URL" \
    || error "Failed to download FrankenPHP from ${DOWNLOAD_URL}"

chmod +x "$FRANKENPHP_BIN"

# Allow binding to ports 80/443 without running the service as root
setcap 'cap_net_bind_service=+ep' "$FRANKENPHP_BIN" \
    || warn "setcap failed — relying on systemd AmbientCapabilities to bind privileged ports."

"$FRANKENPHP_BIN" version || error "FrankenPHP binary failed to run after download. Aborting."
success "FrankenPHP installed: $($FRANKENPHP_BIN version)"

# ─── Domain / automatic HTTPS ──────────────────────────────────────────────────
echo ""
echo "  Domain name:"
echo "    If your domain's DNS is already pointing at this server, FrankenPHP can"
echo "    enable automatic HTTPS via Let's Encrypt. Otherwise you can proceed now"
echo "    with plain IP address access and add a domain later."
echo ""

DOMAIN="${DOMAIN:-}"
if [[ -z "$DOMAIN" ]]; then
    read_input -rp "  Is your domain ready (DNS already points here)? [y/N]: " DOMAIN_READY
    DOMAIN_READY="${DOMAIN_READY:-N}"
    if [[ "${DOMAIN_READY,,}" =~ ^y ]]; then
        while [[ -z "$DOMAIN" ]]; do
            read_input -rp "  Domain name: " DOMAIN
        done
    fi
fi

ACME_EMAIL="${ACME_EMAIL:-}"
USE_LETSENCRYPT="${USE_LETSENCRYPT:-}"

if [[ -z "$DOMAIN" ]]; then
    USE_LETSENCRYPT="N"
    SITE_ADDR=":80"
    SERVER_IP="$(curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null || true)"
    [[ -z "$SERVER_IP" ]] && SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ -n "$SERVER_IP" ]]; then
        info "No domain yet — the app will be reachable at http://${SERVER_IP}"
    fi
fi

if [[ -n "$DOMAIN" ]]; then
    if [[ -z "$USE_LETSENCRYPT" ]]; then
        echo ""
        echo "  HTTPS certificate:"
        echo "    - Let's Encrypt: FrankenPHP requests and renews a free certificate automatically."
        echo "    - Manual: serve plain HTTP here and terminate TLS yourself later"
        echo "      (e.g. your own certificate, or another reverse proxy in front)."
        echo ""
        read_input -rp "  Use Let's Encrypt for automatic HTTPS? [Y/n]: " USE_LETSENCRYPT
        USE_LETSENCRYPT="${USE_LETSENCRYPT:-Y}"
    fi

    if [[ "${USE_LETSENCRYPT,,}" =~ ^y ]]; then
        USE_LETSENCRYPT="Y"
        if [[ -z "$ACME_EMAIL" ]]; then
            read_input -rp "  Email for Let's Encrypt renewal notices [none]: " ACME_EMAIL
        fi
        SITE_ADDR="$DOMAIN"
    else
        USE_LETSENCRYPT="N"
        ACME_EMAIL=""
        SITE_ADDR="http://${DOMAIN}"
        warn "Skipping Let's Encrypt — serving plain HTTP on ${DOMAIN}. Set up TLS manually when ready."
    fi
fi
echo ""

# ─── Laravel directory ─────────────────────────────────────────────────────────
if [[ -z "${APP_DIR:-}" ]]; then
    read_input -rp "  Laravel directory name [laravel]: " APP_DIR
fi
APP_DIR="${APP_DIR:-laravel}"
echo ""

WEBROOT="/var/www/${APP_DIR}/public"
PROJECT_ROOT="/var/www/${APP_DIR}"

# ─── Worker mode (Laravel Octane) ──────────────────────────────────────────────
echo "  Worker mode keeps your app booted in memory for much higher throughput,"
echo "  but requires Laravel Octane (composer require laravel/octane) in your app."
echo ""
read_input -rp "  Enable FrankenPHP worker mode for Octane? [y/N]: " WORKER_MODE
WORKER_MODE="${WORKER_MODE:-N}"
echo ""

WORKER_BLOCK=""
if [[ "${WORKER_MODE,,}" =~ ^y ]]; then
    read_input -rp "    Worker count [${DEFAULT_NUM_THREADS}]: " WORKER_NUM
    WORKER_NUM="${WORKER_NUM:-$DEFAULT_NUM_THREADS}"
    WORKER_FILE="${PROJECT_ROOT}/frankenphp-worker.php"
    WORKER_BLOCK="
		worker {
			file ${WORKER_FILE}
			num ${WORKER_NUM}
		}"
    echo ""
fi

# ─── FrankenPHP thread tuning ──────────────────────────────────────────────────
echo "  FrankenPHP tuning (press Enter to keep default):"
echo ""

read_input -rp "    num_threads (PHP threads)     [${DEFAULT_NUM_THREADS}]: " FRANKEN_NUM_THREADS
FRANKEN_NUM_THREADS="${FRANKEN_NUM_THREADS:-$DEFAULT_NUM_THREADS}"

read_input -rp "    max_threads (autoscale cap)   [${FRANKEN_NUM_THREADS}]: " FRANKEN_MAX_THREADS
FRANKEN_MAX_THREADS="${FRANKEN_MAX_THREADS:-$FRANKEN_NUM_THREADS}"

read_input -rp "    max_requests (thread recycle) [500]: " FRANKEN_MAX_REQUESTS
FRANKEN_MAX_REQUESTS="${FRANKEN_MAX_REQUESTS:-500}"
echo ""

# ─── PHP INI tuning ────────────────────────────────────────────────────────────
echo "  PHP INI tuning (press Enter to keep default):"
echo ""

read_input -rp "    upload_max_filesize  [64M]:   " INI_UPLOAD;    INI_UPLOAD="${INI_UPLOAD:-64M}"
read_input -rp "    post_max_size        [64M]:   " INI_POST;      INI_POST="${INI_POST:-64M}"
read_input -rp "    memory_limit         [256M]:  " INI_MEMORY;    INI_MEMORY="${INI_MEMORY:-256M}"
read_input -rp "    max_execution_time   [60]:    " INI_EXEC_TIME; INI_EXEC_TIME="${INI_EXEC_TIME:-60}"
read_input -rp "    date.timezone        [UTC]:   " INI_TIMEZONE;  INI_TIMEZONE="${INI_TIMEZONE:-UTC}"
read_input -rp "    opcache.memory_consumption    [128]:  " INI_OPC_MEM;   INI_OPC_MEM="${INI_OPC_MEM:-128}"
read_input -rp "    opcache.max_accelerated_files [10000]:" INI_OPC_FILES; INI_OPC_FILES="${INI_OPC_FILES:-10000}"
read_input -rp "    opcache.revalidate_freq       [0]:    " INI_OPC_FREQ;  INI_OPC_FREQ="${INI_OPC_FREQ:-0}"
echo ""

# ─── Directories ────────────────────────────────────────────────────────────────
info "Creating FrankenPHP directories..."
mkdir -p /etc/frankenphp/php.d /etc/frankenphp/Caddyfile.d
mkdir -p /var/lib/frankenphp/data /var/lib/frankenphp/config
mkdir -p /var/log/frankenphp
mkdir -p "$PROJECT_ROOT"
chown -R www-data:www-data /var/lib/frankenphp /var/log/frankenphp

# ─── PHP INI ────────────────────────────────────────────────────────────────────
PHP_INI="/etc/frankenphp/php.ini"
info "Writing PHP INI at ${PHP_INI}..."

cat > "$PHP_INI" <<INI
[PHP]
; ── Laravel / production baseline ──────────────────────────────────────────
short_open_tag        = Off
expose_php            = Off
display_errors        = Off
display_startup_errors = Off
log_errors            = On
error_log              = /var/log/frankenphp/php-error.log

upload_max_filesize   = ${INI_UPLOAD}
post_max_size         = ${INI_POST}
memory_limit          = ${INI_MEMORY}
max_execution_time    = ${INI_EXEC_TIME}
date.timezone         = ${INI_TIMEZONE}

realpath_cache_size   = 4096K
realpath_cache_ttl    = 600

; ── Session hardening ───────────────────────────────────────────────────────
session.cookie_secure   = 1
session.cookie_httponly = 1
session.use_strict_mode = 1
session.cookie_samesite = "Lax"

[opcache]
opcache.enable                = 1
opcache.enable_cli            = 0
opcache.memory_consumption    = ${INI_OPC_MEM}
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = ${INI_OPC_FILES}
opcache.revalidate_freq       = ${INI_OPC_FREQ}
opcache.validate_timestamps   = 1
opcache.save_comments         = 1
opcache.fast_shutdown         = 1
opcache.jit                   = tracing
opcache.jit_buffer_size       = 64M
INI

success "PHP INI written."

# ─── Caddyfile ──────────────────────────────────────────────────────────────────
CADDYFILE="/etc/frankenphp/Caddyfile"
info "Writing Caddyfile at ${CADDYFILE}..."

{
    printf '%s\n' "{"
    printf '\tfrankenphp {\n'
    printf '\t\tnum_threads %s\n' "${FRANKEN_NUM_THREADS}"
    printf '\t\tmax_threads %s\n' "${FRANKEN_MAX_THREADS}"
    printf '\t\tmax_requests %s\n' "${FRANKEN_MAX_REQUESTS}"
    if [[ -n "$WORKER_BLOCK" ]]; then
        printf '%s\n' "$WORKER_BLOCK"
    fi
    printf '\t}\n'
    if [[ -n "$ACME_EMAIL" ]]; then
        printf '\temail %s\n' "$ACME_EMAIL"
    fi
    printf '}\n\n'

    printf '%s {\n' "$SITE_ADDR"
    printf '\troot * %s\n' "$WEBROOT"
    printf '\tencode zstd br gzip\n\n'

    printf '\t# Block dotfiles / stray project files accidentally deployed under public/\n'
    printf '\t# (public/storage is intentionally left reachable — it is the Laravel storage:link symlink)\n'
    printf '\t@forbidden {\n'
    printf '\t\tpath /.env* /.git/* /composer.*\n'
    printf '\t}\n'
    printf '\trespond @forbidden 404\n\n'

    printf '\tphp_server {\n'
    printf '\t\ttry_files {path} index.php\n'
    printf '\t}\n\n'

    printf '\theader {\n'
    printf '\t\tX-Frame-Options        "SAMEORIGIN"\n'
    printf '\t\tX-Content-Type-Options "nosniff"\n'
    printf '\t\tX-XSS-Protection       "1; mode=block"\n'
    printf '\t\tReferrer-Policy        "strict-origin-when-cross-origin"\n'
    printf '\t\tPermissions-Policy     "geolocation=(), microphone=()"\n'
    printf '\t\t-Server\n'
    printf '\t}\n\n'

    printf '\tlog {\n'
    printf '\t\toutput file /var/log/frankenphp/%s-access.log {\n' "$APP_DIR"
    printf '\t\t\troll_size 100mb\n'
    printf '\t\t\troll_keep 10\n'
    printf '\t\t\troll_keep_for 720h\n'
    printf '\t\t}\n'
    printf '\t}\n'
    printf '}\n\n'

    printf '# Drop extra .caddyfile site blocks in Caddyfile.d/ and they are loaded automatically\n'
    printf 'import Caddyfile.d/*.caddyfile\n'
} > "$CADDYFILE"

"$FRANKENPHP_BIN" validate --config "$CADDYFILE" --adapter caddyfile \
    || error "Caddyfile validation failed. Check ${CADDYFILE}."
success "Caddyfile written and validated."

# ─── systemd service ────────────────────────────────────────────────────────────
SERVICE_FILE="/etc/systemd/system/frankenphp.service"
info "Writing systemd service at ${SERVICE_FILE}..."

cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=FrankenPHP application server for Laravel
Documentation=https://frankenphp.dev/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=www-data
Group=www-data
WorkingDirectory=${PROJECT_ROOT}
Environment=XDG_DATA_HOME=/var/lib/frankenphp/data
Environment=XDG_CONFIG_HOME=/var/lib/frankenphp/config
ExecStart=${FRANKENPHP_BIN} run --config ${CADDYFILE} --adapter caddyfile
ExecReload=${FRANKENPHP_BIN} reload --config ${CADDYFILE} --adapter caddyfile --force
Restart=on-failure
RestartSec=2
TimeoutStopSec=10s

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${PROJECT_ROOT} /var/lib/frankenphp /var/log/frankenphp

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now frankenphp
success "FrankenPHP service installed and running."

# ─── Composer ──────────────────────────────────────────────────────────────────
read_input -rp "  Install Composer? [Y/n]: " INSTALL_COMPOSER
INSTALL_COMPOSER="${INSTALL_COMPOSER:-Y}"
echo ""

if [[ "${INSTALL_COMPOSER,,}" =~ ^y ]]; then
    if command -v composer &>/dev/null; then
        success "Composer already installed: $(composer --version --no-ansi)"
    else
        info "Installing Composer..."
        EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");' 2>/dev/null || true)"

        if [[ -z "$EXPECTED_CHECKSUM" ]]; then
            warn "System PHP CLI not found — installing Composer without checksum verification via FrankenPHP's bundled PHP."
            "$FRANKENPHP_BIN" php-cli -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
            "$FRANKENPHP_BIN" php-cli composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
            rm -f composer-setup.php
        else
            php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
            ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

            if [[ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]]; then
                rm -f composer-setup.php
                error "Composer installer checksum mismatch. Aborting."
            fi

            php composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
            rm -f composer-setup.php
        fi
        success "Composer installed: $(composer --version --no-ansi)"
    fi
else
    warn "Skipping Composer installation."
fi

# ─── Webroot ───────────────────────────────────────────────────────────────────
info "Project root ${PROJECT_ROOT} not populated — deploy your Laravel app there manually."

# ─── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │                   Installation complete                      │"
echo "  ├─────────────────────────────────────────────────────────────┤"
printf "  │  %-59s │\n" "FrankenPHP:     $($FRANKENPHP_BIN version)"
printf "  │  %-59s │\n" "Threads:        num=${FRANKEN_NUM_THREADS}, max=${FRANKEN_MAX_THREADS}"
printf "  │  %-59s │\n" "Worker mode:    $([[ -n "$WORKER_BLOCK" ]] && echo "enabled (${WORKER_NUM} workers)" || echo "disabled (classic mode)")"
printf "  │  %-59s │\n" "Site address:   ${SITE_ADDR}"
if [[ -z "$DOMAIN" && -n "${SERVER_IP:-}" ]]; then
printf "  │  %-59s │\n" "Access URL:     http://${SERVER_IP}"
fi
printf "  │  %-59s │\n" "Project root:   ${PROJECT_ROOT}"
printf "  │  %-59s │\n" "Webroot:        ${WEBROOT}"
printf "  │  %-59s │\n" "Caddyfile:      ${CADDYFILE}"
printf "  │  %-59s │\n" "PHP error log:  /var/log/frankenphp/php-error.log"
echo "  ├─────────────────────────────────────────────────────────────┤"
echo "  │  Next steps:                                                │"
printf "  │   1. Deploy Laravel app to %-31s │\n" "${PROJECT_ROOT}"
printf "  │   2. chown -R www-data:www-data %-27s │\n" "${PROJECT_ROOT}"
printf "  │   3. chmod -R 775 %-39s │\n" "${PROJECT_ROOT}/storage"
if [[ -n "$WORKER_BLOCK" ]]; then
echo "  │   4. composer require laravel/octane                        │"
echo "  │      php artisan octane:install --server=frankenphp          │"
echo "  │   5. systemctl restart frankenphp                            │"
else
echo "  │   4. systemctl restart frankenphp                            │"
fi
if [[ -z "$DOMAIN" ]]; then
echo "  │   5. Once your domain is ready, re-run to enable HTTPS       │"
elif [[ "$USE_LETSENCRYPT" == "N" ]]; then
echo "  │   5. Set up TLS manually (own cert or reverse proxy)         │"
fi
echo "  │   6. Logs: journalctl -u frankenphp -f                      │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
