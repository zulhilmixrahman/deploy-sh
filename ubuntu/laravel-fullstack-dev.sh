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

# ─── System info ───────────────────────────────────────────────────────────────
TOTAL_RAM_MB=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)
CPU_CORES=$(nproc 2>/dev/null || echo 1)

# PHP-FPM defaults — dev uses 50% RAM, ~50MB per process
DEFAULT_FPM_MAX=$(( TOTAL_RAM_MB * 50 / 100 / 50 ))
(( DEFAULT_FPM_MAX < 2 )) && DEFAULT_FPM_MAX=2
DEFAULT_FPM_START=2
DEFAULT_FPM_MIN_SPARE=1
DEFAULT_FPM_MAX_SPARE=$(( DEFAULT_FPM_MAX / 2 > 2 ? DEFAULT_FPM_MAX / 2 : 2 ))

# MySQL buffer pool default — dev uses 30% RAM
DEFAULT_BUFFER_POOL=$(( TOTAL_RAM_MB * 30 / 100 ))
(( DEFAULT_BUFFER_POOL < 64 )) && DEFAULT_BUFFER_POOL=64
DEFAULT_BUFFER_POOL="${DEFAULT_BUFFER_POOL}M"

echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │  Laravel Fullstack Installer — Staging / Development        │"
echo "  │  Nginx + PHP-FPM + MySQL  (Ubuntu)                         │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo "  RAM: ${TOTAL_RAM_MB}MB  |  CPUs: ${CPU_CORES}"
echo ""

# ─── PHP version selection ─────────────────────────────────────────────────────
SUPPORTED_PHP_VERSIONS=("7.4" "8.0" "8.1" "8.2" "8.3" "8.4")

if [[ -n "${PHP_VERSION:-}" ]]; then
    PHP_VER="$PHP_VERSION"
else
    echo "  Available PHP-FPM versions:"
    for i in "${!SUPPORTED_PHP_VERSIONS[@]}"; do
        if [[ "${SUPPORTED_PHP_VERSIONS[$i]}" == "8.3" ]]; then
            echo "    $((i+1))) PHP ${SUPPORTED_PHP_VERSIONS[$i]}  (recommended)"
        else
            echo "    $((i+1))) PHP ${SUPPORTED_PHP_VERSIONS[$i]}"
        fi
    done
    echo ""
    read_input -rp "  Select PHP version [default: 8.3]: " php_choice
    php_choice="${php_choice:-5}"

    if [[ "$php_choice" =~ ^[0-9]+$ ]] && (( php_choice >= 1 && php_choice <= ${#SUPPORTED_PHP_VERSIONS[@]} )); then
        PHP_VER="${SUPPORTED_PHP_VERSIONS[$((php_choice-1))]}"
    elif [[ "$php_choice" =~ ^[0-9]+\.[0-9]+$ ]]; then
        PHP_VER="$php_choice"
    else
        PHP_VER="8.3"
    fi
fi

valid_php=false
for v in "${SUPPORTED_PHP_VERSIONS[@]}"; do
    [[ "$v" == "$PHP_VER" ]] && valid_php=true && break
done
$valid_php || error "Unsupported PHP version '$PHP_VER'. Choose from: ${SUPPORTED_PHP_VERSIONS[*]}"

echo ""

# ─── MySQL version selection ───────────────────────────────────────────────────
echo "  Available MySQL versions:"
echo "    1) MySQL 8.0  (LTS)"
echo "    2) MySQL 8.4  (LTS, recommended)"
echo "    3) MySQL 9.1  (Innovation)"
echo ""
read_input -rp "  Select MySQL version [default: 2]: " mysql_choice
echo ""

case "${mysql_choice:-2}" in
    1) MYSQL_VER="8.0"; APT_SERIES="mysql-8.0" ;;
    2) MYSQL_VER="8.4"; APT_SERIES="mysql-8.4" ;;
    3) MYSQL_VER="9.1"; APT_SERIES="mysql-9.1" ;;
    *) MYSQL_VER="8.4"; APT_SERIES="mysql-8.4" ;;
esac

# ─── Application settings ─────────────────────────────────────────────────────
echo "  Application settings (press Enter to keep default):"
echo ""

