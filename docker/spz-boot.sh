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
# DISCORD_REQUIRE_MENTION and DISCORD_ALLOWED_CHANNELS by
# plugins/platforms/discord/adapter.py,
# DISCORD_HOME_CHANNEL and HERMES_MODEL by cron/scheduler.py — so they must
# keep their upstream spelling. Renaming one would leave the adapter looking
# for a variable nobody sets, which is silent: no error, just an agent that
# answers nobody. Each SPZ_ name below falls back to the pre-rename name, so a
# redeploy landing before the Railway variables are renamed still boots on the
# old ones. Drop the fallbacks once Railway is updated.

mkdir -p "$HERMES_HOME"

# Which of the fleet this container is. Each persona is moving onto its own
# Railway service with its own Discord bot, scoped to its own channel, so Zach
# talks to each agent directly instead of through SPZ; hermes-spz keeps #spz and
# #approvals. SPZ_ROLE names that.
#
# It defaults to "spz" deliberately: a service whose Railway variables have not
# been touched must boot exactly as it did before this variable existed, so
# landing this change is a no-op everywhere until Railway says otherwise. Every
# role-dependent branch below is written as "spz is the status quo, a persona is
# the departure" for the same reason.
SPZ_ROLE="${SPZ_ROLE:-spz}"
case "${SPZ_ROLE}" in
  spz|trainer|clinic|manager|clz) ;;
  *)
    # Warn, don't exit. This is a container start command: refusing to boot on a
    # typo takes the agent offline, which is worse than running scoped. An
    # unrecognized role is treated as a persona rather than as spz, because
    # hermes-spz is the one service that never sets the variable at all — so a
    # typo can only come from a persona service, where the safe reading is
    # "scope me and relay for nobody", not "behave like SPZ".
    echo "[spz-boot] Warning: unrecognized SPZ_ROLE '${SPZ_ROLE}' — treating this as a persona instance, not spz"
    ;;
esac

# Which persona relays this instance still carries: a comma-separated list of
# persona keys (trainer, clinic, manager, clz), no spaces. As each persona gets
# its own container its key comes out of this list on hermes-spz and SPZ stops
# relaying for it — the channel then belongs to that persona's own bot, and two
# bots answering the same channel is the failure this avoids.
#
# Unset on hermes-spz means all four, which is exactly today's behaviour. Unset
# on a persona container means none: a persona answers as itself and carries
# nobody. An explicit value always wins either way, and the literal "none"
# spells out an empty list (an empty string can't, since sh cannot distinguish
# unset from empty here without ${VAR+x} gymnastics that read worse than a word).
if [ -n "${SPZ_RELAY_CHANNELS}" ]; then
  SPZ_RELAY_LIST="${SPZ_RELAY_CHANNELS}"
elif [ "${SPZ_ROLE}" = "spz" ]; then
  SPZ_RELAY_LIST="trainer,clinic,manager,clz"
else
  SPZ_RELAY_LIST="none"
fi
if [ "${SPZ_RELAY_LIST}" = "none" ]; then
  SPZ_RELAY_LIST=""
fi

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

# $1 = persona key, matched against SPZ_RELAY_LIST — a persona that has moved to
#      its own container is filtered out here, and because DERIVED_FREE_CHANNELS
#      is accumulated in this same function, it leaves the free-response list at
#      the same time and for the same reason. There is no second place to edit.
# $2 = channel id (skipped entirely when unset, so a persona whose channel id
#      isn't configured simply gets no entry), $3 = the relay prompt.
add_persona_channel() {
  case ",${SPZ_RELAY_LIST}," in
    *",$1,"*) ;;
    *) return 0 ;;
  esac
  [ -n "$2" ] || return 0
  CHANNEL_PROMPTS="${CHANNEL_PROMPTS}        \"$2\": \"$3\"
"
  if [ -z "${DERIVED_FREE_CHANNELS}" ]; then
    DERIVED_FREE_CHANNELS="$2"
  else
    DERIVED_FREE_CHANNELS="${DERIVED_FREE_CHANNELS},$2"
  fi
}

# These prompts become YAML double-quoted scalars, so they must contain no
# double quote and no backslash. Each names its tool AND that tool's argument
# explicitly, because the four tools take differently-named arguments
# (instruction / message / goal / brief) and a wrong guess is a silent
# no-reply in a channel Zach is waiting on.
add_persona_channel trainer "${SPZ_CHANNEL_TRAINER:-${DISCORD_CHANNEL_TRAINER}}" \
  "This channel belongs to The Trainer, the agent for The Gym. Do not answer it yourself: pass Zach's message to the instruct_trainer tool as its instruction argument, then reply with exactly the text that tool returns - no preamble, summary or commentary of your own. If the tool errors, say so plainly and quote the error rather than answering in its place."
