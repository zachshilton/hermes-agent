#!/bin/sh
# Generates this instance's Hermes config (MCP client wiring + persona) from
# Railway env vars on every container start, then hands off to the real
# gateway process. Idempotent by design — always overwrites, so a Railway
# variable change takes effect on next redeploy without hand-editing files
# inside the (possibly ephemeral, if no volume is attached yet) data dir.
#
# Confirmed via diagnostics that Railway's custom start command runs this
# script directly as root, bypassing the image's normal s6-overlay
# entrypoint (and therefore stage2-hook.sh's own UID remap/chown logic)
# entirely — so ownership has to be fixed here instead, before handing off
# to `hermes gateway run`, which drops to the non-root "hermes" user
# internally and needs $HERMES_HOME already writable by that user.
set -e

mkdir -p "$HERMES_HOME"

cat > "$HERMES_HOME/config.yaml" <<EOF
timezone: "Europe/London"
model: "${HERMES_MODEL:-anthropic/claude-sonnet-5}"
mcp_servers:
  spz:
    url: "${SPZ_MCP_URL}"
    headers:
      Authorization: "Bearer ${SPZ_MCP_TOKEN}"
    timeout: 180
EOF

if [ -n "${SPZ_SOUL_MD}" ]; then
  printf '%s\n' "${SPZ_SOUL_MD}" > "$HERMES_HOME/SOUL.md"
fi

# Daily 12PM Roundup — only on the instance with its own SMS gateway
# (SMS_ALLOWED_USERS is only ever set on hermes-spz, never hermes-manager,
# so this naturally scopes the job to the right service without a separate
# flag). "timezone: Europe/London" above means this literal 12:00 stays
# correct across the BST/GMT clock change year-round — no manual seasonal
# nudge like the old Vercel cron needed. Idempotent: checked by name so a
# container restart never creates a duplicate job.
if [ -n "${SMS_ALLOWED_USERS}" ]; then
  if ! hermes cron list --all 2>&1 | grep -q "Name:      daily-roundup"; then
    hermes cron create "0 12 * * *" \
      "Call get_daily_roundup_text, then send me its exact returned text via SMS — no changes, additions, or commentary of your own." \
      --name daily-roundup \
      --deliver "sms:${SMS_ALLOWED_USERS}" \
      || echo "[spz-boot] Warning: failed to create daily-roundup cron job"
  fi
fi

chown -R hermes:hermes "$HERMES_HOME" 2>&1 || echo "[spz-boot] Warning: chown of $HERMES_HOME failed — continuing"

exec hermes gateway run