read_input -rp "    Laravel directory name   [laravel]:  " APP_DIR
APP_DIR="${APP_DIR:-laravel}"

read_input -rp "    Environment label        [staging]:  " APP_ENV
APP_ENV="${APP_ENV:-staging}"

echo ""
read_input -rp "  Create MySQL database and user now? [Y/n]: " CREATE_DB
CREATE_DB="${CREATE_DB:-Y}"
echo ""

DB_NAME=""
DB_USER=""
DB_PASS=""

if [[ "${CREATE_DB,,}" =~ ^y ]]; then
    read_input -rp "    Database name   [${APP_DIR}]: " DB_NAME
    DB_NAME="${DB_NAME:-$APP_DIR}"

    read_input -rp "    DB username     [${APP_DIR}]: " DB_USER
    DB_USER="${DB_USER:-$APP_DIR}"

    while true; do
        read_input -rsp "    DB password:  " DB_PASS;  echo ""
        read_input -rsp "    Confirm:      " DB_PASS2; echo ""
        [[ "$DB_PASS" == "$DB_PASS2" ]] && break
        warn "Passwords do not match. Try again."
    done
    [[ -z "$DB_PASS" ]] && error "Database password cannot be empty."
    echo ""
fi

# ─── Nginx tuning prompts ─────────────────────────────────────────────────────
echo "  Nginx tuning (press Enter to keep default):"
echo ""

read_input -rp "    client_max_body_size [64M]:  " NGX_CLIENT_MAX
NGX_CLIENT_MAX="${NGX_CLIENT_MAX:-64M}"

read_input -rp "    keepalive_timeout    [65]:   " NGX_KEEPALIVE
NGX_KEEPALIVE="${NGX_KEEPALIVE:-65}"
echo ""

# ─── PHP-FPM tuning prompts ────────────────────────────────────────────────────
echo "  PHP-FPM pool tuning (press Enter to keep default):"
echo "  RAM: ${TOTAL_RAM_MB}MB  — dev: 50% RAM, ~50MB per PHP process"
echo ""

read_input -rp "    pm                   [dynamic]:  " FPM_PM
FPM_PM="${FPM_PM:-dynamic}"

read_input -rp "    pm.max_children      [${DEFAULT_FPM_MAX}]:       " FPM_MAX_CHILDREN
FPM_MAX_CHILDREN="${FPM_MAX_CHILDREN:-$DEFAULT_FPM_MAX}"

read_input -rp "    pm.start_servers     [${DEFAULT_FPM_START}]:        " FPM_START
FPM_START="${FPM_START:-$DEFAULT_FPM_START}"

read_input -rp "    pm.min_spare_servers [${DEFAULT_FPM_MIN_SPARE}]:        " FPM_MIN_SPARE
FPM_MIN_SPARE="${FPM_MIN_SPARE:-$DEFAULT_FPM_MIN_SPARE}"

read_input -rp "    pm.max_spare_servers [${DEFAULT_FPM_MAX_SPARE}]:        " FPM_MAX_SPARE
FPM_MAX_SPARE="${FPM_MAX_SPARE:-$DEFAULT_FPM_MAX_SPARE}"

read_input -rp "    pm.max_requests      [200]:      " FPM_MAX_REQUESTS
FPM_MAX_REQUESTS="${FPM_MAX_REQUESTS:-200}"
echo ""

# ─── PHP INI tuning prompts ────────────────────────────────────────────────────
echo "  PHP INI tuning (press Enter to keep default):"
echo ""

read_input -rp "    upload_max_filesize  [64M]:   " INI_UPLOAD;    INI_UPLOAD="${INI_UPLOAD:-64M}"
read_input -rp "    post_max_size        [64M]:   " INI_POST;      INI_POST="${INI_POST:-64M}"
read_input -rp "    memory_limit         [512M]:  " INI_MEMORY;    INI_MEMORY="${INI_MEMORY:-512M}"
read_input -rp "    max_execution_time   [120]:   " INI_EXEC_TIME; INI_EXEC_TIME="${INI_EXEC_TIME:-120}"
read_input -rp "    date.timezone        [UTC]:   " INI_TIMEZONE;  INI_TIMEZONE="${INI_TIMEZONE:-UTC}"
echo ""