add_persona_channel clinic "${SPZ_CHANNEL_CLINIC:-${DISCORD_CHANNEL_CLINIC}}" \
  "This channel belongs to The Medical Team, the agent for The Clinic. Do not answer it yourself: pass Zach's message to the ask_medical tool as its message argument, then reply with exactly the text that tool returns - no preamble, summary or commentary of your own. If the tool errors, say so plainly and quote the error rather than answering in its place."
add_persona_channel manager "${SPZ_CHANNEL_MANAGER:-${DISCORD_CHANNEL_MANAGER}}" \
  "This channel belongs to The Manager, the agent that runs the content-ops pipeline. Do not answer it yourself: pass Zach's message to the ask_manager tool as its message argument, then reply with exactly the text that tool returns - no preamble, summary or commentary of your own. Use instruct_manager instead only when Zach clearly wants a preference remembered going forward. If the tool errors, say so plainly and quote the error."
add_persona_channel clz "${SPZ_CHANNEL_CLZ:-${DISCORD_CHANNEL_CLZ}}" \
  "This channel belongs to CLZ, the agent for Organic Ecom. Do not answer it yourself: pass Zach's message to the delegate_to_clz tool as its goal argument, then reply with exactly the text that tool returns - no preamble, summary or commentary of your own. That tool runs a real task and can take a while, so wait for it. If it errors, say so plainly and quote the error."

# The AI Content Creator was here, relaying to request_content_generation. That
# persona no longer exists, so the entry is gone rather than left to rot: an
# unset channel id already made add_persona_channel skip it silently, which
# means a stale line here would have looked live while doing nothing — the
# hardest kind of config to reason about later. Its dashboard-side pieces
# (contentAgent.ts, the request_content_generation tool, the content MCP token)
# are a separate cleanup in that repo.

# A persona container runs its own Discord bot and owns exactly one channel.
# Scoping it there is two framework variables, neither of which this script
# invents: DISCORD_ALLOWED_CHANNELS is the adapter's whitelist — once set, every
# message outside it is dropped, by on_message and by the slash-command gate
# alike (plugins/platforms/discord/adapter.py) — and DISCORD_FREE_RESPONSE_CHANNELS
# waives DISCORD_REQUIRE_MENTION, which defaults to true, so Zach can just type
# instead of @mentioning a single-purpose bot in its own channel every message.
# Both are set only when Railway has not set them explicitly, the same
# env-beats-derived rule the free-response block below follows.
#
# Deliberately inert when SPZ_ROLE is spz: hermes-spz answers in several
# channels, so a whitelist of one would be exactly wrong there.
if [ "${SPZ_ROLE}" != "spz" ] && [ -n "${SPZ_PERSONA_CHANNEL}" ]; then
  if [ -z "${DISCORD_ALLOWED_CHANNELS}" ]; then
    DISCORD_ALLOWED_CHANNELS="${SPZ_PERSONA_CHANNEL}"
    export DISCORD_ALLOWED_CHANNELS
  fi
  if [ -z "${DISCORD_FREE_RESPONSE_CHANNELS}" ]; then
    DISCORD_FREE_RESPONSE_CHANNELS="${SPZ_PERSONA_CHANNEL}"
    export DISCORD_FREE_RESPONSE_CHANNELS
  fi
  echo "[spz-boot] Role ${SPZ_ROLE} scoped to channel ${SPZ_PERSONA_CHANNEL}"
fi

# Agent-to-agent conversation. Each persona listens in exactly one channel (the
# whitelist just above) and now admits messages authored by other bots there, so
# the fleet talks to each other in the persona channels rather than in a room of
# their own: the Manager asks the Trainer by posting in #the-trainer, and the
# Trainer answers in #the-trainer.
#
# That one-listener-per-channel shape is what makes this safe. This framework has
# no loop guard — nothing counts bot-to-bot turns or breaks a cycle. It doesn't
# need one here: a reply lands in a channel whose only listener is the bot that
# wrote it, and a bot never wakes on its own messages, so an exchange runs out on
# its own. Put two listeners in one room and nothing stops them, which is exactly
# why there is no shared #agents channel in this design.
#
# Deliberately NOT set when SPZ_ROLE is spz, and that is load-bearing rather than
# tidiness. hermes-spz relays the persona channels while the personas' own bots
# are still coming up, and it posts those relayed answers into the same channels
# as a bot. If SPZ also listened to bots it would answer the personas' replies
# and re-relay them, which is the one arrangement here that could actually cycle.
# Left at the framework default ("none") SPZ cannot see a bot message at all, so
# the hazard is removed structurally instead of by getting a cutover order right.
#
# DISCORD_BOTS_REQUIRE_INLINE_MENTION is deliberately left at its false default.
# It exists to stop reply-ping ping-pong between bots sharing a channel, which
# the shape above already prevents; switching it on would instead oblige every
# agent to know the others' bot *user* ids on top of their channel ids, and a
# missing <@id> token is a silent no-answer rather than an error.
if [ "${SPZ_ROLE}" != "spz" ] && [ -z "${DISCORD_ALLOW_BOTS}" ]; then
  DISCORD_ALLOW_BOTS="all"
  export DISCORD_ALLOW_BOTS
  echo "[spz-boot] Role ${SPZ_ROLE} admits messages from other agents"
