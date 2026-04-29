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

# PHP-FPM: max_children = 75% RAM / 50MB per process, min 2
DEFAULT_FPM_MAX=$(( TOTAL_RAM_MB * 75 / 100 / 50 ))
(( DEFAULT_FPM_MAX < 2 )) && DEFAULT_FPM_MAX=2
DEFAULT_FPM_START=$(( DEFAULT_FPM_MAX / 4 > 1 ? DEFAULT_FPM_MAX / 4 : 2 ))
DEFAULT_FPM_MIN_SPARE=$(( DEFAULT_FPM_MAX / 4 > 1 ? DEFAULT_FPM_MAX / 4 : 1 ))
DEFAULT_FPM_MAX_SPARE=$(( DEFAULT_FPM_MAX / 2 > 2 ? DEFAULT_FPM_MAX / 2 : 3 ))

echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │   Laravel Stack Installer (Nginx + PHP)  │"
echo "  └─────────────────────────────────────────┘"
echo "  RAM: ${TOTAL_RAM_MB}MB  |  CPUs: ${CPU_CORES}"
echo ""

# ─── PHP version selection ─────────────────────────────────────────────────────
SUPPORTED_VERSIONS=("7.4" "8.0" "8.1" "8.2" "8.3" "8.4")

if [[ -n "${PHP_VERSION:-}" ]]; then
    PHP_VER="$PHP_VERSION"
else
    echo "  Available PHP versions:"
    for i in "${!SUPPORTED_VERSIONS[@]}"; do
        echo "    $((i+1))) PHP ${SUPPORTED_VERSIONS[$i]}"
    done
    echo ""
    read_input -rp "  Select PHP version [default: 8.3]: " choice
    choice="${choice:-5}"

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#SUPPORTED_VERSIONS[@]} )); then
        PHP_VER="${SUPPORTED_VERSIONS[$((choice-1))]}"
    elif [[ "$choice" =~ ^[0-9]+\.[0-9]+$ ]]; then
        PHP_VER="$choice"
    else
        PHP_VER="8.3"
    fi
fi

valid=false
for v in "${SUPPORTED_VERSIONS[@]}"; do
    [[ "$v" == "$PHP_VER" ]] && valid=true && break
done
$valid || error "Unsupported PHP version '$PHP_VER'. Choose from: ${SUPPORTED_VERSIONS[*]}"

info "Installing Nginx + PHP ${PHP_VER} for Laravel on Ubuntu"
echo ""

# ─── System update ─────────────────────────────────────────────────────────────
info "Updating package lists..."
apt-get update -qq

info "Installing prerequisites..."
apt-get install -y -qq \
    curl \
    gnupg2 \
    ca-certificates \
    lsb-release \
    software-properties-common \
    apt-transport-https \
    unzip \
    git

# ─── Ondřej Surý PPAs ─────────────────────────────────────────────────────────
info "Adding Ondřej Surý Nginx PPA..."
add-apt-repository -y ppa:ondrej/nginx > /dev/null 2>&1
info "Adding Ondřej Surý PHP PPA..."
add-apt-repository -y ppa:ondrej/php > /dev/null 2>&1
apt-get update -qq
success "Ondřej Surý PPAs ready."

# ─── Nginx ─────────────────────────────────────────────────────────────────────
info "Installing Nginx..."
apt-get install -y -qq nginx
systemctl enable nginx
systemctl start nginx
success "Nginx installed and running."

# ─── Nginx global tuning ──────────────────────────────────────────────────────
echo ""
echo "  Nginx global tuning (press Enter to keep default):"
echo ""

read_input -rp "    worker_connections   [1024]:  " NGX_WORKER_CONN
NGX_WORKER_CONN="${NGX_WORKER_CONN:-1024}"

read_input -rp "    keepalive_timeout    [65]:    " NGX_KEEPALIVE
NGX_KEEPALIVE="${NGX_KEEPALIVE:-65}"

read_input -rp "    client_max_body_size [64M]:   " NGX_CLIENT_MAX
NGX_CLIENT_MAX="${NGX_CLIENT_MAX:-64M}"

read_input -rp "    gzip compression     [on]:    " NGX_GZIP
NGX_GZIP="${NGX_GZIP:-on}"
echo ""

info "Writing Nginx global production config..."
NGINX_PROD_CONF="/etc/nginx/conf.d/production.conf"
cat > "$NGINX_PROD_CONF" <<NGX
# ── Process ───────────────────────────────────────────────────────────────────
worker_rlimit_nofile 65535;