# ─── MySQL tuning prompts ─────────────────────────────────────────────────────
echo "  MySQL tuning (press Enter to keep default):"
echo "  RAM: ${TOTAL_RAM_MB}MB  — dev: 30% RAM for buffer pool"
echo ""

read_input -rp "    innodb_buffer_pool_size  [${DEFAULT_BUFFER_POOL}]: " T_BUFFER_POOL
T_BUFFER_POOL="${T_BUFFER_POOL:-$DEFAULT_BUFFER_POOL}"

read_input -rp "    max_connections          [50]:   " T_MAX_CONN
T_MAX_CONN="${T_MAX_CONN:-50}"

read_input -rp "    max_allowed_packet       [64M]:  " T_MAX_PACKET
T_MAX_PACKET="${T_MAX_PACKET:-64M}"

read_input -rp "    slow_query_log           [ON]:   " T_SLOW_LOG
T_SLOW_LOG="${T_SLOW_LOG:-ON}"

read_input -rp "    long_query_time (sec)    [1]:    " T_LONG_QUERY
T_LONG_QUERY="${T_LONG_QUERY:-1}"

read_input -rp "    Enable general_log?      [y/N]:  " T_GENERAL_LOG
[[ "${T_GENERAL_LOG,,}" =~ ^y ]] && GENERAL_LOG_VAL="ON" || GENERAL_LOG_VAL="OFF"
echo ""

# ─── Confirm ───────────────────────────────────────────────────────────────────
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │  Ready to install:                                          │"
printf "  │    PHP-FPM:   %-45s │\n" "${PHP_VER}"
printf "  │    MySQL:     %-45s │\n" "${MYSQL_VER}"
printf "  │    Webroot:   /var/www/%-37s │\n" "${APP_DIR}/public"
printf "  │    Env label: %-45s │\n" "${APP_ENV}"
[[ -n "$DB_NAME" ]] && \
printf "  │    Database:  %-45s │\n" "${DB_NAME}  (user: ${DB_USER})"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
read_input -rp "  Proceed with installation? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
[[ "${CONFIRM,,}" =~ ^y ]] || { warn "Aborted."; exit 0; }
echo ""

# ════════════════════════════════════════════════════════════════════════════════
#  INSTALLATION
# ════════════════════════════════════════════════════════════════════════════════

# ─── Prerequisites ─────────────────────────────────────────────────────────────
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
    debconf-utils \
    unzip \
    git \
    openssl

# ─── Ondřej Surý PPAs (Nginx + PHP) ──────────────────────────────────────────
info "Adding official Nginx stable repository..."
curl -fsSL https://nginx.org/keys/nginx_signing.key \
    | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
https://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
    > /etc/apt/sources.list.d/nginx.list
info "Adding Ondřej Surý PHP PPA..."
add-apt-repository -y ppa:ondrej/php
apt-get update -qq
success "Nginx (nginx.org) and Ondřej Surý PHP repositories ready."

# ─── MySQL APT repository ──────────────────────────────────────────────────────
if ! dpkg -l 2>/dev/null | grep -q "mysql-apt-config"; then
    info "Adding MySQL Community APT repository (MySQL ${MYSQL_VER})..."
    TMPDIR_MYSQL=$(mktemp -d)
    curl -fsSL "https://dev.mysql.com/get/mysql-apt-config_0.8.33-1_all.deb" \
        -o "${TMPDIR_MYSQL}/mysql-apt-config.deb"

    echo "mysql-apt-config mysql-apt-config/select-server select ${APT_SERIES}" \
        | debconf-set-selections
    echo "mysql-apt-config mysql-apt-config/select-product select Ok" \
        | debconf-set-selections

    DEBIAN_FRONTEND=noninteractive dpkg -i "${TMPDIR_MYSQL}/mysql-apt-config.deb"
    rm -rf "$TMPDIR_MYSQL"
    apt-get update -qq
    success "MySQL APT repository configured for MySQL ${MYSQL_VER}."
else
    info "MySQL APT repository already present."
fi

# ════════════════════════════════════════════════════════════════════════════════
#  NGINX
# ════════════════════════════════════════════════════════════════════════════════

info "Installing Nginx..."
apt-get install -y -qq nginx
systemctl enable nginx
systemctl start nginx
success "Nginx installed and running."

