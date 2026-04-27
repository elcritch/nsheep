#!/bin/sh
# Run this on the VPS as root
# Generates an SSH key pair, configures the nsheep user, and prints the private key

set -e

USER="nsheep"
DEPLOY_DIR="/opt/nsheep"
KEY_FILE="/home/$USER/.ssh/nsheep_deploy"

echo "=== Setting up $USER for CI deploy ==="

# Ensure user exists with a shell
if ! id "$USER" >/dev/null 2>&1; then
    echo "Creating user $USER..."
    adduser -D -s /bin/sh "$USER"
else
    echo "User $USER exists, ensuring shell is set..."
    usermod -s /bin/sh "$USER"
fi

# Create .ssh directory
SSH_DIR="/home/$USER/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Generate SSH key pair if it doesn't exist
if [ ! -f "$KEY_FILE" ]; then
    echo "Generating SSH key pair..."
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "nsheep-ci-deploy"
    chown -R "$USER:$USER" "$SSH_DIR"
else
    echo "Key already exists at $KEY_FILE"
fi

# Ensure authorized_keys contains the public key
PUB_KEY="$(cat "$KEY_FILE.pub")"
if [ -f "$SSH_DIR/authorized_keys" ] && grep -q "$PUB_KEY" "$SSH_DIR/authorized_keys" 2>/dev/null; then
    echo "Public key already in authorized_keys"
else
    echo "$PUB_KEY" >> "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
    chown -R "$USER:$USER" "$SSH_DIR"
    echo "Public key added to authorized_keys"
fi

# Install sudo if missing
if ! command -v sudo >/dev/null 2>&1; then
    echo "Installing sudo..."
    apk add sudo
fi

# Allow nsheep to restart services without password
cat > /etc/sudoers.d/nsheep-deploy <<'EOF'
nsheep ALL=(ALL) NOPASSWD: /sbin/rc-service nsheep restart, /sbin/rc-service nsheep-fetcher restart, /sbin/rc-service nsheep status, /sbin/rc-service nsheep-fetcher status
EOF
chmod 440 /etc/sudoers.d/nsheep-deploy

echo "=== Sudoers configured ==="

# Ensure deploy dir is owned by nsheep
if [ -d "$DEPLOY_DIR" ]; then
    chown -R "$USER:$USER" "$DEPLOY_DIR"
    echo "=== $DEPLOY_DIR ownership fixed ==="
else
    echo "WARNING: $DEPLOY_DIR does not exist yet"
fi

# Print the private key for GitHub Secrets
echo ""
echo "========================================"
echo "COPY THIS PRIVATE KEY TO GITHUB SECRETS"
echo "Secret name: SSH_PRIVATE_KEY"
echo "========================================"
echo ""
cat "$KEY_FILE"
echo ""
echo "========================================"
echo "Test the connection from any machine:"
echo "  ssh -i <private-key-file> $USER@<this-server-ip>"
echo "========================================"
