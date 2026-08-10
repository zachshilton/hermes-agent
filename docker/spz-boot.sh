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

# Naming: every variable this script alone consumes is SPZ_-prefixed. The
# DISCORD_*/HERMES_* names that survive below are read by the framework
# itself — DISCORD_ALLOWED_USERS by gateway/authz_mixin.py and
# gateway/pairing.py, DISCORD_FREE_RESPONSE_CHANNELS and
# DISCORD_REQUIRE_MENTION by plugins/platforms/discord/adapter.py,
# DISCORD_HOME_CHANNEL and HERMES_MODEL by cron/scheduler.py — so they must
# keep their upstream spelling. Renaming one would leave the adapter looking
# for a variable nobody sets, which is silent: no error, just an agent that
# answers nobody. Each SPZ_ name below falls back to the pre-rename name, so a
# redeploy landing before the Railway variables are renamed still boots on the
# old ones. Drop the fallbacks once Railway is updated.

mkdir -p "$HERMES_HOME"

# Persona channel relays. A message Zach types in #the-trainer, #the-clinic,
# #the-manager, #clz or #content-creator is still handled by this (SPZ's)
# agent — but primed with a per-channel prompt telling it to hand the message
# straight to that persona's MCP tool and echo the reply back untouched. The
# persona's own agent, on its own Anthropic key, still writes every word; SPZ
# is only the carrier. That is why this needs no forwarding endpoint and no
# Python: the dashboard's api/discord-inbound.ts was built to receive
# forwarded messages, but this framework's Discord adapter answers with its
# own agent rather than forwarding anywhere, and config reaches the same end.
#
# `channel_prompts` is read out of platforms.discord.extra by the adapter's
# resolve_channel_prompt (gateway/platforms/base.py) and appended to that one
# message's ephemeral context in gateway/run.py — so it shapes a single reply
# and never leaks into #spz or into SOUL.md.
CHANNEL_PROMPTS=""
DERIVED_FREE_CHANNELS=""

# $1 = channel id (skipped entirely when unset, so a persona whose channel id
#      isn't configured simply gets no entry), $2 = the relay prompt.
add_persona_channel() {
  [ -n "$1" ] || return 0
  CHANNEL_PROMPTS="${CHANNEL_PROMPTS}        \"$1\": \"$2\"
"
  if [ -z "${DERIVED_FREE_CHANNELS}" ]; then
    DERIVED_FREE_CHANNELS="$1"
  else
    DERIVED_FREE_CHANNELS="${DERIVED_FREE_CHANNELS},$1"
  fi
}

# These prompts become YAML double-quoted scalars, so they must contain no
# double quote and no backslash. Each names its tool AND that tool's argument
# explicitly, because the four tools take differently-named arguments
# (instruction / message / goal / brief) and a wrong guess is a silent
# no-reply in a channel Zach is waiting on.
add_persona_channel "${SPZ_CHANNEL_TRAINER:-${DISCORD_CHANNEL_TRAINER}}" \
  "This channel belongs to The Trainer, the agent for The Gym. Do not answer it yourself: pass Zach's message to the instruct_trainer tool as its instruction argument, then reply with exactly the text that tool returns - no preamble, summary or commentary of your own. If the tool errors, say so plainly and quote the error rather than answering in its place."
add_persona_channel "${SPZ_CHANNEL_CLINIC:-${DISCORD_CHANNEL_CLINIC}}" \
  "This channel belongs to The Medical Team, the agent for The Clinic. Do not answer it yourself: pass Zach's message to the ask_medical tool as its message argument, then reply with exactly the text that tool returns - no preamble, summary or commentary of your own. If the tool errors, say so plainly and quote the error rather than answering in its place."
add_persona_channel "${SPZ_CHANNEL_MANAGER:-${DISCORD_CHANNEL_MANAGER}}" \
  "This channel belongs to The Manager, the agent that runs the content-ops pipeline. Do not answer it yourself: pass Zach's message to the ask_manager tool as its message argument, then reply with exactly the text that tool returns - no preamble, summary or commentary of your own. Use instruct_manager instead only when Zach clearly wants a preference remembered going forward. If the tool errors, say so plainly and quote the error."
