#!/usr/bin/env bash
# Boot harness for docker/spz-boot.sh — the only behavioural check that script gets.
#
# Runs spz-boot.sh against a stubbed `hermes` and `chown` earlier on PATH and a throwaway
# HERMES_HOME, so the final `exec hermes gateway run` lands on the stub and the generated
# config.yaml / SOUL.md are left behind to inspect. Prints one labelled section per check;
# read them — a failing check prints FAIL/MISSING rather than changing the exit code.
# What each section is asking, and why none can be dropped: SPZ.md, "Verifying a
# `spz-boot.sh` change".
#
# Usage (Git Bash, from anywhere in the repo):  scripts/spz-boot-harness.sh
cd "$(git rev-parse --show-toplevel)"

# --- the harness: a stub `hermes` and `chown` earlier on PATH ---------------
STUB="$(mktemp -d)"; PATH="$STUB:$PATH"; export PATH
printf '#!/bin/sh\nexit 0\n' > "$STUB/chown"
cat > "$STUB/hermes" <<'STUB_EOF'
#!/bin/sh
# Logs every call, and models the cron store on the Railway volume, so that
# "the second boot must not create a duplicate" is checkable, not assumed.
echo "hermes $*" >> "$STUB_LOG"
JOBS="$HERMES_HOME/.stub-cron-jobs"
case "$1 $2" in
  "cron list")   [ -f "$JOBS" ] && sed 's/^/Name:      /' "$JOBS"; exit 0 ;;
  "cron create") while [ $# -gt 0 ]; do
                   if [ "$1" = "--name" ]; then echo "$2" >> "$JOBS"; break; fi
                   shift
                 done; exit 0 ;;
  "cron remove") grep -qxF "$3" "$JOBS" 2>/dev/null || exit 1  # absent => fail, as the real CLI does
                 grep -vxF "$3" "$JOBS" > "$JOBS.t"; mv "$JOBS.t" "$JOBS"; exit 0 ;;
esac
exit 0
STUB_EOF
chmod +x "$STUB/hermes" "$STUB/chown"

# $1 = a label for this boot's log; everything else comes from the caller's env.
boot() { STUB_LOG="$HERMES_HOME/$1.log"; export STUB_LOG; : > "$STUB_LOG"
         sh docker/spz-boot.sh; }

MCP="SPZ_MCP_URL=https://example.invalid/mcp SPZ_MCP_TOKEN=tok"

# --- 1. the spz role, the live shape, booted twice into one HERMES_HOME -----
SPZ="$(mktemp -d)"
( export HERMES_HOME="$SPZ" $MCP SPZ_SOUL_MD='You are SPZ.' \
    SPZ_RELAY_CHANNELS=none \
    SPZ_CHANNEL_HOME=111111111111111111 SPZ_CHANNEL_APPROVALS=222222222222222222 \
    SPZ_ROUNDUP_ENABLED=1 SPZ_CONTENT_OPS_POLL=1
  boot spz1; cp "$SPZ/config.yaml" "$SPZ/config.1.yaml"; boot spz2 )

echo "== IDEMPOTENCY: config.yaml identical across two boots =="
diff "$SPZ/config.1.yaml" "$SPZ/config.yaml" && echo "  OK"
echo "== IDEMPOTENCY: one job per name, not two =="; sort "$SPZ/.stub-cron-jobs"
echo "== boot 2 cron calls (remove+create for the poll; no second roundup create) =="
grep '^hermes cron' "$SPZ/spz2.log" | cut -c1-70
echo "== TOOLSETS: both a discord and a cron key; cronjob rides the poll flag =="
sed -n '/^platform_toolsets:/,/^[a-z]/p' "$SPZ/config.yaml"
echo "== QUOTED SCALARS =="; grep '"' "$SPZ/config.yaml"

# --- 2. the roundup switch OFF: the job must be REMOVED, not merely not made -
( export HERMES_HOME="$SPZ" $MCP SPZ_RELAY_CHANNELS=none SPZ_CONTENT_OPS_POLL=1 \
    DISCORD_ALLOWED_USERS=   # the pre-rename fallback; leave it set and the switch is inert
  boot spzoff )
echo "== ROUNDUP OFF: spz-daily-roundup removed unconditionally =="
grep '^hermes cron remove spz-daily-roundup' "$SPZ/spzoff.log" || echo "  MISSING — the bug is back"
echo "== ROUNDUP OFF: remaining jobs =="; sort "$SPZ/.stub-cron-jobs"

# --- 3. a persona role -------------------------------------------------------
P="$(mktemp -d)"
( export HERMES_HOME="$P" $MCP SPZ_SOUL_MD='You are The Trainer.' \
    SPZ_ROLE=trainer SPZ_PERSONA_CHANNEL=333333333333333333 \
    SPZ_CHANNEL_TRAINER=333333333333333333 SPZ_CHANNEL_CLINIC=444444444444444444 \
    SPZ_CHANNEL_MANAGER=555555555555555555 SPZ_CHANNEL_CLZ=666666666666666666
  boot persona )
echo "== SELF-EXCLUSION: the other three ids, never 333333333333333333 =="
grep 'send_message with target' "$P/SOUL.md"
echo "== persona: no roundup created =="
grep '^hermes cron create' "$P/persona.log" || echo "  OK: none"

# --- 4. relays on — the only shape that still emits channel_prompts ----------
R="$(mktemp -d)"
( export HERMES_HOME="$R" $MCP SPZ_CHANNEL_TRAINER=777777777777777777
  boot relay )
echo "== QUOTED SCALARS: channel_prompts keys must be \"777...\", not 777... =="
grep -A1 'channel_prompts:' "$R/config.yaml" | cut -c1-60

# --- 4b. fork skills: the block, and the two ways back ----------------------
echo "== SKILLS: dir resolved absolute, path quoted =="
sed -n '/^skills:/,/^[a-z]/p' "$SPZ/config.yaml"
S1="$(mktemp -d)"
( export HERMES_HOME="$S1" $MCP SPZ_RELAY_CHANNELS=none SPZ_SKILLS_DIR=none; boot skillsoff >/dev/null )
echo "== SKILLS: SPZ_SKILLS_DIR=none omits the key =="
grep -q '^skills:' "$S1/config.yaml" && echo "  FAIL: key emitted" || echo "  OK: absent"
S2="$(mktemp -d)"
( export HERMES_HOME="$S2" $MCP SPZ_RELAY_CHANNELS=none SPZ_SKILLS_DIR=/nonexistent
  boot skillsmiss ) | grep -i 'skills dir' || echo "  FAIL: a missing dir must warn, not pass silently"

# --- 5. the way back: `full` must omit the key ALTOGETHER --------------------
F="$(mktemp -d)"
( export HERMES_HOME="$F" $MCP SPZ_RELAY_CHANNELS=none \
    SPZ_TOOLSETS=full SPZ_CRON_TOOLSETS=full
  boot full )
echo "== FULL: platform_toolsets must be absent, not empty =="
grep -q platform_toolsets "$F/config.yaml" && echo "  FAIL: key emitted" || echo "  OK: absent"
