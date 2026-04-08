#!/usr/bin/env bash
# ============================================================
# AUTOPILOT — Backup Script
# Backs up: PostgreSQL DBs, uploaded files, env configs
# Destination: AWS S3 (or GCP bucket)
# Schedule: Daily at 02:00 UTC via cron
# ============================================================

set -euo pipefail

# ── CONFIG ──────────────────────────────────────────────────
DISCORD_WEBHOOK="${DISCORD_WEBHOOK_URL:-}"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
DATE=$(date '+%Y-%m-%d')
LOG_FILE="/var/log/autopilot/backup.log"
BACKUP_DIR="/tmp/autopilot_backups/$TIMESTAMP"
S3_BUCKET="${S3_BACKUP_BUCKET:-s3://your-backup-bucket}"
RETENTION_DAYS=30

# PostgreSQL connections (add yours)
declare -A DBS=(
  ["dele_db"]="${DELE_DATABASE_URL:-}"
  ["bizsuite_db"]="${BIZSUITE_DATABASE_URL:-}"
)

# Directories to back up
BACKUP_DIRS=(
  "/app/uploads"
  "/app/data"
)

mkdir -p "$BACKUP_DIR" "$(dirname "$LOG_FILE")"

# ── HELPERS ─────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

send_discord() {
  local color="$1" title="$2" message="$3" emoji="$4"
  [[ -z "$DISCORD_WEBHOOK" ]] && return
  curl -s -X POST "$DISCORD_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "{\"embeds\":[{\"title\":\"$emoji $title\",\"description\":\"$message\",\"color\":$color,\"footer\":{\"text\":\"Autopilot Backup · $(date '+%Y-%m-%d %H:%M:%S')\"}}]}" \
    > /dev/null
}

human_size() { du -sh "$1" 2>/dev/null | cut -f1; }

# ── DATABASE BACKUPS ────────────────────────────────────────
backup_databases() {
  local total_size=0
  log "── Database backups starting ──"

  for db_name in "${!DBS[@]}"; do
    local db_url="${DBS[$db_name]}"
    [[ -z "$db_url" ]] && log "⚠️  Skipping $db_name — no connection URL set" && continue

    local dump_file="$BACKUP_DIR/${db_name}_${TIMESTAMP}.sql.gz"
    log "Dumping $db_name..."

    if pg_dump "$db_url" | gzip -9 > "$dump_file" 2>>"$LOG_FILE"; then
      local size
      size=$(human_size "$dump_file")
      log "✅ $db_name — $size"
    else
      log "❌ $db_name — dump FAILED"
      send_discord 15158332 "Backup Failed: $db_name" \
        "Database dump failed for \`$db_name\`. Check connection URL and pg_dump access." "❌"
    fi
  done
}

# ── FILE BACKUPS ────────────────────────────────────────────
backup_files() {
  log "── File backups starting ──"

  for dir in "${BACKUP_DIRS[@]}"; do
    [[ ! -d "$dir" ]] && log "⚠️  Skipping $dir — directory not found" && continue

    local dir_name
    dir_name=$(basename "$dir")
    local archive="$BACKUP_DIR/${dir_name}_${TIMESTAMP}.tar.gz"

    if tar -czf "$archive" -C "$(dirname "$dir")" "$dir_name" 2>>"$LOG_FILE"; then
      log "✅ $dir — $(human_size "$archive")"
    else
      log "❌ $dir — archive FAILED"
    fi
  done
}

# ── UPLOAD TO S3 ────────────────────────────────────────────
upload_to_s3() {
  log "── Uploading to S3 ──"
  local dest="${S3_BUCKET}/backups/${DATE}/"

  if aws s3 cp "$BACKUP_DIR" "$dest" --recursive \
    --storage-class STANDARD_IA \
    --sse AES256 \
    >> "$LOG_FILE" 2>&1; then

    local total_size
    total_size=$(du -sh "$BACKUP_DIR" | cut -f1)
    log "✅ Upload complete — $total_size → $dest"
    echo "$total_size"
  else
    log "❌ S3 upload FAILED"
    send_discord 15158332 "Backup Upload Failed" \
      "Could not upload backups to S3 ($dest). Check AWS credentials and bucket policy." "❌"
    return 1
  fi
}

# ── PRUNE OLD BACKUPS ───────────────────────────────────────
prune_old_backups() {
  log "── Pruning backups older than ${RETENTION_DAYS} days ──"
  aws s3 ls "${S3_BUCKET}/backups/" | \
    awk '{print $2}' | \
    while read -r prefix; do
      local folder_date="${prefix%/}"
      local cutoff
      cutoff=$(date -d "-${RETENTION_DAYS} days" '+%Y-%m-%d')
      if [[ "$folder_date" < "$cutoff" ]]; then
        log "Deleting old backup: $folder_date"
        aws s3 rm "${S3_BUCKET}/backups/${folder_date}/" --recursive >> "$LOG_FILE" 2>&1
      fi
    done
}

# ── MAIN ─────────────────────────────────────────────────────
log "════ Backup run started ════"

backup_databases
backup_files
upload_size=$(upload_to_s3)
prune_old_backups

# Cleanup local temp
rm -rf "$BACKUP_DIR"

log "════ Backup run complete ════"

# Success alert (once per day is fine, no cooldown)
send_discord 3066993 "Daily Backup Complete" \
  "All databases and files backed up successfully.\n\n**Size:** $upload_size\n**Destination:** \`${S3_BUCKET}/backups/${DATE}/\`\n**Retention:** ${RETENTION_DAYS} days" "💾"