add_persona_channel "${SPZ_CHANNEL_CLZ:-${DISCORD_CHANNEL_CLZ}}" \
  "This channel belongs to CLZ, the agent for Organic Ecom. Do not answer it yourself: pass Zach's message to the delegate_to_clz tool as its goal argument, then reply with exactly the text that tool returns - no preamble, summary or commentary of your own. That tool runs a real task and can take a while, so wait for it. If it errors, say so plainly and quote the error."

# The AI Content Creator was here, relaying to request_content_generation. That
# persona no longer exists, so the entry is gone rather than left to rot: an
# unset channel id already made add_persona_channel skip it silently, which
# means a stale line here would have looked live while doing nothing — the
# hardest kind of config to reason about later. Its dashboard-side pieces
# (contentAgent.ts, the request_content_generation tool, the content MCP token)
# are a separate cleanup in that repo.

# A persona channel is useless if every message needs an @mention first
# (DISCORD_REQUIRE_MENTION defaults to true), so the channels wired above join
# the free-response list automatically, along with #spz and #approvals — the
# latter is load-bearing, since a free-typed `YES <code>` there is never seen
# otherwise. Guarded on the variable being unset so an explicit Railway value
# still wins, matching the adapter's own env-beats-YAML convention; the cost of
# setting it by hand is that you must then list every channel yourself.
if [ -z "${DISCORD_FREE_RESPONSE_CHANNELS}" ] && [ -n "${DERIVED_FREE_CHANNELS}" ]; then
  for _extra in "${SPZ_CHANNEL_HOME:-${DISCORD_CHANNEL_SPZ}}" \
                "${SPZ_CHANNEL_APPROVALS:-${DISCORD_CHANNEL_APPROVALS}}"; do
    [ -n "${_extra}" ] || continue
    DERIVED_FREE_CHANNELS="${_extra},${DERIVED_FREE_CHANNELS}"
  done
  DISCORD_FREE_RESPONSE_CHANNELS="${DERIVED_FREE_CHANNELS}"
  export DISCORD_FREE_RESPONSE_CHANNELS
  echo "[spz-boot] Free-response channels derived: ${DISCORD_FREE_RESPONSE_CHANNELS}"
fi

# Omitted entirely rather than emitted empty when no channel ids are set — a
# bare `channel_prompts:` key would parse as null, which resolve_channel_prompt
# tolerates, but an absent block keeps the generated config honest about what
# this instance actually has wired.
if [ -n "${CHANNEL_PROMPTS}" ]; then
  PLATFORMS_BLOCK="platforms:
  discord:
    extra:
      channel_prompts:
${CHANNEL_PROMPTS}"
else
  PLATFORMS_BLOCK=""
fi

# Discord is the framework's most verbose display tier by default
# (gateway/display_config.py's _TIER_HIGH), and this config previously set no
# display block at all — so every persona channel was narrating the relay it
# exists to hide. A message to #the-trainer produced a "⚙️
# mcp__spz__instruct_trainer" bubble quoting the first 40 characters back, any
# preamble SPZ emitted alongside the tool call as its own separate message (the
# channel prompt's "no preamble" only ever governed the final turn), a "⏳
# Working — 3 min" heartbeat, and none of it cleaned up afterwards. The four
# settings below leave the channel showing the question and the persona's
# answer, which is what it was always meant to look like.
#
# "off" MUST stay quoted. The config is read with yaml.safe_load, which is YAML
# 1.1, where a bare off is the boolean False — and the resolver compares this
# value against the string "off". Unquoted it silently does nothing, which is
# the same class of trap as the unquoted channel ids below.
#
# Note this is per-platform, not per-channel: display settings resolve on the
# platform key alone (ChannelOverride carries only model/provider/system_prompt),
# so this quietens #spz too. That is the accepted cost — there is no per-channel
# layer to hang it on.
cat > "$HERMES_HOME/config.yaml" <<EOF
timezone: "Europe/London"
model: "${HERMES_MODEL:-anthropic/claude-sonnet-5}"
display:
  platforms:
    discord:
      tool_progress: "off"
      interim_assistant_messages: false
      long_running_notifications: false
      busy_ack_detail: false
mcp_servers:
  spz:
    url: "${SPZ_MCP_URL}"
    headers:
      Authorization: "Bearer ${SPZ_MCP_TOKEN}"
    timeout: 180