# ── Security ──────────────────────────────────────────────────────────────────
server_tokens off;

# ── Timeouts ──────────────────────────────────────────────────────────────────
keepalive_timeout         ${NGX_KEEPALIVE};
keepalive_requests        1000;
client_body_timeout       30;
client_header_timeout     30;
send_timeout              30;
reset_timedout_connection on;

# ── Buffer sizes ──────────────────────────────────────────────────────────────
client_body_buffer_size   128k;
client_header_buffer_size 1k;
client_max_body_size      ${NGX_CLIENT_MAX};
large_client_header_buffers 4 16k;

# ── File serving ──────────────────────────────────────────────────────────────
sendfile    on;
tcp_nopush  on;
tcp_nodelay on;

# ── Gzip ──────────────────────────────────────────────────────────────────────
gzip              ${NGX_GZIP};
gzip_vary         on;
gzip_proxied      any;
gzip_comp_level   5;
gzip_min_length   256;
gzip_types
    text/plain text/css text/xml text/javascript
    application/json application/javascript application/xml
    application/rss+xml application/atom+xml image/svg+xml
    font/truetype font/opentype application/vnd.ms-fontobject;
NGX

# Set worker_connections in events block via included snippet
NGINX_EVENTS_CONF="/etc/nginx/conf.d/events.conf"
# worker_connections lives inside the events block — patch nginx.conf directly
sed -i "s/worker_connections [0-9]\+;/worker_connections ${NGX_WORKER_CONN};/" \
    /etc/nginx/nginx.conf

nginx -t && systemctl reload nginx
success "Nginx global production config applied."

# ─── Database selection ────────────────────────────────────────────────────────
echo ""
echo "  Available databases:"
echo "    1) MySQL / MariaDB"
echo "    2) PostgreSQL"
echo "    3) SQLite"
echo ""
read_input -rp "  Select database [default: 1]: " db_choice
echo ""

case "${db_choice:-1}" in
    1) DB_EXT="php${PHP_VER}-mysql";    DB_NAME="MySQL / MariaDB" ;;
    2) DB_EXT="php${PHP_VER}-pgsql";    DB_NAME="PostgreSQL" ;;
    3) DB_EXT="php${PHP_VER}-sqlite3";  DB_NAME="SQLite" ;;
    *) DB_EXT="php${PHP_VER}-mysql";    DB_NAME="MySQL / MariaDB" ;;
esac

# ─── PHP extensions ────────────────────────────────────────────────────────────
PHP_EXTENSIONS=(
    "php${PHP_VER}-fpm"
    "php${PHP_VER}-cli"
    "php${PHP_VER}-common"
    "$DB_EXT"
    "php${PHP_VER}-mbstring"
    "php${PHP_VER}-xml"
    "php${PHP_VER}-bcmath"
    "php${PHP_VER}-curl"
    "php${PHP_VER}-zip"
    "php${PHP_VER}-gd"
    "php${PHP_VER}-intl"
    "php${PHP_VER}-opcache"
    "php${PHP_VER}-redis"
    "php${PHP_VER}-tokenizer"
)

info "Installing PHP ${PHP_VER} and extensions (DB: ${DB_NAME})..."
apt-get install -y -qq "${PHP_EXTENSIONS[@]}"
systemctl enable "php${PHP_VER}-fpm"
systemctl start  "php${PHP_VER}-fpm"
success "PHP ${PHP_VER}-FPM installed and running."

# ─── PHP-FPM pool tuning ──────────────────────────────────────────────────────
echo ""
echo "  PHP-FPM pool tuning (press Enter to keep default):"
echo "  Detected RAM: ${TOTAL_RAM_MB}MB — estimated ~50MB per PHP process"
echo ""

read_input -rp "    pm                   [dynamic]:  " FPM_PM
FPM_PM="${FPM_PM:-dynamic}"

read_input -rp "    pm.max_children      [${DEFAULT_FPM_MAX}]:      " FPM_MAX_CHILDREN
FPM_MAX_CHILDREN="${FPM_MAX_CHILDREN:-$DEFAULT_FPM_MAX}"

read_input -rp "    pm.start_servers     [${DEFAULT_FPM_START}]:       " FPM_START
FPM_START="${FPM_START:-$DEFAULT_FPM_START}"

read_input -rp "    pm.min_spare_servers [${DEFAULT_FPM_MIN_SPARE}]:       " FPM_MIN_SPARE
FPM_MIN_SPARE="${FPM_MIN_SPARE:-$DEFAULT_FPM_MIN_SPARE}"

