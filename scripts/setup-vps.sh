#!/bin/bash
set -euo pipefail

# NSheep VPS Setup Script
# Run as root on a fresh Ubuntu 22.04/24.04 host
# Usage: ./setup-vps.sh 103.199.16.163

IP="${1:-103.199.16.163}"
DOMAIN="${2:-}"  # Optional: set your domain for SSL
NSHEEP_DIR="/opt/nsheep"
NSHEEP_USER="nsheep"

echo "=== Setting up nsheep on $IP ==="

# --- System ---
echo "[1/9] Updating system..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y \
  curl wget git build-essential \
  nginx certbot python3-certbot-nginx \
  sqlite3 libsqlite3-dev \
  libcurl4-openssl-dev \
  docker.io

# --- DNS (China optimized) ---
echo "[2/9] Configuring DNS resolvers..."
cat > /etc/resolv.conf << 'EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 114.114.114.114
EOF

# --- User ---
echo "[3/9] Creating nsheep user..."
id -u "$NSHEEP_USER" &>/dev/null || useradd -r -s /bin/false -d "$NSHEEP_DIR" "$NSHEEP_USER"

# --- Nim ---
echo "[4/9] Installing Nim..."
if ! command -v nim &>/dev/null; then
  curl https://nim-lang.org/choosenim/init.sh -sSf | sh -s -- -y
  export PATH="$HOME/.nimble/bin:$PATH"
  echo 'export PATH="$HOME/.nimble/bin:$PATH"' >> ~/.bashrc
fi
export PATH="$HOME/.nimble/bin:$PATH"
nim --version

# --- Clone & Build ---
echo "[5/9] Building nsheep..."
rm -rf "$NSHEEP_DIR"
git clone https://github.com/nim-works/nsheep.git "$NSHEEP_DIR" 2>/dev/null || true
# If private repo or local, use SCP instead:
# mkdir -p "$NSHEEP_DIR" && cp -r /local/nsheep/* "$NSHEEP_DIR/"

cd "$NSHEEP_DIR"
nimble setup -y 2>/dev/null || true
nimble install -d -y
make frontend
nimble build

chown -R "$NSHEEP_USER:$NSHEEP_USER" "$NSHEEP_DIR"

# --- Config ---
echo "[6/9] Creating nsheep config..."
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

cloudflare:
  accountId: ""
  r2AccessKeyId: ""
  r2SecretKey: ""
  r2Bucket: "nsheep-packages"
  kvNamespaceId: ""
  apiToken: ""

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

# --- Systemd Service ---
echo "[7/9] Creating systemd service..."
cat > /etc/systemd/system/nsheep.service << 'EOF'
[Unit]
Description=NSheep Package Registry Server
After=network.target

[Service]
Type=simple
User=nsheep
Group=nsheep
WorkingDirectory=/opt/nsheep
ExecStart=/opt/nsheep/nsheep /opt/nsheep/cfg.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/nsheep-fetcher.service << 'EOF'
[Unit]
Description=NSheep Package Fetcher
After=network.target

[Service]
Type=simple
User=nsheep
Group=nsheep
WorkingDirectory=/opt/nsheep
ExecStart=/opt/nsheep/nsheep-fetcher /opt/nsheep/cfg.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nsheep
systemctl start nsheep
systemctl enable nsheep-fetcher
systemctl start nsheep-fetcher

# --- Nginx ---
echo "[8/9] Configuring nginx..."

if [ -n "$DOMAIN" ]; then
  # Domain mode with SSL
  cat > /etc/nginx/sites-available/nsheep << EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

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
else
  # IP-only mode (no SSL)
  cat > /etc/nginx/sites-available/nsheep << EOF
server {
    listen 80;
    server_name $IP;

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

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/nsheep /etc/nginx/sites-enabled/nsheep

nginx -t
systemctl restart nginx
systemctl enable nginx

# --- SSL (if domain provided) ---
if [ -n "$DOMAIN" ]; then
  echo "[9/9] Obtaining SSL certificate..."
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" || true
fi

echo ""
echo "=== Setup complete ==="
echo "NSheep API:    http://${DOMAIN:-$IP}/api/v1/packages"
echo "Packages.json: http://${DOMAIN:-$IP}/packages.json"
echo "Health:        http://${DOMAIN:-$IP}/health"
echo ""
echo "Services:"
echo "  Server:  systemctl status nsheep"
echo "  Fetcher: systemctl status nsheep-fetcher"
echo ""
echo "Logs:"
echo "  journalctl -u nsheep -f"
echo "  journalctl -u nsheep-fetcher -f"
