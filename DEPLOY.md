# NimPack Deployment Guide

## Architecture

```
User → Cloudflare CDN → Nginx → nsheep (port 8080)
                ↓
           nsheep-fetcher (background ingestion)
```

- **Cloudflare**: DNS + CDN (caches tarballs at edge)
- **VPS**: Runs nsheep + nsheep-fetcher + nginx reverse proxy
- **Storage**: SQLite database + tarball files on local disk

---

## VPS Setup

### 1. Requirements

- Linux VPS (Alpine, Ubuntu, Debian, etc.)
- 2GB+ RAM, 20GB+ disk
- Domain pointed at VPS IP via Cloudflare

### 2. Create User

```bash
# As root
adduser -D -s /bin/sh nsheep
mkdir -p /opt/nsheep
chown -R nsheep:nsheep /opt/nsheep
```

### 3. Deploy Binaries

```bash
# On the VPS as nsheep user
mkdir -p /opt/nsheep && cd /opt/nsheep

# Download from GitHub Releases (or copy via SCP)
wget https://github.com/nim-community/nsheep/releases/latest/download/nsheep-linux-amd64.tar.gz
tar -xzf nsheep-linux-amd64.tar.gz
chmod +x nsheep nsheep-fetcher

# Create config
cat > cfg.yaml << 'EOF'
server:
  bindAddr: "127.0.0.1"
  port: 8080
  publicDir: "./public"

github:
  token: ""  # Optional: GitHub API token for higher rate limits

local:
  tarballDir: "./data/tarballs"
  metadataDir: "./data/metadata"

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
```

### 4. Configure Nginx

Copy the production nginx config from the repo:

```bash
# Alpine
mkdir -p /etc/nginx/http.d
cp scripts/nginx.conf /etc/nginx/http.d/nsheep.conf

# Edit domain and SSL paths if needed
vi /etc/nginx/http.d/nsheep.conf

nginx -t && rc-service nginx restart

# Or Debian/Ubuntu
mkdir -p /etc/nginx/sites-available
cp scripts/nginx.conf /etc/nginx/sites-available/nsheep
ln -sf /etc/nginx/sites-available/nsheep /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx
```

The config includes:
- **Static assets** (`/app.js`, `/app.css`, `/robot.svg`) served directly by nginx with `immutable` caching.
- **SPA shell** (`/`) cached with `max-age=0, must-revalidate` — browsers revalidate via `Last-Modified`, getting `304 Not Modified` when unchanged.
- **API + dynamic routes** proxied to Mummy on port 8080.
- **SSL** via Let's Encrypt (managed by certbot).
- **HTTP→HTTPS redirect** on port 80.

### 5. Configure OpenRC Services (Alpine)

```bash
# /etc/init.d/nsheep
cat > /etc/init.d/nsheep << 'EOF'
#!/sbin/openrc-run

description="NimPack Package Registry"
command="/opt/nsheep/nsheep"
command_args="/opt/nsheep/cfg.yaml"
command_user="nsheep:nsheep"
pidfile="/run/nsheep.pid"
directory="/opt/nsheep"

supervisor="supervise-daemon"
EOF
chmod +x /etc/init.d/nsheep

# /etc/init.d/nsheep-fetcher
cat > /etc/init.d/nsheep-fetcher << 'EOF'
#!/sbin/openrc-run

description="NimPack Package Fetcher"
command="/opt/nsheep/nsheep-fetcher"
command_args="/opt/nsheep/cfg.yaml"
command_user="nsheep:nsheep"
pidfile="/run/nsheep-fetcher.pid"
directory="/opt/nsheep"

supervisor="supervise-daemon"
EOF
chmod +x /etc/init.d/nsheep-fetcher

# Enable and start
rc-update add nsheep default
rc-update add nsheep-fetcher default
rc-service nsheep start
rc-service nsheep-fetcher start
```

---

## Cloudflare DNS Setup

In Cloudflare Dashboard → DNS:

1. Add **A record**: `nimpack.org` → `YOUR_VPS_IP`
2. Set to **Proxied** (orange cloud 🟠)
3. SSL/TLS mode: **Full (strict)** or **Full**

Tarballs are automatically cached by Cloudflare because the server sends:
```
Cache-Control: public, max-age=31536000, immutable
```

---

## CI/CD Deployment

### GitHub Secrets

In Repository Settings → Secrets and variables → Actions:

| Secret | Value |
|--------|-------|
| `SSH_HOST` | Your VPS IP |
| `SSH_USER` | `nsheep` |
| `SSH_PRIVATE_KEY` | Deploy SSH private key |

Pushing to `main` automatically builds and deploys via `.github/workflows/deploy.yml`.

---

## Verify Deployment

```bash
# Health check
curl https://nimpack.org/health

# View package list
curl https://nimpack.org/api/v1/packages

# Test download (should be CDN cached)
curl -I https://nimpack.org/download/jsony/1.1.5
```

---

## Troubleshooting

### View Logs

```bash
# Alpine OpenRC
rc-service nsheep status
tail -f /var/log/messages | grep nsheep

# Or check chronicles log files in /opt/nsheep/data/
```

### Service Won't Start

```bash
# Run manually to see errors
su -s /bin/sh nsheep -c "/opt/nsheep/nsheep /opt/nsheep/cfg.yaml"
```

### Out of Memory

The VPS has ~939MB RAM. Large tarball downloads were causing OOM kills — this was fixed by using `readFile` instead of loading tarballs into `seq[byte]`. If you still see OOMs, check:

```bash
free -h
dmesg | grep -i "killed process"
```

---

## Maintenance

### Update Packages Manually

```bash
curl -X POST https://nimpack.org/api/v1/ingest
```

### Check Disk Usage

```bash
du -sh /opt/nsheep/data/tarballs
du -sh /opt/nsheep/data/nsheep.db
```

### Backup

```bash
# SQLite DB
cp /opt/nsheep/data/nsheep.db /backup/nsheep-$(date +%Y%m%d).db

# Tarballs (optional, can be re-fetched)
rsync -av /opt/nsheep/data/tarballs/ /backup/tarballs/
```