read_input -rp "    pm.max_spare_servers [${DEFAULT_FPM_MAX_SPARE}]:       " FPM_MAX_SPARE
FPM_MAX_SPARE="${FPM_MAX_SPARE:-$DEFAULT_FPM_MAX_SPARE}"

read_input -rp "    pm.max_requests      [500]:      " FPM_MAX_REQUESTS
FPM_MAX_REQUESTS="${FPM_MAX_REQUESTS:-500}"
echo ""

FPM_POOL_CONF="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
info "Tuning PHP-FPM pool at ${FPM_POOL_CONF}..."

sed -i "s/^pm = .*/pm = ${FPM_PM}/"                                    "$FPM_POOL_CONF"
sed -i "s/^pm.max_children = .*/pm.max_children = ${FPM_MAX_CHILDREN}/" "$FPM_POOL_CONF"
sed -i "s/^pm.start_servers = .*/pm.start_servers = ${FPM_START}/"      "$FPM_POOL_CONF"
sed -i "s/^pm.min_spare_servers = .*/pm.min_spare_servers = ${FPM_MIN_SPARE}/" "$FPM_POOL_CONF"
sed -i "s/^pm.max_spare_servers = .*/pm.max_spare_servers = ${FPM_MAX_SPARE}/" "$FPM_POOL_CONF"
sed -i "s/^;pm.max_requests = .*/pm.max_requests = ${FPM_MAX_REQUESTS}/" "$FPM_POOL_CONF"
# Uncomment if commented
grep -q "^pm.max_requests" "$FPM_POOL_CONF" \
    || echo "pm.max_requests = ${FPM_MAX_REQUESTS}" >> "$FPM_POOL_CONF"

# Enable FPM status page for monitoring
sed -i 's|^;pm.status_path = .*|pm.status_path = /fpm-status|' "$FPM_POOL_CONF"

success "PHP-FPM pool tuned."

# ─── PHP INI tuning ───────────────────────────────────────────────────────────
PHP_INI="/etc/php/${PHP_VER}/fpm/php.ini"

echo ""
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

info "Tuning PHP INI at ${PHP_INI}..."

sed -i "s/^upload_max_filesize = .*/upload_max_filesize = ${INI_UPLOAD}/"  "$PHP_INI"
sed -i "s/^post_max_size = .*/post_max_size = ${INI_POST}/"                "$PHP_INI"
sed -i "s/^memory_limit = .*/memory_limit = ${INI_MEMORY}/"                "$PHP_INI"
sed -i "s/^max_execution_time = .*/max_execution_time = ${INI_EXEC_TIME}/" "$PHP_INI"
sed -i "s|^;date.timezone =.*|date.timezone = ${INI_TIMEZONE}|"            "$PHP_INI"

# Production security hardening
sed -i 's/^expose_php = On/expose_php = Off/'                 "$PHP_INI"
sed -i 's/^display_errors = On/display_errors = Off/'        "$PHP_INI"
sed -i 's/^display_startup_errors = On/display_startup_errors = Off/' "$PHP_INI"
sed -i 's/^log_errors = Off/log_errors = On/'                "$PHP_INI"
sed -i 's/^;error_log = php_errors.log/error_log = \/var\/log\/php\/fpm-error.log/' "$PHP_INI"

# Session hardening
sed -i 's/^;session.cookie_secure =.*/session.cookie_secure = 1/'     "$PHP_INI"
sed -i 's/^session.cookie_httponly =.*/session.cookie_httponly = 1/'  "$PHP_INI"
sed -i 's/^;session.use_strict_mode =.*/session.use_strict_mode = 1/' "$PHP_INI"
sed -i 's/^session.cookie_samesite =.*/session.cookie_samesite = "Lax"/' "$PHP_INI"

mkdir -p /var/log/php
chown www-data:www-data /var/log/php

# OPcache — revalidate_freq=0 in production (use opcache.validate_timestamps=0 for no-check)
OPCACHE_INI="/etc/php/${PHP_VER}/fpm/conf.d/10-opcache.ini"
cat > "$OPCACHE_INI" <<OPCACHE
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=${INI_OPC_MEM}
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=${INI_OPC_FILES}
opcache.revalidate_freq=${INI_OPC_FREQ}
opcache.validate_timestamps=1
opcache.save_comments=1
opcache.fast_shutdown=1
opcache.jit=tracing
opcache.jit_buffer_size=64M
OPCACHE

