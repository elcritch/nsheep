# NSheep Deployment Guide

## Architecture Options

### Option 1: Cloudflare Tunnel (Recommended)
- **Pros**: No public IP required, automatic HTTPS, DDoS protection
- **Best for**: Home NAS, Raspberry Pi, or when you don't want to manage firewalls
- **Architecture**: `User → Cloudflare CDN → Cloudflare Tunnel → Your Server`

### Option 2: Traditional VPS + Cloudflare CDN
- **Pros**: Full control, simple and direct
- **Best for**: Existing VPS (e.g., Hetzner, DigitalOcean)
- **Architecture**: `User → Cloudflare CDN → VPS`

### Option 3: Docker Compose (Local/Server)
- **Best for**: Quick testing or private deployment

---

## Option 1: Cloudflare Tunnel Deployment

### 1. Install cloudflared

```bash
# macOS
brew install cloudflared

# Linux
curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared.deb

# Or use Docker
docker run -d --name cloudflared cloudflare/cloudflared:latest tunnel --no-autoupdate run --token YOUR_TOKEN
```

### 2. Create Tunnel

```bash
# Login to Cloudflare
cloudflared tunnel login

# Create tunnel
cloudflared tunnel create nsheep-server

# This will output a tunnel ID, save it
# Example: 2c5e8c8e-1234-5678-9abc-def012345678
```

### 3. Configure Tunnel

Create `~/.cloudflared/config.yml`:

```yaml
tunnel: 2c5e8c8e-1234-5678-9abc-def012345678
credentials-file: /root/.cloudflared/2c5e8c8e-1234-5678-9abc-def012345678.json

ingress:
  - hostname: nsheep.yourdomain.com
    service: http://localhost:8080
  - service: http_status:404
```

### 4. Run NSheep + Tunnel

Create `docker-compose.yml`:

```yaml
version: '3.8'

services:
  nsheep:
    build: .
    container_name: nsheep
    volumes:
      - ./data:/app/data
      - ./cfg.yaml:/app/cfg.yaml:ro
    network_mode: host  # Use host network for tunnel access
    restart: unless-stopped
    command: /app/nsheep /app/cfg.yaml

  tunnel:
    image: cloudflare/cloudflared:latest
    container_name: nsheep-tunnel
    command: tunnel --no-autoupdate run --token ${CF_TUNNEL_TOKEN}
    environment:
      - CF_TUNNEL_TOKEN=${CF_TUNNEL_TOKEN}
    restart: unless-stopped
```

Or use systemd services:

```ini
# /etc/systemd/system/nsheep.service
[Unit]
Description=NSheep Package Registry
After=network.target

[Service]
Type=simple
User=nsheep
WorkingDirectory=/opt/nsheep
ExecStart=/opt/nsheep/nsheep /opt/nsheep/cfg.yaml
Restart=always

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/nsheep-tunnel.service
[Unit]
Description=Cloudflare Tunnel for NSheep
After=network.target nsheep.service

[Service]
Type=simple
User=nsheep
ExecStart=/usr/local/bin/cloudflared tunnel run 2c5e8c8e-1234-5678-9abc-def012345678
Restart=always

[Install]
WantedBy=multi-user.target
```

Start:
```bash
sudo systemctl enable --now nsheep nsheep-tunnel
```

---

## Option 2: VPS + Cloudflare CDN

### 1. Purchase a VPS

Recommended:
- Hetzner (Germany, affordable) - CX11 3.79€/month
- DigitalOcean - $6/month
- Linode - $5/month

### 2. Configure DNS

In Cloudflare Dashboard:
1. Add A record: `nsheep.yourdomain.com` → `YOUR_VPS_IP`
2. Enable orange cloud (Proxied)

### 3. Deploy NSheep

```bash
# On the VPS
mkdir -p /opt/nsheep
cd /opt/nsheep

# Download binary (from GitHub Releases)
wget https://github.com/YOUR_USERNAME/nsheep/releases/latest/download/nsheep-linux-amd64.tar.gz
tar -xzf nsheep-linux-amd64.tar.gz
chmod +x nsheep

# Create config
cat > cfg.yaml << 'EOF'
server:
  bindAddr: "127.0.0.1"
  port: 8080

github:
  token: ""

local:
  tarballDir: "./data/tarballs"
  metadataDir: "./data/metadata"

cloudflare:
  accountId: ""
  r2AccessKeyId: ""
  r2SecretKey: ""
  r2Bucket: "nsheep-packages"
  kvNamespaceId: ""
  apiToken: ""

storage: local
EOF
```

### 4. Configure Nginx (Optional, Recommended)

```nginx
# /etc/nginx/sites-available/nsheep
server {
    listen 80;
    server_name nsheep.yourdomain.com;
    
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Large file uploads
        client_max_body_size 100M;
    }
}
```

Enable HTTPS (handled automatically by Cloudflare)

---

## Cloudflare Service Setup

### 1. Create R2 Bucket

```bash
# Using wrangler
npm install -g wrangler
wrangler login

# Create bucket
wrangler r2 bucket create nsheep-packages

# Get S3-compatible credentials
wrangler r2 bucket s3 list nsheep-packages
```

Or via Dashboard:
1. Open Cloudflare Dashboard → R2
2. Click "Create bucket"
3. Name: `nsheep-packages`
4. Save the Access Key ID and Secret Access Key

### 2. Create KV Namespace

```bash
wrangler kv:namespace create "NSHEEP_INDEX"
```

Or via Dashboard:
1. Workers & Pages → KV
2. Create a namespace
3. Name: `nsheep-index`
4. Save the Namespace ID

### 3. Create API Token

In Dashboard:
1. My Profile → API Tokens
2. Create Token
3. Use template "Edit Cloudflare Workers"
4. Permissions:
   - Account: Cloudflare Tunnel:Read
   - Zone: Zone:Read, DNS:Edit
   - R2: Edit
   - Workers KV Storage: Edit

---

## CI/CD Deployment

### GitHub Secrets Setup

In Repository Settings → Secrets and variables → Actions:

```
# For Cloudflare storage
CF_ACCOUNT_ID
CF_API_TOKEN
CF_R2_ACCESS_KEY_ID
CF_R2_SECRET_ACCESS_KEY
CF_R2_BUCKET
CF_KV_NAMESPACE_ID

# For Cloudflare Tunnel (if used)
CF_TUNNEL_TOKEN

# For traditional SSH deployment (if used)
SSH_PRIVATE_KEY
PRODUCTION_HOST
PRODUCTION_USER
```

### Automatic Deployment

Pushing code to the `main` branch will automatically trigger deployment (per `.github/workflows/deploy.yml`)

---

## Verify Deployment

```bash
# Health check
curl https://nsheep.yourdomain.com/health

# Test ingestion
curl -X POST https://nsheep.yourdomain.com/api/v1/packages/ingest \
  -H "Content-Type: application/json" \
  -d '{"url": "https://github.com/nim-lang/jsony"}'

# View package list
curl https://nsheep.yourdomain.com/api/v1/packages
```

---

## Troubleshooting

### Tunnel Connection Issues
```bash
cloudflared tunnel diagnose
cloudflared tunnel info <tunnel-id>
```

### R2 Permission Errors
Check if API Token has R2:Edit permission

### KV Access Failures
Verify the KV namespace ID is correct

### View Logs
```bash
# Docker
docker logs nsheep

# Systemd
journalctl -u nsheep -f
```
