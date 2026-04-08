#!/usr/bin/env bash
# ============================================================
# AUTOPILOT — Health Check & Auto-Restart
# Covers: Dele Super App, BizSuite Pro, OpenClaw
# Run via cron every 2 minutes or as a systemd service
# ============================================================

set -euo pipefail

# ── CONFIG ──────────────────────────────────────────────────
DISCORD_WEBHOOK="${DISCORD_WEBHOOK_URL:-}"
LOG_FILE="/var/log/autopilot/healthcheck.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
ALERT_COOLDOWN=300  # seconds between repeat alerts per service
COOLDOWN_DIR="/tmp/autopilot_cooldowns"

mkdir -p "$(dirname "$LOG_FILE")" "$COOLDOWN_DIR"

# Service definitions: "name|url|restart_cmd|critical"
SERVICES=(
  "Dele API|https://dele-api.railway.app/health|railway up --service dele-api|true"
  "BizSuite PageForge|https://pageforge.railway.app/health|railway up --service pageforge|true"
  "BizSuite OutreachBot|https://outreachbot.railway.app/health|railway up --service outreachbot|true"
  "OpenClaw|https://openclaw.railway.app/health|railway up --service openclaw|false"
)

# ── HELPERS ─────────────────────────────────────────────────
log() { echo "[$TIMESTAMP] $*" | tee -a "$LOG_FILE"; }

send_discord() {
  local color="$1" title="$2" message="$3" emoji="$4"
  [[ -z "$DISCORD_WEBHOOK" ]] && return
  curl -s -X POST "$DISCORD_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "{
      \"embeds\": [{
        \"title\": \"$emoji $title\",
        \"description\": \"$message\",
        \"color\": $color,
        \"footer\": {\"text\": \"Autopilot · $TIMESTAMP\"}
      }]
    }" > /dev/null
}

is_cooling_down() {
  local service_key="${1// /_}"
  local cooldown_file="$COOLDOWN_DIR/$service_key"
  if [[ -f "$cooldown_file" ]]; then
    local last_alert now elapsed
    last_alert=$(cat "$cooldown_file")
    now=$(date +%s)
    elapsed=$(( now - last_alert ))
    [[ $elapsed -lt $ALERT_COOLDOWN ]] && return 0
  fi
  date +%s > "$cooldown_file"
  return 1
}

check_service() {
  local name url restart_cmd critical
  IFS='|' read -r name url restart_cmd critical <<< "$1"

  local status_code
  status_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 --max-time 20 "$url" 2>/dev/null || echo "000")

  if [[ "$status_code" == "200" ]]; then
    log "✅ $name — OK ($status_code)"
    return 0
  fi

  log "❌ $name — FAILED (HTTP $status_code) — attempting restart"

  # Attempt restart
  if eval "$restart_cmd" >> "$LOG_FILE" 2>&1; then
    log "🔄 $name — restart issued"
    sleep 15

    # Re-check after restart
    local recheck
    recheck=$(curl -s -o /dev/null -w "%{http_code}" \
      --connect-timeout 10 --max-time 20 "$url" 2>/dev/null || echo "000")

    if [[ "$recheck" == "200" ]]; then
      log "✅ $name — recovered after restart"
      if ! is_cooling_down "${name}_recover"; then
        send_discord 3066993 "$name Recovered" \
          "Service was down (HTTP $status_code) but recovered after auto-restart." "✅"
      fi
    else
      log "🚨 $name — STILL DOWN after restart (HTTP $recheck)"
      if ! is_cooling_down "${name}_down"; then
        local urgency=""
        [[ "$critical" == "true" ]] && urgency="**CRITICAL SERVICE**\n"
        send_discord 15158332 "$name Still Down" \
          "${urgency}HTTP $recheck after restart attempt. Manual intervention needed.\n\`\`\`\nURL: $url\nLast checked: $TIMESTAMP\n\`\`\`" "🚨"
      fi
    fi
  else
    log "⚠️  $name — restart command failed"
    if ! is_cooling_down "${name}_restart_fail"; then
      send_discord 16776960 "$name Restart Failed" \
        "Could not issue restart for $name. Check Railway CLI auth.\nURL: $url" "⚠️"
    fi
  fi
}

# ── MAIN ─────────────────────────────────────────────────────
log "─── Health check run started ───"
for svc in "${SERVICES[@]}"; do
  check_service "$svc"
done
log "─── Health check run complete ───"