systemctl reload "php${PHP_VER}-fpm"
success "PHP INI tuned."

# ─── Nginx site config ─────────────────────────────────────────────────────────
echo ""
read_input -rp "  Laravel directory name [laravel]: " APP_DIR
APP_DIR="${APP_DIR:-laravel}"
echo ""

NGINX_CONF="/etc/nginx/sites-available/${APP_DIR}"
WEBROOT="/var/www/${APP_DIR}/public"

info "Writing Nginx site config..."
cat > "$NGINX_CONF" <<NGINX
server {
    listen 80;
    listen [::]:80;

    server_name _;
    root ${WEBROOT};
    index index.php;

    charset utf-8;

    # Laravel front controller
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # Static asset caching
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2?|ttf|svg|webp)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        access_log off;
    }

    # PHP-FPM
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;

        fastcgi_connect_timeout  60s;
        fastcgi_send_timeout     60s;
        fastcgi_read_timeout     60s;
        fastcgi_buffers          8 16k;
        fastcgi_buffer_size      32k;
    }

    # FPM status (restrict to localhost)
    location = /fpm-status {
        allow 127.0.0.1;
        deny all;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    # Block hidden files (.env, .git, etc.)
    location ~ /\.(?!well-known) {
        deny all;
    }

    # Security headers
    add_header X-Frame-Options           "SAMEORIGIN"                   always;
    add_header X-Content-Type-Options    "nosniff"                      always;
    add_header X-XSS-Protection          "1; mode=block"                always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy        "geolocation=(), microphone=()" always;

    # Logging
    access_log /var/log/nginx/${APP_DIR}-access.log combined buffer=512k flush=1m;
    error_log  /var/log/nginx/${APP_DIR}-error.log warn;
}
NGINX

ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/${APP_DIR}"
[[ -L /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl reload nginx
success "Nginx site config written and reloaded."

# ─── Composer ──────────────────────────────────────────────────────────────────
read_input -rp "  Install Composer? [Y/n]: " INSTALL_COMPOSER
INSTALL_COMPOSER="${INSTALL_COMPOSER:-Y}"
echo ""

if [[ "${INSTALL_COMPOSER,,}" =~ ^y ]]; then
    if command -v composer &>/dev/null; then
        success "Composer already installed: $(composer --version --no-ansi)"
    else
        info "Installing Composer..."
        EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
        php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
        ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

        if [[ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]]; then
            rm -f composer-setup.php
            error "Composer installer checksum mismatch. Aborting."
        fi

        php composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
        rm -f composer-setup.php
        success "Composer installed: $(composer --version --no-ansi)"
    fi
else
    warn "Skipping Composer installation."
fi

# ─── Webroot ───────────────────────────────────────────────────────────────────
info "Webroot ${WEBROOT} not created — deploy your Laravel app there manually."

# ─── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │                   Installation complete                      │"
echo "  ├─────────────────────────────────────────────────────────────┤"
printf "  │  %-59s │\n" "Nginx:          $(nginx -v 2>&1)"
printf "  │  %-59s │\n" "PHP:            $(php${PHP_VER} --version | head -1)"
printf "  │  %-59s │\n" "PHP-FPM sock:   /run/php/php${PHP_VER}-fpm.sock"
printf "  │  %-59s │\n" "FPM pool:       pm=${FPM_PM}, max_children=${FPM_MAX_CHILDREN}"
printf "  │  %-59s │\n" "Database:       ${DB_NAME} (${DB_EXT})"
printf "  │  %-59s │\n" "Webroot:        ${WEBROOT}"
printf "  │  %-59s │\n" "Nginx config:   ${NGINX_CONF}"
printf "  │  %-59s │\n" "PHP error log:  /var/log/php/fpm-error.log"
echo "  ├─────────────────────────────────────────────────────────────┤"
echo "  │  Next steps:                                                │"
printf "  │   1. Deploy Laravel app to %-31s │\n" "/var/www/${APP_DIR}"
printf "  │   2. chown -R www-data:www-data %-27s │\n" "/var/www/${APP_DIR}"
printf "  │   3. chmod -R 775 %-39s │\n" "/var/www/${APP_DIR}/storage"
echo "  │   4. Update server_name in ${NGINX_CONF}"
echo "  │   5. Add SSL: certbot --nginx -d yourdomain.com             │"
echo "  │   6. FPM status: curl http://127.0.0.1/fpm-status           │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