fi

# The roster a persona needs in order to *start* a conversation rather than only
# answer one. send_message addresses Discord as discord:<channel id>, so an agent
# that doesn't know the other channels' ids can only ever reply where it was
# spoken to. Built from the same SPZ_CHANNEL_* variables hermes-spz already uses
# for relaying, so channel ids keep one vocabulary across the fleet — but note
# each persona service needs the full set, not just its own SPZ_PERSONA_CHANNEL.
#
# Self is excluded on purpose. An agent handed its own channel id will eventually
# post to it, and since a bot never wakes on its own messages that message goes
# nowhere while looking, from the agent's side, exactly like a delivered one.
FLEET_ROSTER=""

# $1 = persona key (matched against SPZ_ROLE to drop self), $2 = how the agent
# should think of that colleague, $3 = channel id — absent id means absent line,
# so a persona that hasn't been given the others' ids simply gets no roster and
# behaves as it did before, rather than emitting a target that goes nowhere.
# Nothing is added on hermes-spz at all. It cannot receive a bot message (see
# DISCORD_ALLOW_BOTS above), so half the roster's advice would be false there,
# and it already reaches every persona through its MCP tools — a send_message
# path would be a second, worse route whose answer lands in a channel SPZ isn't
# reading. Its SOUL.md also stays exactly what Railway says it is.
add_fleet_member() {
  [ "${SPZ_ROLE}" != "spz" ] || return 0
  [ "$1" != "${SPZ_ROLE}" ] || return 0
  [ -n "$3" ] || return 0
  FLEET_ROSTER="${FLEET_ROSTER}- $2 — send_message with target discord:$3
"
}
add_fleet_member trainer "The Trainer, the agent for The Gym" \
  "${SPZ_CHANNEL_TRAINER:-${DISCORD_CHANNEL_TRAINER}}"
add_fleet_member clinic "The Medical Team, the agent for The Clinic" \
  "${SPZ_CHANNEL_CLINIC:-${DISCORD_CHANNEL_CLINIC}}"
add_fleet_member manager "The Manager, the agent that runs the content-ops pipeline" \
  "${SPZ_CHANNEL_MANAGER:-${DISCORD_CHANNEL_MANAGER}}"
add_fleet_member clz "CLZ, the agent for Organic Ecom" \
  "${SPZ_CHANNEL_CLZ:-${DISCORD_CHANNEL_CLZ}}"

# Appended to whatever persona text Railway supplies rather than written
# separately, because SOUL.md is the only context that survives into a
# cron-triggered turn — channel_prompts shape one inbound message in one channel,
# so a roster hung there would be invisible to hermes-manager's content-ops poll,
# which is the one job most likely to need to tell another agent something.
#
# Concatenating into SPZ_SOUL_MD (rather than appending to the file) keeps the
# existing single write below as the only thing that touches SOUL.md, so the file
# is still rebuilt whole on every boot and can't accumulate a roster per restart.
if [ -n "${FLEET_ROSTER}" ]; then
  SPZ_SOUL_MD="${SPZ_SOUL_MD}

## The rest of the fleet

You are one of several agents Zach runs, each owning one Discord channel. The
others are:

${FLEET_ROSTER}
When one of them writes in your channel, treat it as a colleague asking a
genuine question and answer it there, in your channel, the same way you would
answer Zach — briefly, and without repeating their message back to them. Do not
forward what they said on to anyone else.

When you need something only another agent knows, ask it directly with
send_message rather than guessing or telling Zach to go and ask. Say who you are
and what you need in one message; their answer appears in their channel, not
yours, so ask only when the answer is worth Zach reading it there.

Zach reads all of these channels, so talk to each other as though he is
listening, because he is."
fi

