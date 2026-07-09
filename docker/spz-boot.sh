#!/bin/sh
# Generates this instance's Hermes config (MCP client wiring + persona) from
# Railway env vars on every container start, then hands off to the real
# gateway process. Idempotent by design — always overwrites, so a Railway
# variable change takes effect on next redeploy without hand-editing files
# inside the (possibly ephemeral, if no volume is attached yet) data dir.
set -e

echo "[spz-boot-diag] whoami=$(whoami 2>&1) id=$(id 2>&1)"
echo "[spz-boot-diag] HERMES_HOME=$HERMES_HOME ls -la:"
ls -la "$HERMES_HOME" 2>&1 | head -20
echo "[spz-boot-diag] attempting mkdir -p $HERMES_HOME/logs directly:"
mkdir -p "$HERMES_HOME/logs" 2>&1 && echo "[spz-boot-diag] mkdir logs: OK" || echo "[spz-boot-diag] mkdir logs: FAILED"
ls -ld "$HERMES_HOME/logs" 2>&1

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

exec hermes gateway run
