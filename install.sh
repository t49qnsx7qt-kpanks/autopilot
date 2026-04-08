#!/usr/bin/env bash
# ============================================================
# AUTOPILOT — Installer
# Sets up cron jobs, systemd service, log rotation, env file
# Run as root or with sudo on your Ubuntu VPS / EC2 instance
# ============================================================

set -euo pipefail

AUTOPILOT_DIR="/opt/autopilot"
LOG_DIR="/var/log/autopilot"
SCRIPTS_DIR="$AUTOPILOT_DIR/scripts"
CURRENT_USER="${SUDO_USER:-$USER}"

echo "╔══════════════════════════════════════╗"
echo "║        AUTOPILOT INSTALLER           ║"
echo "╚══════════════════════════════════════╝"

# ── 1. DIRECTORIES ──────────────────────────────────────────
echo "→ Creating directories..."
mkdir -p "$AUTOPILOT_DIR" "$LOG_DIR" "$SCRIPTS_DIR"
chmod 750 "$LOG_DIR"

# ── 2. COPY SCRIPTS ─────────────────────────────────────────
echo "→ Installing scripts..."
cp healthcheck.sh "$SCRIPTS_DIR/"
cp backup.sh "$SCRIPTS_DIR/"
chmod +x "$SCRIPTS_DIR/"*.sh

# ── 3. ENV FILE (edit this with your real values) ───────────
echo "→ Creating env file..."
if [[ ! -f "$AUTOPILOT_DIR/.env" ]]; then
cat > "$AUTOPILOT_DIR/.env" << 'EOF'
# ── Discord ─────────────────────────────────────────────────
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/YOUR_WEBHOOK_HERE

# ── Railway ─────────────────────────────────────────────────
RAILWAY_TOKEN=your_railway_token_here

# ── Databases ───────────────────────────────────────────────
DELE_DATABASE_URL=postgresql://user:pass@host:5432/dele_db
BIZSUITE_DATABASE_URL=postgresql://user:pass@host:5432/bizsuite_db

# ── AWS (for backups) ────────────────────────────────────────
AWS_ACCESS_KEY_ID=your_key_here
AWS_SECRET_ACCESS_KEY=your_secret_here
AWS_DEFAULT_REGION=us-east-1
S3_BACKUP_BUCKET=s3://your-backup-bucket-name

# ── GCP alternative (uncomment to use instead of S3) ────────
# GCS_BACKUP_BUCKET=gs://your-gcp-bucket
EOF
  echo "  ⚠️  Edit $AUTOPILOT_DIR/.env with your real values"
else
  echo "  ✓ .env already exists, skipping"
fi
chmod 600 "$AUTOPILOT_DIR/.env"

# ── 4. SYSTEMD SERVICE (continuous health monitor) ──────────
echo "→ Installing systemd health monitor service..."
cat > /etc/systemd/system/autopilot-health.service << EOF
[Unit]
Description=Autopilot Health Check Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$CURRENT_USER
EnvironmentFile=$AUTOPILOT_DIR/.env
ExecStart=/bin/bash -c 'while true; do $SCRIPTS_DIR/healthcheck.sh; sleep 120; done'
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable autopilot-health.service
systemctl start autopilot-health.service
echo "  ✓ autopilot-health.service started"

# ── 5. CRON JOBS ────────────────────────────────────────────
echo "→ Setting up cron jobs..."
CRON_FILE="/etc/cron.d/autopilot"
cat > "$CRON_FILE" << EOF
# Autopilot cron jobs
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Daily backup at 02:00 UTC
0 2 * * * $CURRENT_USER source $AUTOPILOT_DIR/.env && $SCRIPTS_DIR/backup.sh >> $LOG_DIR/backup.log 2>&1

# Weekly log cleanup (keep 30 days)
0 3 * * 0 $CURRENT_USER find $LOG_DIR -name "*.log" -mtime +30 -delete
EOF
chmod 644 "$CRON_FILE"
echo "  ✓ Cron jobs installed"

# ── 6. LOG ROTATION ─────────────────────────────────────────
echo "→ Configuring log rotation..."
cat > /etc/logrotate.d/autopilot << EOF
$LOG_DIR/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 640 $CURRENT_USER $CURRENT_USER
}
EOF
echo "  ✓ Log rotation configured"

# ── 7. SUMMARY ───────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✅  AUTOPILOT INSTALLED SUCCESSFULLY                ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Health checks:  every 2 min (systemd service)       ║"
echo "║  Backups:        daily 02:00 UTC (cron)              ║"
echo "║  Logs:           $LOG_DIR                  ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  NEXT STEPS:                                         ║"
echo "║  1. Edit $AUTOPILOT_DIR/.env                         ║"
echo "║  2. systemctl status autopilot-health                ║"
echo "║  3. Add deploy.yml to .github/workflows/             ║"
echo "║  4. Set GitHub Secrets (RAILWAY_TOKEN, DISCORD_*)    ║"
echo "╚══════════════════════════════════════════════════════╝"