info "Writing Nginx global config..."
cat > "/etc/nginx/conf.d/global.conf" <<NGX
server_tokens off;

keepalive_timeout         ${NGX_KEEPALIVE};
keepalive_requests        100;
client_body_timeout       60;
client_header_timeout     60;
send_timeout              60;

client_body_buffer_size   128k;
client_header_buffer_size 1k;
client_max_body_size      ${NGX_CLIENT_MAX};
large_client_header_buffers 4 16k;

sendfile    on;
tcp_nopush  on;
tcp_nodelay on;

gzip              on;
gzip_vary         on;
gzip_proxied      any;
gzip_comp_level   3;
gzip_min_length   256;
gzip_types
    text/plain text/css text/xml text/javascript
    application/json application/javascript application/xml
    application/rss+xml font/truetype font/opentype image/svg+xml;
NGX

nginx -t && systemctl reload nginx
success "Nginx global config applied."

# ════════════════════════════════════════════════════════════════════════════════
#  PHP-FPM
# ════════════════════════════════════════════════════════════════════════════════

PHP_EXTENSIONS=(
    "php${PHP_VER}-fpm"
    "php${PHP_VER}-cli"
    "php${PHP_VER}-common"
    "php${PHP_VER}-mysql"
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
    "php${PHP_VER}-xdebug"
)

info "Installing PHP ${PHP_VER} and extensions..."
apt-get install -y -qq "${PHP_EXTENSIONS[@]}"
systemctl enable "php${PHP_VER}-fpm"
systemctl start  "php${PHP_VER}-fpm"
success "PHP ${PHP_VER}-FPM installed and running."

# ─── PHP-FPM pool tuning ──────────────────────────────────────────────────────
FPM_POOL_CONF="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
info "Tuning PHP-FPM pool at ${FPM_POOL_CONF}..."

sed -i "s/^pm = .*/pm = ${FPM_PM}/"                                             "$FPM_POOL_CONF"
sed -i "s/^pm.max_children = .*/pm.max_children = ${FPM_MAX_CHILDREN}/"         "$FPM_POOL_CONF"
sed -i "s/^pm.start_servers = .*/pm.start_servers = ${FPM_START}/"              "$FPM_POOL_CONF"
sed -i "s/^pm.min_spare_servers = .*/pm.min_spare_servers = ${FPM_MIN_SPARE}/"  "$FPM_POOL_CONF"
sed -i "s/^pm.max_spare_servers = .*/pm.max_spare_servers = ${FPM_MAX_SPARE}/"  "$FPM_POOL_CONF"
sed -i "s/^;pm.max_requests = .*/pm.max_requests = ${FPM_MAX_REQUESTS}/"        "$FPM_POOL_CONF"
grep -q "^pm.max_requests" "$FPM_POOL_CONF" \
    || echo "pm.max_requests = ${FPM_MAX_REQUESTS}" >> "$FPM_POOL_CONF"
sed -i 's|^;pm.status_path = .*|pm.status_path = /fpm-status|' "$FPM_POOL_CONF"

success "PHP-FPM pool tuned."

# ─── PHP INI tuning ───────────────────────────────────────────────────────────
PHP_INI="/etc/php/${PHP_VER}/fpm/php.ini"
info "Tuning PHP INI at ${PHP_INI}..."

sed -i "s/^upload_max_filesize = .*/upload_max_filesize = ${INI_UPLOAD}/"  "$PHP_INI"
sed -i "s/^post_max_size = .*/post_max_size = ${INI_POST}/"                "$PHP_INI"
sed -i "s/^memory_limit = .*/memory_limit = ${INI_MEMORY}/"                "$PHP_INI"
sed -i "s/^max_execution_time = .*/max_execution_time = ${INI_EXEC_TIME}/" "$PHP_INI"
sed -i "s|^;date.timezone =.*|date.timezone = ${INI_TIMEZONE}|"            "$PHP_INI"