${PLATFORMS_BLOCK}
EOF

if [ -n "${SPZ_SOUL_MD}" ]; then
  printf '%s\n' "${SPZ_SOUL_MD}" > "$HERMES_HOME/SOUL.md"
fi

# Daily 12PM Roundup — only on the instance Zach actually talks to. The guard
# is now SPZ_ROUNDUP_ENABLED, an explicit flag set on hermes-spz alone, rather
# than a piggyback on whichever credential happened to be unique to that
# service. That piggyback has broken twice: first as SMS_ALLOWED_USERS, then
# as DISCORD_ALLOWED_USERS, each time retiring the underlying feature and
# taking the roundup with it silently. A flag that exists only to answer "is
# this hermes-spz?" cannot be retired out from under the cron. It still falls
# back to DISCORD_ALLOWED_USERS so this redeploy is safe before the Railway
# variable exists. "timezone: Europe/London"
# above means this literal 12:00 stays correct across the BST/GMT clock change
# year-round — no manual seasonal nudge like the old Vercel cron needed.
# Idempotent: checked by name so a container restart never creates a duplicate.
#
# Delivery goes to DISCORD_HOME_CHANNEL (#spz) via the platform's registered
# standalone sender, so it works whether or not the gateway happens to be
# mid-restart when the cron fires.
if [ -n "${SPZ_ROUNDUP_ENABLED:-${DISCORD_ALLOWED_USERS}}" ]; then
  # One-time migrations, not manual steps. Each superseded name has to be
  # removed explicitly, because the name check below only ever asks whether the
  # CURRENT name exists — an old job it doesn't know about would sit there
  # forever, still firing on its old schedule and delivery. `daily-roundup` was
  # the SMS-era job; `daily-roundup-discord` is the pre-SPZ-naming one, which
  # is otherwise a live duplicate that would post the roundup twice.
  # Removing is safe to attempt on every boot — once gone the command just
  # fails and is suppressed. `hermes cron remove` resolves by name as well as
  # id (cron/jobs.py resolve_job_ref), so no id lookup is needed.
  hermes cron remove daily-roundup >/dev/null 2>&1 || true
  hermes cron remove daily-roundup-discord >/dev/null 2>&1 || true

  if ! hermes cron list --all 2>&1 | grep -q "Name:      spz-daily-roundup"; then
    hermes cron create "0 12 * * *" \
      "Call get_daily_roundup_text, then post its exact returned text — no changes, additions, or commentary of your own." \
      --name spz-daily-roundup \
      --deliver "discord" \
      || echo "[spz-boot] Warning: failed to create spz-daily-roundup cron job"
  fi
fi

# Content-ops poll — only on hermes-manager (SPZ_CONTENT_OPS_POLL is only ever
# set there, same explicit-flag scoping as the roundup cron above). Runs the
# whole review->captioned pipeline unattended: approve_video and scan_video
# are already registered ungated for the manager agent in api/mcp.ts, and
# scan_video alone now resolves sponsorship + drafts every platform's
# caption server-side, so this is genuinely just two tool calls per video.
if [ -n "${SPZ_CONTENT_OPS_POLL:-${CONTENT_OPS_POLL_ENABLED}}" ]; then
  # Same migration reasoning as the roundup job — the pre-SPZ-naming job would
  # otherwise keep polling every 30 minutes alongside its replacement, doubling
  # every approve_video/scan_video call on the dashboard side.
  hermes cron remove content-ops-poll >/dev/null 2>&1 || true

  if ! hermes cron list --all 2>&1 | grep -q "Name:      spz-content-ops-poll"; then
    hermes cron create "*/30 * * * *" \
      "Call get_pending_videos for faiz, arif, and taha. For each video returned, call approve_video with its details, then scan_video with its drive link — that single follow-up call transcribes it, checks sponsor/topic alignment, resolves sponsorship, and drafts captions for every platform in its category automatically. Do this for every pending video found, without asking me first. If a video errors, skip it and continue with the rest." \
      --name spz-content-ops-poll \
      || echo "[spz-boot] Warning: failed to create spz-content-ops-poll cron job"
  fi
fi

chown -R hermes:hermes "$HERMES_HOME" 2>&1 || echo "[spz-boot] Warning: chown of $HERMES_HOME failed — continuing"

exec hermes gateway run