# A persona channel is useless if every message needs an @mention first
# (DISCORD_REQUIRE_MENTION defaults to true), so the channels wired above join
# the free-response list automatically, along with #spz and #approvals — the
# latter is load-bearing, since a free-typed `YES <code>` there is never seen
# otherwise. Guarded on the variable being unset so an explicit Railway value
# still wins, matching the adapter's own env-beats-YAML convention; the cost of
# setting it by hand is that you must then list every channel yourself.
#
# #spz and #approvals are added whether or not any relay survived. They used to
# be reached only when at least one persona channel was wired, which was fine
# while SPZ carried all four — but the whole point of SPZ_RELAY_CHANNELS is that
# that number falls to zero as the personas move out, and #approvals losing
# free-response on the boot where the last relay leaves is precisely the silent
# failure this file keeps warning about. The export itself is still guarded on
# there being something to export, so an instance with no channel ids at all
# still sets nothing.
if [ -z "${DISCORD_FREE_RESPONSE_CHANNELS}" ]; then
  for _extra in "${SPZ_CHANNEL_HOME:-${DISCORD_CHANNEL_SPZ}}" \
                "${SPZ_CHANNEL_APPROVALS:-${DISCORD_CHANNEL_APPROVALS}}"; do
    [ -n "${_extra}" ] || continue
    if [ -z "${DERIVED_FREE_CHANNELS}" ]; then
      DERIVED_FREE_CHANNELS="${_extra}"
    else
      DERIVED_FREE_CHANNELS="${_extra},${DERIVED_FREE_CHANNELS}"
    fi
  done
  if [ -n "${DERIVED_FREE_CHANNELS}" ]; then
    DISCORD_FREE_RESPONSE_CHANNELS="${DERIVED_FREE_CHANNELS}"
    export DISCORD_FREE_RESPONSE_CHANNELS
    echo "[spz-boot] Free-response channels derived: ${DISCORD_FREE_RESPONSE_CHANNELS}"
  fi
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
# variable exists — but that fallback is now honoured only when SPZ_ROLE is spz.
# Every persona container sets DISCORD_ALLOWED_USERS (Zach has to be allowed to
# talk to his own agent), so an unnarrowed fallback would hand all four of them
# a 12PM roundup cron posting into their own channel. The guard itself is
# untouched and still keys on SPZ_ROUNDUP_ENABLED — SPZ_ROLE only gates the
# deprecated pre-rename fallback, and once that fallback is dropped this becomes
# two lines to delete. "timezone: Europe/London"
# above means this literal 12:00 stays correct across the BST/GMT clock change
# year-round — no manual seasonal nudge like the old Vercel cron needed.
# Idempotent: checked by name so a container restart never creates a duplicate.
#
# Delivery goes to DISCORD_HOME_CHANNEL (#spz) via the platform's registered
# standalone sender, so it works whether or not the gateway happens to be
# mid-restart when the cron fires.
SPZ_ROUNDUP_GUARD="${SPZ_ROUNDUP_ENABLED}"
if [ -z "${SPZ_ROUNDUP_GUARD}" ] && [ "${SPZ_ROLE}" = "spz" ]; then
  SPZ_ROUNDUP_GUARD="${DISCORD_ALLOWED_USERS}"
fi
if [ -n "${SPZ_ROUNDUP_GUARD}" ]; then
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
# How often the poll runs. A variable rather than a literal because the right
# interval is a cost/latency judgement that will be revisited — the framework
# convention here is to reach for config before code, and this way the next
# adjustment is a Railway edit rather than a commit.
#
# The default is hourly, down from the */30 it ran at for its first months. A
# firing is not one API call: every one starts a fresh conversation, so the
# system prompt, SOUL.md, the Hermes core toolset and the manager's ~19 MCP tool
# schemas are re-sent uncached on every round trip inside it, and the prompt
# below loops approve_video + scan_video over every pending video. That cost is
# paid 48 times a day at */30 even when the queue is empty. Hourly halves the
# floor; the pipeline is unattended, so nothing downstream notices the latency.
SPZ_CONTENT_OPS_CRON="${SPZ_CONTENT_OPS_CRON:-0 * * * *}"

