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

chown -R hermes:hermes "$HERMES_HOME" 2>&1 || echo "[spz-boot] Warning: chown of $HERMES_HOME failed — continuing"

exec hermes gateway run
