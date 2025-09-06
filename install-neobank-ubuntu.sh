#!/usr/bin/env bash
set -euo pipefail

# ============================================
# NeoBank Lite (CTF) - Ubuntu Auto Installer
# Installs: PHP + PHP-FPM + SQLite + Composer + wkhtmltopdf + Nginx
# Deploys the app ZIP into /var/www/<app_name> and configures Nginx
#
# Usage (examples):
#   sudo bash install-neobank-ubuntu.sh --host 203.0.113.10 --zip /root/neobank-lite-sqlite-smtp.zip
#   sudo bash install-neobank-ubuntu.sh --host bank.example.com --smtp-user you@example.com --smtp-pass 'app_password' --zip /root/neobank.zip
#
# Flags (all optional except --host and --zip):
#   --host <domain_or_ip>        # Required: domain or public IP for app_url and Nginx server_name
#   --zip  <path_to_zip>         # Required: path to your neobank ZIP (contains neobank_portal_sqlite/)
#   --app-name <name>            # Default: neobank
#   --smtp-host <host>           # Default: 213.136.85.48
#   --smtp-port <port>           # Default: 587
#   --smtp-secure <tls|ssl>      # Default: tls
#   --smtp-user <user>           # Default: soor@lab.spacetechno.om
#   --smtp-pass <pass>           # Default: eFINseWAglUcIndIftSurgenTLetTswE70
#   --smtp-from <addr>           # Default: same as smtp-user
#   --smtp-from-name <name>      # Default: NeoBank Lite
#   --reset-salt <salt>          # Default: minty
# ============================================

# Defaults
APP_NAME="neobank"
HOST=""
ZIP_PATH=""
SMTP_HOST="213.136.85.48"
SMTP_PORT="587"
SMTP_SECURE="tls"
SMTP_USER="soor@lab.spacetechno.om"
SMTP_PASS="eFINseWAglUcIndIftSurgenTLetTswE70"
SMTP_FROM=""
SMTP_FROM_NAME="NeoBank Lite"
RESET_SALT="minty"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --zip) ZIP_PATH="$2"; shift 2;;
    --app-name) APP_NAME="$2"; shift 2;;
    --smtp-host) SMTP_HOST="$2"; shift 2;;
    --smtp-port) SMTP_PORT="$2"; shift 2;;
    --smtp-secure) SMTP_SECURE="$2"; shift 2;;
    --smtp-user) SMTP_USER="$2"; shift 2;;
    --smtp-pass) SMTP_PASS="$2"; shift 2;;
    --smtp-from) SMTP_FROM="$2"; shift 2;;
    --smtp-from-name) SMTP_FROM_NAME="$2"; shift 2;;
    --reset-salt) RESET_SALT="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

if [[ -z "$HOST" || -z "$ZIP_PATH" ]]; then
  echo "ERROR: --host and --zip are required."
  exit 1
fi
if [[ -z "$SMTP_FROM" ]]; then
  SMTP_FROM="$SMTP_USER"
fi

APP_ROOT="/var/www/${APP_NAME}"
APP_URL="http://${HOST}"

echo "==> Installing system packages (PHP, PHP-FPM, SQLite, Composer, wkhtmltopdf, Nginx)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y software-properties-common ca-certificates curl unzip nginx sqlite3   php php-cli php-fpm php-sqlite3 php-mbstring php-xml php-curl php-zip   wkhtmltopdf composer

PHPV="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHPFPM_SOCK="/run/php/php${PHPV}-fpm.sock"
systemctl enable --now "php${PHPV}-fpm"

echo "==> Preparing web root at ${APP_ROOT} ..."
mkdir -p "${APP_ROOT}"
rm -rf "${APP_ROOT:?}/"* || true
unzip -o "${ZIP_PATH}" -d "${APP_ROOT}"

# Detect web directory inside the ZIP (usually neobank_portal_sqlite/)
if [[ -d "${APP_ROOT}/neobank_portal_sqlite" ]]; then
  WEB_ROOT="${APP_ROOT}/neobank_portal_sqlite"