# Dev/staging — expose errors for debugging
sed -i 's/^expose_php = On/expose_php = Off/'                             "$PHP_INI"
sed -i 's/^display_errors = Off/display_errors = On/'                     "$PHP_INI"
sed -i 's/^display_startup_errors = Off/display_startup_errors = On/'     "$PHP_INI"
sed -i 's/^log_errors = Off/log_errors = On/'                             "$PHP_INI"
sed -i 's/^;error_log = php_errors.log/error_log = \/var\/log\/php\/fpm-error.log/' "$PHP_INI"

mkdir -p /var/log/php
chown www-data:www-data /var/log/php

# OPcache — revalidate on every request so code changes are picked up immediately
OPCACHE_INI="/etc/php/${PHP_VER}/fpm/conf.d/10-opcache.ini"
cat > "$OPCACHE_INI" <<OPCACHE
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.revalidate_freq=0
opcache.validate_timestamps=1
opcache.save_comments=1
opcache.fast_shutdown=1
OPCACHE

# Xdebug — loaded but passive; switch to xdebug.mode=debug to activate step debugging
XDEBUG_INI="/etc/php/${PHP_VER}/fpm/conf.d/20-xdebug.ini"
cat > "$XDEBUG_INI" <<XDBG
xdebug.mode=develop
xdebug.start_with_request=no
xdebug.client_host=127.0.0.1
xdebug.client_port=9003
xdebug.log=/var/log/php/xdebug.log
XDBG

systemctl reload "php${PHP_VER}-fpm"
success "PHP INI tuned (dev: display_errors=On, OPcache validates every request)."

# ════════════════════════════════════════════════════════════════════════════════
#  MYSQL
# ════════════════════════════════════════════════════════════════════════════════

info "Installing MySQL ${MYSQL_VER} Community Server..."

MYSQL_ROOT_PASS=$(openssl rand -base64 32 | tr -d '/+=')

debconf-set-selections <<< "mysql-community-server mysql-community-server/root-pass password ${MYSQL_ROOT_PASS}"
debconf-set-selections <<< "mysql-community-server mysql-community-server/re-root-pass password ${MYSQL_ROOT_PASS}"
debconf-set-selections <<< "mysql-server mysql-server/root_password password ${MYSQL_ROOT_PASS}"
debconf-set-selections <<< "mysql-server mysql-server/root_password_again password ${MYSQL_ROOT_PASS}"

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mysql-community-server

systemctl enable mysql
systemctl start mysql
success "MySQL ${MYSQL_VER} installed and running."

# ─── Secure MySQL ─────────────────────────────────────────────────────────────
info "Securing MySQL installation..."

mysql -uroot -p"${MYSQL_ROOT_PASS}" <<SQL
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket;
FLUSH PRIVILEGES;
SQL

unset MYSQL_ROOT_PASS
success "MySQL secured. Root login uses OS socket auth (no password)."

# ─── MySQL dev/staging tuning ─────────────────────────────────────────────────
MYCNF_DEV="/etc/mysql/conf.d/dev.cnf"
info "Writing dev/staging config to ${MYCNF_DEV}..."

cat > "$MYCNF_DEV" <<CNF
[mysqld]
# ── Connections ───────────────────────────────────────────────────────────────
max_connections            = ${T_MAX_CONN}
max_allowed_packet         = ${T_MAX_PACKET}
thread_cache_size          = 4

# ── InnoDB ────────────────────────────────────────────────────────────────────
innodb_buffer_pool_size         = ${T_BUFFER_POOL}
innodb_flush_log_at_trx_commit  = 2
innodb_flush_method             = O_DIRECT
innodb_file_per_table           = ON

# ── Logging ───────────────────────────────────────────────────────────────────
slow_query_log                = ${T_SLOW_LOG}
slow_query_log_file           = /var/log/mysql/slow.log
long_query_time               = ${T_LONG_QUERY}
log_queries_not_using_indexes = ON
general_log                   = ${GENERAL_LOG_VAL}
general_log_file              = /var/log/mysql/general.log

# ── Character set ─────────────────────────────────────────────────────────────
character_set_server   = utf8mb4
collation_server       = utf8mb4_unicode_ci

# ── Temp tables ───────────────────────────────────────────────────────────────
tmp_table_size         = 32M
max_heap_table_size    = 32M

# ── Network ───────────────────────────────────────────────────────────────────
bind-address           = 127.0.0.1
CNF

mkdir -p /var/log/mysql
chown mysql:mysql /var/log/mysql

