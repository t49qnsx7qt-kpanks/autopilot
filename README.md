# Autopilot

Production automation stack I built and use across my own platforms (Dele, BizSuite, MnemoPay). Handles deployment, health monitoring, backup, and alerting so I don't have to babysit servers at 3am.

## What it does

**Health monitoring** (`scripts/healthcheck.sh`)
- Polls every service's `/health` endpoint every 2 minutes via systemd
- If something's down: auto-restarts it via Railway CLI, waits 15 seconds, re-checks
- Still down after restart? Sends a Discord alert with full context (HTTP status, URL, timestamp)
- 5-minute cooldown between repeat alerts so Discord doesn't blow up
- Marks critical vs non-critical services differently

**Automated backups** (`scripts/backup.sh`)
- Runs daily at 02:00 UTC via cron
- `pg_dump` each Postgres database, gzip compress, encrypt with GPG, push to S3
- Tars upload directories and config files
- Auto-prunes backups older than 30 days
- Discord summary when done (or when something fails)

**CI/CD pipeline** (`github-actions/deploy.yml`)
- Triggers on push to main
- Smart change detection: only deploys services that actually changed
- Pipeline: test (pytest) -> build (Docker validate) -> deploy (Railway) -> health verify -> Discord notify
- Concurrency control: never cancels a deploy mid-flight
- Separate success/failure Discord notifications with commit details

**Monitoring dashboard** (`dashboard/autopilot-dashboard.html`)
- Real-time service status cards
- Uptime percentage tracking
- Response time monitoring
- Auto-refreshes every 30 seconds
- Single HTML file, no dependencies

**One-command install** (`install.sh`)
- Sets up systemd service for health monitoring
- Configures cron for daily backups
- Creates log rotation
- Generates `.env` template
- Works on any Ubuntu/Debian VPS or EC2 instance

## Architecture

```
Git push -> GitHub Actions
              |-- Run tests (pytest)
              |-- Build Docker image (validate)
              |-- railway up --service <name>
              |-- Wait 30s -> health check all endpoints
              +-- Discord notify (success or failure)

systemd service (always running)
  +-- healthcheck.sh every 2 min
        |-- curl /health on each service
        |-- On fail: railway up -> wait 15s -> re-check
        |-- Still down: Discord alert (with cooldown)
        +-- Recovered: Discord notify

cron (daily 02:00 UTC)
  +-- backup.sh
        |-- pg_dump each database -> gzip -> GPG encrypt -> S3
        |-- tar uploads/ and data/ -> S3
        |-- Prune backups > 30 days
        +-- Discord summary
```

## Setup

```bash
git clone https://github.com/t49qnsx7qt-kpanks/autopilot /opt/autopilot
cd /opt/autopilot
sudo bash install.sh
sudo nano /opt/autopilot/.env   # fill in your values
sudo systemctl restart autopilot-health
```

## Adding a service

Edit the `SERVICES` array in `scripts/healthcheck.sh`:

```bash
SERVICES=(
  "My Service|https://myservice.com/health|railway up --service myservice|true"
  # name       URL                          restart command                 critical?
)
```

`critical=true` adds a **CRITICAL SERVICE** label to Discord alerts.

## Scaling beyond Railway

**AWS:** Replace `railway up` with `aws ecs update-service --force-new-deployment`. Use RDS for Postgres. Health checks hit ALB target group URLs.

**GCP:** Replace restart with `gcloud run services update`. Use Cloud SQL. Switch S3 bucket to GCS and `gsutil`.

## Requirements

- Ubuntu/Debian (tested on 22.04 and 24.04)
- Railway CLI (for restart commands)
- AWS CLI (for S3 backups)
- GPG (for backup encryption)
- curl, jq, systemd, cron

## License

MIT