else
  # fallback: assume ZIP extracted directly
  WEB_ROOT="${APP_ROOT}"
fi

# Ensure writable directories exist
mkdir -p "${WEB_ROOT}/data" "${WEB_ROOT}/mailbox" "${WEB_ROOT}/config"

echo "==> Writing config/env.php ..."
cat > "${WEB_ROOT}/config/env.php" <<EOF
<?php
return [
  'smtp_host' => '${SMTP_HOST}',
  'smtp_port' => ${SMTP_PORT},
  'smtp_secure' => '${SMTP_SECURE}',
  'smtp_user'  => '${SMTP_USER}',
  'smtp_pass'  => '${SMTP_PASS}',
  'smtp_from'  => '${SMTP_FROM}',
  'smtp_from_name' => '${SMTP_FROM_NAME}',
  'app_url' => '${APP_URL}',
  'reset_salt' => '${RESET_SALT}'
];
EOF

# Some apps also have config/config.php — ensure it exists for wkhtmltopdf path if needed
if [[ ! -f "${WEB_ROOT}/config/config.php" ]]; then
  cat > "${WEB_ROOT}/config/config.php" <<'EOF'
<?php
define('WKHTMLTOPDF_PATH', 'wkhtmltopdf'); // available in PATH
?>
EOF
fi

echo "==> Composer install (PHPMailer, autoload)..."
pushd "${WEB_ROOT}" >/dev/null
if [[ ! -f "composer.json" ]]; then
  cat > composer.json <<'EOF'
{
  "name": "ctf/neobank-lite-sqlite-smtp",
  "description": "CTF banking portal with SQLite + SMTP (PHPMailer)",
  "type": "project",
  "require": {
    "php": ">=8.0",
    "phpmailer/phpmailer": "^6.9"
  },
  "config": {
    "optimize-autoloader": true,
    "sort-packages": true
  }
}
EOF
fi
composer install --no-dev --optimize-autoloader
popd >/dev/null

echo "==> Setting permissions for www-data ..."
chown -R www-data:www-data "${APP_ROOT}"
find "${WEB_ROOT}" -type d -exec chmod 755 {} \;
chmod 775 "${WEB_ROOT}/data" "${WEB_ROOT}/mailbox"

echo "==> Writing Nginx server block ..."
NGINX_CONF="/etc/nginx/sites-available/${APP_NAME}"
cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
    server_name ${HOST};

    root ${WEB_ROOT};
    index index.php;

    access_log /var/log/nginx/${APP_NAME}.access.log;
    error_log  /var/log/nginx/${APP_NAME}.error.log;

    location / {
        try_files \$uri /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHPFPM_SOCK};
    }

    location ~* \.(?:css|js|png|jpg|jpeg|gif|svg|ico)$ {
        try_files \$uri =404;
        expires 7d;
        access_log off;
    }
}
EOF

ln -sf "${NGINX_CONF}" "/etc/nginx/sites-enabled/${APP_NAME}"
# Disable default site if enabled
if [[ -f /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
fi

echo "==> Testing Nginx config ..."
nginx -t
systemctl reload nginx || systemctl restart nginx

# Optional: open firewall for HTTP if ufw is present
if command -v ufw >/dev/null 2>&1; then
  ufw allow 'Nginx Full' || true
fi

echo "==> Verifying wkhtmltopdf ..."
wkhtmltopdf -V || { echo "WARNING: wkhtmltopdf not working as expected."; }

cat <<NOTE

========================================================
✅ Install complete!

• Web root:        ${WEB_ROOT}
• App URL:         http://${HOST}
• Nginx site:      ${NGINX_CONF}
• PHP-FPM socket:  ${PHPFPM_SOCK}

Next steps:
1) Browse:  http://${HOST}/
2) Register a user (real email). If mail lands in spam, mark "Not Spam".
3) If emails don't arrive, check:
   - SMTP settings in ${WEB_ROOT}/config/env.php
   - Mailcow logs / firewall
   - ${WEB_ROOT}/mailbox/ fallback (if Composer/PHPMailer missing)

Security note: Rotate the SMTP app password when you're done testing.
========================================================
NOTE
