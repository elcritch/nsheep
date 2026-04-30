#!/bin/sh
set -e

# NSheep VPS Setup Script for Alpine Linux 3.23
# Run as root
# Usage: ./setup-vps-alpine.sh 103.199.16.163 [domain]

IP="${1:-103.199.16.163}"
DOMAIN="${2:-}"
NSHEEP_DIR="/opt/nsheep"
NSHEEP_USER="nsheep"

echo "=== Setting up nsheep on Alpine Linux ($IP) ==="

# --- System ---
echo "[1/9] Updating system..."
apk update
apk upgrade

# --- DNS (China optimized) ---
echo "[2/9] Configuring DNS resolvers..."
cat > /etc/resolv.conf << 'EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 114.114.114.114
EOF

# --- Packages ---
echo "[3/9] Installing packages..."
apk add --no-cache \
  build-base curl git wget \
  nginx certbot certbot-nginx \
  sqlite sqlite-dev \
  curl-dev openssl-dev \
  libffi-dev py3-pip \
  docker docker-compose \
  openrc

# Ensure openrc is set up for containers/VPS (if not already)
if [ ! -d /run/openrc ]; then
  mkdir -p /run/openrc
  touch /run/openrc/softlevel
fi

# --- User ---
echo "[4/9] Creating nsheep user..."
adduser -D -h "$NSHEEP_DIR" -s /bin/sh "$NSHEEP_USER" 2>/dev/null || true

# --- Nim ---
echo "[5/9] Installing Nim..."
if ! command -v nim >/dev/null 2>&1; then
  # Use Alpine packages (much faster than choosenim on Alpine)
  apk add --no-cache nim nimble
fi

nim --version

# --- Clone & Build ---
echo "[6/9] Building nsheep..."
rm -rf "$NSHEEP_DIR"

# If you have the repo locally, scp it instead:
# scp -r /local/nsheep root@$IP:/opt/
# Clone from GitHub
# git clone https://github.com/nim-community/nsheep.git "$NSHEEP_DIR" 2>/dev/null || {
#   echo "Git clone failed. Please scp your local nsheep repo to $NSHEEP_DIR"
#   exit 1
# }

cd "$NSHEEP_DIR"

# Regenerate nimble.paths for Alpine environment
rm -f nimble.paths
nimble setup -y 2>/dev/null || true
nimble install -d -y

# Build frontend and binaries
make frontend
nimble build

chown -R "$NSHEEP_USER:$NSHEEP_USER" "$NSHEEP_DIR"

# --- Config ---
echo "[7/9] Creating nsheep config..."
mkdir -p "$NSHEEP_DIR/data/tarballs"

cat > "$NSHEEP_DIR/cfg.yaml" << EOF
server:
  bindAddr: "127.0.0.1"
  port: 8080
  publicDir: "./public"
  baseUrl: "http://${DOMAIN:-$IP}"

github:
  token: ""

local:
  dbPath: "./data/nsheep.db"
  tarballDir: "./data/tarballs"

fetcher:
  interval: 3600
  maxPackages: 0
  filterPatterns: []

validator:
  enabled: true
  dockerImage: "nimlang/nim:latest"
  timeout: 300
  required: false

storage: local
EOF

chown -R "$NSHEEP_USER:$NSHEEP_USER" "$NSHEEP_DIR/data"

# --- OpenRC Service ---
echo "[8/9] Creating OpenRC service..."
cat > /etc/init.d/nsheep << 'EOF'
#!/sbin/openrc-run

description="NSheep Package Registry Server"
command="/opt/nsheep/nsheep"
command_args="/opt/nsheep/cfg.yaml"
command_user="nsheep:nsheep"
command_background="yes"
pidfile="/run/nsheep.pid"
directory="/opt/nsheep"

output_log="/var/log/nsheep.log"
error_log="/var/log/nsheep.err"

depend() {
  need net
  after nginx
}

start_pre() {
  checkpath -f -m 0644 -o "$command_user" "$output_log" "$error_log"
}
EOF

chmod +x /etc/init.d/nsheep

# Create log files
touch /var/log/nsheep.log /var/log/nsheep.err
chown "$NSHEEP_USER:$NSHEEP_USER" /var/log/nsheep.log /var/log/nsheep.err

rc-update add nsheep default
rc-service nsheep start || {
  echo "Warning: nsheep failed to start. Check logs: cat /var/log/nsheep.err"
}

# --- Nginx ---
echo "[9/9] Configuring nginx..."

mkdir -p /etc/nginx/http.d
rm -f /etc/nginx/http.d/default.conf

# Use production nginx config from repo
if [ -f "$NSHEEP_DIR/scripts/nginx.conf" ]; then
  cp "$NSHEEP_DIR/scripts/nginx.conf" /etc/nginx/http.d/nsheep.conf
  # Update domain and SSL paths if a custom domain is provided
  if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "nimpack.org" ]; then
    sed -i "s/nimpack.org/$DOMAIN/g" /etc/nginx/http.d/nsheep.conf
    sed -i "s|/etc/letsencrypt/live/nimpack.org|/etc/letsencrypt/live/$DOMAIN|g" /etc/nginx/http.d/nsheep.conf
  fi
else
  echo "Warning: scripts/nginx.conf not found. Falling back to basic proxy config."
  cat > /etc/nginx/http.d/nsheep.conf << EOF
server {
    listen 80;
    server_name ${DOMAIN:-$IP};

    client_max_body_size 100M;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
fi

nginx -t
rc-service nginx restart
rc-update add nginx default

# --- SSL (if domain provided) ---
if [ -n "$DOMAIN" ]; then
  echo "[10/10] Obtaining SSL certificate..."
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" || {
    echo "Certbot failed. You may need to run manually: certbot --nginx -d $DOMAIN"
  }
fi

echo ""
echo "=== Setup complete ==="
echo "NSheep API:    http://${DOMAIN:-$IP}/api/v1/packages"
echo "Packages.json: http://${DOMAIN:-$IP}/packages.json"
echo "Health:        http://${DOMAIN:-$IP}/health"
echo ""
echo "Manage service:  rc-service nsheep {start|stop|restart}"
echo "View logs:       tail -f /var/log/nsheep.log /var/log/nsheep.err"
echo ""
echo "To run the fetcher (ingest packages):"
echo "  cd $NSHEEP_DIR && su -s /bin/sh nsheep -c './nsheep-fetcher cfg.yaml'"