systemctl restart mysql
success "MySQL dev/staging config applied."

# ─── Create app database and user ─────────────────────────────────────────────
if [[ -n "$DB_NAME" ]]; then
    info "Creating database '${DB_NAME}' and user '${DB_USER}'@'localhost'..."
    mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    success "Database '${DB_NAME}' and user '${DB_USER}' created."
fi

# ════════════════════════════════════════════════════════════════════════════════
#  NGINX SITE CONFIG
# ════════════════════════════════════════════════════════════════════════════════

NGINX_CONF="/etc/nginx/sites-available/${APP_DIR}"
WEBROOT="/var/www/${APP_DIR}/public"

info "Writing Nginx site config for '${APP_DIR}'..."
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

    # Short-lived asset cache (dev: 1 day)
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2?|ttf|svg|webp)$ {
        expires 1d;
        access_log off;
    }

    # PHP-FPM — longer timeouts for debugging
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;

        fastcgi_connect_timeout  120s;
        fastcgi_send_timeout     120s;
        fastcgi_read_timeout     120s;
        fastcgi_buffers          8 16k;
        fastcgi_buffer_size      32k;
    }

    # FPM status page (localhost only)
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

    add_header X-Frame-Options        "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff"    always;

    access_log /var/log/nginx/${APP_DIR}-access.log combined;
    error_log  /var/log/nginx/${APP_DIR}-error.log  debug;
}
NGINX

ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/${APP_DIR}"
[[ -L /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default

mkdir -p "$WEBROOT"
chown -R www-data:www-data "/var/www/${APP_DIR}"

nginx -t && systemctl reload nginx
success "Nginx site config written and reloaded."

# ════════════════════════════════════════════════════════════════════════════════
#  COMPOSER
# ════════════════════════════════════════════════════════════════════════════════

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

# ─── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │                   Installation complete                      │"
echo "  ├─────────────────────────────────────────────────────────────┤"
printf "  │  %-59s │\n" "Environment:    ${APP_ENV}"
printf "  │  %-59s │\n" "Nginx:          $(nginx -v 2>&1)"
printf "  │  %-59s │\n" "PHP:            $(php${PHP_VER} --version | head -1)"
printf "  │  %-59s │\n" "PHP-FPM sock:   /run/php/php${PHP_VER}-fpm.sock"
printf "  │  %-59s │\n" "FPM pool:       pm=${FPM_PM}, max_children=${FPM_MAX_CHILDREN}"
printf "  │  %-59s │\n" "MySQL:          $(mysql --version)"
printf "  │  %-59s │\n" "Webroot:        ${WEBROOT}"
printf "  │  %-59s │\n" "Nginx config:   ${NGINX_CONF}"
printf "  │  %-59s │\n" "PHP error log:  /var/log/php/fpm-error.log"
printf "  │  %-59s │\n" "MySQL slow log: /var/log/mysql/slow.log"
[[ "$GENERAL_LOG_VAL" == "ON" ]] && \
printf "  │  %-59s │\n" "MySQL gen log:  /var/log/mysql/general.log"
[[ -n "$DB_NAME" ]] && \
printf "  │  %-59s │\n" "Database:       ${DB_NAME}  (user: ${DB_USER}@localhost)"
echo "  ├─────────────────────────────────────────────────────────────┤"
echo "  │  Next steps:                                                │"
printf "  │   1. Deploy Laravel to %-35s │\n" "/var/www/${APP_DIR}"
printf "  │   2. chown -R www-data:www-data %-27s │\n" "/var/www/${APP_DIR}"
printf "  │   3. chmod -R 775 %-39s │\n" "/var/www/${APP_DIR}/storage"
echo "  │   4. Copy .env.example → .env and configure:               │"
[[ -n "$DB_NAME" ]] && \
echo "  │        DB_DATABASE=${DB_NAME}"
[[ -n "$DB_USER" ]] && \
echo "  │        DB_USERNAME=${DB_USER}"
echo "  │   5. php artisan key:generate                              │"
echo "  │   6. php artisan migrate                                   │"
echo "  │   7. FPM status: curl http://127.0.0.1/fpm-status          │"
echo "  │   8. Xdebug port 9003 — set xdebug.mode=debug to activate │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