if [ -n "${SPZ_CONTENT_OPS_POLL:-${CONTENT_OPS_POLL_ENABLED}}" ]; then
  # Same migration reasoning as the roundup job — the pre-SPZ-naming job would
  # otherwise keep polling every 30 minutes alongside its replacement, doubling
  # every approve_video/scan_video call on the dashboard side.
  hermes cron remove content-ops-poll >/dev/null 2>&1 || true

  # Removed and recreated on every boot rather than created only when absent,
  # the same departure spz-persona-checkin below already makes and for the same
  # reason. The name check this replaces only ever asked whether the job EXISTS,
  # never whether it still matches what this file says — so its schedule was
  # pinned to whatever it read on the first boot of that container. Editing the
  # interval here would have looked like it worked and changed nothing on any
  # already-running service, which is the silent failure this file keeps being
  # bitten by, and is precisely why a 30-minute poll outlived the decision to
  # widen it. Now that the schedule is a Railway variable the recreate is not
  # optional: a name check would make SPZ_CONTENT_OPS_CRON inert on every
  # service that has already booted once, which is all of them.
  #
  # Unlike the persona check-in, nothing is lost by rebuilding it. That job's
  # note about the next-run clock resetting on each redeploy applies to interval
  # schedules; these are absolute cron expressions, so the next run is the next
  # top of the hour no matter when the container last started.
  hermes cron remove spz-content-ops-poll >/dev/null 2>&1 || true
  hermes cron create "${SPZ_CONTENT_OPS_CRON}" \
    "Call get_pending_videos for faiz, arif, and taha. For each video returned, call approve_video with its details, then scan_video with its drive link — that single follow-up call transcribes it, checks sponsor/topic alignment, resolves sponsorship, and drafts captions for every platform in its category automatically. Do this for every pending video found, without asking me first. If a video errors, skip it and continue with the rest." \
    --name spz-content-ops-poll \
    && echo "[spz-boot] Content-ops poll scheduled (${SPZ_CONTENT_OPS_CRON})" \
    || echo "[spz-boot] Warning: failed to create spz-content-ops-poll cron job"
fi

# Per-persona proactive turn — the one thing a persona still cannot do. Each is
# purely reactive: it answers Zach, and since the fleet roster above it answers
# the other agents, but nothing makes it speak first. The two crons in this file
# both belong to other services (the roundup to hermes-spz, the content-ops poll
# to hermes-manager), so a persona container has no scheduled turn at all. This
# gives it one, delivered to its own channel via DISCORD_HOME_CHANNEL.
#
# A schedule variable and a prompt variable rather than anything hardcoded here,
# because what a proactive turn should say is entirely per-persona — a morning
# check-in from The Trainer and a follow-up sweep from The Clinic share nothing
# but firing on a timer. Both are required: a schedule with nothing to say would
# post an empty turn on a timer, which is worse than staying quiet, so a lone
# SPZ_PERSONA_CRON warns and creates nothing rather than guessing a prompt.
#
# Off unless Railway sets them, so landing this changes no live behaviour until a
# service opts in — the same no-op-by-default story as SPZ_ROLE. Skipped on spz
# entirely, which already posts the 12PM roundup into #spz and does not need a
# second scheduled message there.
#
# Removed and recreated on every boot rather than created only when absent. The
# existence checks above are right for jobs whose prompt is a literal in this
# file, but this prompt lives in a Railway variable Zach will iterate on, and a
# name check would pin the job to whatever the prompt said the first time it
# booted — editing the variable would appear to work and change nothing, which
# is precisely the silent failure this file keeps being bitten by. Rebuilding it
# every start matches how config.yaml and SOUL.md are already handled here. The
# cost is that the next-run clock resets on each redeploy; for a daily or hourly
# check-in that is invisible, and it is the reason this stays opt-in rather than
# being switched on for every persona by default.
#
# The name deliberately carries no role in it. The name is what remove and the
# checks key on, so a role-derived one would strand a job on any service whose
# SPZ_ROLE changed — the same superseded-name trap that needs explicit removal
# lines above. One container runs exactly one persona, so a fixed name cannot
# collide with anything and never needs migrating.
if [ "${SPZ_ROLE}" != "spz" ] && [ -n "${SPZ_PERSONA_CRON}" ]; then
  if [ -z "${SPZ_PERSONA_CRON_PROMPT}" ]; then
    echo "[spz-boot] Warning: SPZ_PERSONA_CRON set without SPZ_PERSONA_CRON_PROMPT — no proactive job created"
  else
    hermes cron remove spz-persona-checkin >/dev/null 2>&1 || true
    hermes cron create "${SPZ_PERSONA_CRON}" \
      "${SPZ_PERSONA_CRON_PROMPT}" \
      --name spz-persona-checkin \
      --deliver "discord" \
      && echo "[spz-boot] Role ${SPZ_ROLE} scheduled a proactive turn (${SPZ_PERSONA_CRON})" \
      || echo "[spz-boot] Warning: failed to create spz-persona-checkin cron job"
  fi
fi

chown -R hermes:hermes "$HERMES_HOME" 2>&1 || echo "[spz-boot] Warning: chown of $HERMES_HOME failed — continuing"

exec hermes gateway run
