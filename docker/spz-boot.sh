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

# --- How SPZ answers -------------------------------------------------------
#
# Concatenated onto SPZ_SOUL_MD the same way the fleet roster above is, and for
# the same reason: SOUL.md is the only context that survives into a
# cron-triggered turn, so guidance hung anywhere else is invisible to the daily
# roundup — the one turn nobody is watching as it happens.
#
# Why this lives in the repo rather than in the Railway variable, against this
# file's usual "config over code" instinct: it is reviewed prose about how to
# answer, not a value Zach iterates on between deploys. The roundup prompt is a
# Railway variable precisely because it gets edited often; this is closer to the
# roster — structural, stable, and worth having in the diff where a change to it
# can be read and argued with. It APPENDS, so whatever persona text Railway
# supplies still leads.
#
# The third paragraph is the load-bearing one and should not be trimmed for
# brevity. "Be blunt" on its own reliably degrades into confident invention,
# which is the exact failure the finance and ecom skills are built to avoid —
# both instruct the model to say it cannot see something rather than guess, and
# a soul that rewards decisiveness without separating it from certainty pulls
# directly against them.
#
# SPZ_ANSWER_STYLE=none omits the block, the same escape-hatch shape as
# SPZ_RELAY_CHANNELS=none and SPZ_SKILLS_DIR=none.
# Also gated on SPZ_SOUL_MD already being non-empty. Without that guard the
# append makes the variable truthy on a service that sets no persona text at
# all, which flips the write below from "skipped" to "runs" and overwrites the
# SOUL.md stage2-hook seeded from docker/SOUL.md — replacing an identity line
# with guidance and no identity. hermes-spz always sets the variable so this
# never fires here, but it is exactly the kind of silent regression this file
# keeps being bitten by, and the guard costs one condition.
if [ -n "${SPZ_SOUL_MD}" ] && [ "${SPZ_ANSWER_STYLE:-on}" != "none" ]; then
  SPZ_SOUL_MD="${SPZ_SOUL_MD}

## How to answer

Lead with the verdict. Zach asked for your read, not a survey of options — give
the answer in the first sentence, then the reasoning that got you there.

Analyse before you answer. If a question rests on a wrong premise, say so
instead of answering around it. If the honest answer is that an idea is bad, say
it is bad and say why, then say what you would do instead. Do not soften a real
objection into \"something to consider\". Do not list pros and cons to avoid
picking one.

Blunt is not the same as certain, and confusing the two is the one way this goes
wrong. A raw verdict on something you know is what he wants. A raw verdict on
something you are guessing at is worse than hedging, because it sounds identical
to the real thing. State what you know plainly and what you do not know just as
plainly. \"I can't see that\" is a complete answer. Never fill a gap with
something that sounds right.

No preamble, no restating the question, no offer of further help at the end.
Short sentences. If the answer is one line, it is one line."
  echo "[spz-boot] Answer-style guidance appended to SOUL.md"
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

# Live voice channels. `/voice join`, typed in a text channel while Zach is
# sitting in a voice channel, connects this bot to that channel, transcribes what
# he says (gateway/run.py _handle_voice_channel_input -> tools.transcription_tools)
# and speaks the reply back (tools.tts_tool). All of it already exists upstream —
# the only thing missing was that both halves need a provider named in
# config.yaml, and neither picks a working one here by default.
#
# Both providers must be ones whose SDK is BAKED INTO THE IMAGE, which rules out
# the framework's own defaults and is the whole reason this block is explicit:
#
#   - STT defaults to "local" (faster-whisper), and TTS defaults to "edge".
#     Neither ships in the container. pyproject's [all] extra deliberately
#     excludes the voice and edge-tts deps, and the Dockerfile installs
#     `--extra all --extra messaging`, so both would fall to tools/lazy_deps.py
#     at first use — a pip install into /opt/hermes/.venv, which is inside the
#     immutable image layer and owned by root while the gateway runs as the
#     hermes user (the shim drops privileges via s6-setuidgid). That install
#     fails, and even where it succeeded it would be lost on every redeploy.
#   - `openai==2.24.0` is a CORE dependency, so it is present. Both the OpenAI
#     and the Groq STT paths drive it (Groq via base_url), as does OpenAI TTS.
#
# Hence: providers here, not a Dockerfile change. Setting stt.provider explicitly
# also stops the auto-detect ladder (local > groq > openai) from silently trying
# the missing local backend first.
#
# Gated on there being a key to use, following the same rule as every other
# instance-scoped feature in this file: presence of the Railway variable is the
# switch. No key, no block, and the generated config is unchanged from today.
# Voice transport itself needs nothing further — discord.py[voice] (PyNaCl +
# davey for DAVE E2EE) comes in via the messaging extra, and ffmpeg and libopus
# are already in the image. Discord-side, the bot needs Connect + Speak on the
# voice channel; scripts/discord-voice-doctor.py checks all of it from inside
# the container.
#
# Deliberately NOT setting voice.auto_tts. That is the global "speak every
# reply" switch, and it would have SPZ reading its text answers in #spz aloud.
# `/voice join` already flips this chat to voice mode on its own and persists
# that to gateway_voice_mode.json on the volume, so the opt-in stays per-channel
# and survives a restart.
SPZ_STT_PROVIDER="${SPZ_STT_PROVIDER:-openai}"
SPZ_TTS_PROVIDER="${SPZ_TTS_PROVIDER:-openai}"
SPZ_TTS_VOICE="${SPZ_TTS_VOICE:-alloy}"
SPZ_TTS_MODEL="${SPZ_TTS_MODEL:-gpt-4o-mini-tts}"

# Delivery, as opposed to timbre. SPZ_TTS_VOICE picks WHO is speaking;
# these two shape HOW. Both are omitted from the emitted config when unset, so
# this block is a no-op until Railway says otherwise.
#
# SPZ_TTS_SPEED is a multiplier the framework clamps to 0.25-4.0. Emitted
# UNQUOTED because it must reach Python as a number — tts_tool does
# float(oai_config.get("speed", ...)), which raises on a quoted non-numeric and
# would take the whole reply down rather than degrade. So validate here: a
# non-numeric value is dropped with a warning instead of being passed on.
#
# SPZ_TTS_INSTRUCTIONS is free-text style direction ("measured, formal, dry"),
# supported by the gpt-4o*-tts family and rejected by legacy tts-1 (tts_tool
# warns and drops it there). It is emitted as a YAML block scalar rather than a
# quoted string precisely because it is prose someone will iterate on: an
# apostrophe or a stray quote inside double quotes breaks the whole config, and
# a config that fails to parse takes the gateway down for a wording tweak.
SPZ_TTS_SPEED="${SPZ_TTS_SPEED:-}"
SPZ_TTS_INSTRUCTIONS="${SPZ_TTS_INSTRUCTIONS:-}"

TTS_EXTRA=""
if [ -n "${SPZ_TTS_SPEED}" ]; then
  case "${SPZ_TTS_SPEED}" in
    ''|*[!0-9.]*|*.*.*)
      echo "[spz-boot] Warning: SPZ_TTS_SPEED='${SPZ_TTS_SPEED}' is not a number; ignoring" >&2
      ;;
    *)
      TTS_EXTRA="${TTS_EXTRA}    speed: ${SPZ_TTS_SPEED}
"
      ;;
  esac
fi
if [ -n "${SPZ_TTS_INSTRUCTIONS}" ]; then
  # Block scalar: every line indented under the key, so quotes, apostrophes and
  # newlines in the value cannot terminate a string or break the document.
  TTS_EXTRA="${TTS_EXTRA}    instructions: |-
$(printf '%s\n' "${SPZ_TTS_INSTRUCTIONS}" | sed 's/^/      /')
"
fi

# What a spoken turn leaves behind in the TEXT channel. Both keep a voice
# conversation in the voice channel instead of duplicating it into the chat log:
# `echo_transcript` is Zach's own speech, posted as "**[Voice]** @zach: ...";
# `suppress_text_reply` is SPZ's answer, otherwise both spoken AND posted.
#
# The defaults reproduce the framework's historical behaviour exactly, so this
# block changes nothing until a Railway variable says otherwise — the same
# safety story as SPZ_ROLE. These are display preferences rather than
# credentials, which is why they are config.yaml keys read by
# _voice_chat_visibility rather than env vars the gateway reads directly.
#
# Note what suppress_text_reply does NOT do: the assistant turn is still written
# to session history, so the conversation stays coherent across turns. Only the
# outbound chat copy is dropped, and only when the audio actually went out — a
# TTS failure falls back to posting the text rather than losing the answer.
SPZ_VOICE_ECHO_TRANSCRIPT="${SPZ_VOICE_ECHO_TRANSCRIPT:-true}"
SPZ_VOICE_SUPPRESS_TEXT="${SPZ_VOICE_SUPPRESS_TEXT:-false}"

# Speak the "gateway online" notice as a voice note as well as posting it, so a
# redeploy demonstrates what the configured voice sounds like. Tuning a voice is
# a listen-adjust-redeploy loop and the voice-channel connection does not survive
# a restart — without this, hearing the result means sitting in a voice channel
# and running /voice join after every single deploy.
#
# Off by default, and additive when on: the text notice is sent and counted
# before the audio is attempted, so every failure here leaves startup as it was.
SPZ_VOICE_STARTUP_NOTE="${SPZ_VOICE_STARTUP_NOTE:-false}"

# These two are emitted UNQUOTED, which is the exact inverse of the rule the
# rest of this file follows — and for the same underlying reason. They have to
# reach Python as YAML booleans, because the reader takes bool() of whatever it
# finds and `bool("false")` is True. Quote them and "off" means "on", silently.
#
# So normalise here rather than trusting the Railway value: anything that is not
# recognisably true/false becomes the documented default and says so. Without
# this, `SPZ_VOICE_SUPPRESS_TEXT=no` emits the bare word `no`, which YAML 1.1
# does read as False — but `=nope` emits a string, and every string is truthy.
# That is the third instance of this trap in this file, as predicted.
normalize_bool() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true|yes|on|1)   printf 'true' ;;
    false|no|off|0)  printf 'false' ;;
    *)
      printf '%s' "$2"
      echo "[spz-boot] Warning: $3='$1' is not a boolean; using $2" >&2
      ;;
  esac
}
SPZ_VOICE_ECHO_TRANSCRIPT="$(normalize_bool "${SPZ_VOICE_ECHO_TRANSCRIPT}" true SPZ_VOICE_ECHO_TRANSCRIPT)"
SPZ_VOICE_SUPPRESS_TEXT="$(normalize_bool "${SPZ_VOICE_SUPPRESS_TEXT}" false SPZ_VOICE_SUPPRESS_TEXT)"
SPZ_VOICE_STARTUP_NOTE="$(normalize_bool "${SPZ_VOICE_STARTUP_NOTE}" false SPZ_VOICE_STARTUP_NOTE)"

# ElevenLabs. The OpenAI voices read as synthetic and are slow enough to be felt
# in a spoken exchange, so this is the realism/latency option — its SDK is baked
# into the image via `--extra tts-premium` rather than lazy-installed, for the
# reason the Dockerfile spells out.
#
# Separate names from SPZ_TTS_VOICE / SPZ_TTS_MODEL on purpose. Those are the
# OpenAI voice NAME and model; these are ElevenLabs IDs, a different namespace
# entirely. Reusing the names would invite exactly the transposition that has
# already cost one debugging session — a voice in the model slot fails at speak
# time with a 404, never at boot.
#
# The model default is the fast one. eleven_flash_v2_5 is built for
# conversational latency; eleven_turbo_v2_5 trades some speed for fidelity and
# eleven_multilingual_v2 is the most faithful and the slowest. Latency is the
# complaint that brought us here, so speed is the default and the others are a
# variable away.
#
# No voice_id default is invented here — the framework's own fallback (Adam) is
# American, and picking a British one means choosing a real id from the
# ElevenLabs voice library. An id made up in a shell script would 404 at speak
# time, which is the failure mode this file works hardest to avoid.
SPZ_ELEVENLABS_MODEL_ID="${SPZ_ELEVENLABS_MODEL_ID:-eleven_flash_v2_5}"
SPZ_ELEVENLABS_VOICE_ID="${SPZ_ELEVENLABS_VOICE_ID:-}"

# Delivery rate, 0.7-1.2. Unset emits nothing, so the request is unchanged from
# before this existed. Validated here rather than passed through, for the reason
# SPZ_TTS_SPEED already is: tts_tool calls float() on it and a non-numeric raises
# mid-reply. Note this is a DIFFERENT key from SPZ_TTS_SPEED — that one is read
# only by the OpenAI backend, so setting it while on elevenlabs does nothing.
SPZ_ELEVENLABS_SPEED="${SPZ_ELEVENLABS_SPEED:-}"

# STT and TTS no longer share a credential, so they are gated separately. An
# ElevenLabs key alone buys a voice that speaks but cannot listen; a Groq key
# alone is the reverse. Emitting `stt.enabled: true` without a key it can use
# would fail on the first spoken word instead of at boot.
VOICE_STT_OK=""
if [ -n "${OPENAI_API_KEY}" ] || [ -n "${VOICE_TOOLS_OPENAI_KEY}" ] || [ -n "${GROQ_API_KEY}" ]; then
  VOICE_STT_OK="yes"
fi
VOICE_TTS_OK=""
case "${SPZ_TTS_PROVIDER}" in
  elevenlabs)
    if [ -n "${ELEVENLABS_API_KEY}" ]; then
      VOICE_TTS_OK="yes"
    else
      echo "[spz-boot] Warning: SPZ_TTS_PROVIDER=elevenlabs but ELEVENLABS_API_KEY is unset; TTS disabled" >&2
    fi
    ;;
  *)
    if [ -n "${OPENAI_API_KEY}" ] || [ -n "${VOICE_TOOLS_OPENAI_KEY}" ]; then
      VOICE_TTS_OK="yes"
    fi
    ;;
esac

if [ -n "${VOICE_STT_OK}" ] || [ -n "${VOICE_TTS_OK}" ]; then
  # Quoted for the same reason everything else here is: this is read with
  # yaml.safe_load (YAML 1.1), and an unquoted provider or voice name is one
  # rename away from being coerced to something that isn't a string.
  VOICE_BLOCK=""
  if [ -n "${VOICE_STT_OK}" ]; then
    VOICE_BLOCK="stt:
  enabled: true
  provider: \"${SPZ_STT_PROVIDER}\"
"
  fi
  if [ -n "${VOICE_TTS_OK}" ]; then
    VOICE_BLOCK="${VOICE_BLOCK}tts:
  provider: \"${SPZ_TTS_PROVIDER}\"
"
    if [ "${SPZ_TTS_PROVIDER}" = "elevenlabs" ]; then
      VOICE_BLOCK="${VOICE_BLOCK}  elevenlabs:
    model_id: \"${SPZ_ELEVENLABS_MODEL_ID}\"
"
      # Omitted rather than emitted empty when unset: the framework falls back
      # to its own default voice, whereas an empty string reaches the API as a
      # blank id.
      if [ -n "${SPZ_ELEVENLABS_SPEED}" ]; then
        case "${SPZ_ELEVENLABS_SPEED}" in
          ''|*[!0-9.]*|*.*.*)
            echo "[spz-boot] Warning: SPZ_ELEVENLABS_SPEED='${SPZ_ELEVENLABS_SPEED}' is not a number; ignoring" >&2
            ;;
          *)
            VOICE_BLOCK="${VOICE_BLOCK}    speed: ${SPZ_ELEVENLABS_SPEED}
"
            ;;
        esac
      fi
      if [ -n "${SPZ_ELEVENLABS_VOICE_ID}" ]; then
        VOICE_BLOCK="${VOICE_BLOCK}    voice_id: \"${SPZ_ELEVENLABS_VOICE_ID}\"
"
      else
        echo "[spz-boot] Warning: SPZ_ELEVENLABS_VOICE_ID unset; using the framework default voice (Adam, American)" >&2
      fi
      TTS_DESC="${SPZ_ELEVENLABS_MODEL_ID}/${SPZ_ELEVENLABS_VOICE_ID:-default}"
    else
      VOICE_BLOCK="${VOICE_BLOCK}  openai:
    model: \"${SPZ_TTS_MODEL}\"
    voice: \"${SPZ_TTS_VOICE}\"
${TTS_EXTRA}"
      TTS_DESC="${SPZ_TTS_VOICE}"
    fi
  else
    TTS_DESC="disabled"
  fi
  VOICE_BLOCK="${VOICE_BLOCK}voice:
  echo_transcript: ${SPZ_VOICE_ECHO_TRANSCRIPT}
  suppress_text_reply: ${SPZ_VOICE_SUPPRESS_TEXT}
  startup_voice_note: ${SPZ_VOICE_STARTUP_NOTE}
"
  if [ -n "${VOICE_STT_OK}" ]; then
    STT_DESC="${SPZ_STT_PROVIDER}"
  else
    STT_DESC="disabled"
  fi
  echo "[spz-boot] Voice enabled (stt=${STT_DESC}, tts=${SPZ_TTS_PROVIDER}/${TTS_DESC})"
else
  VOICE_BLOCK=""
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

# Which native toolsets each surface loads — the largest cost lever in this file.
#
# With no platform_toolsets key at all, _get_platform_tools
# (hermes_cli/tools_config.py) falls back to the platform default: hermes-discord
# for an adapter turn, hermes-cron for a scheduled one. Both resolve to a 51-tool
# bundle, of which 16 survive their check_fn gates on a machine with no API keys
# and serialize to ~9.8k tokens of JSON schema — more on Railway, where the keys
# that gate the browser, web, image and vision tools are actually present. That
# block is re-sent on EVERY API call, and this fleet opens almost none of it:
# there is no repo on the container to read or patch, no browser, nothing to
# shell out to, and the kanban and Home Assistant tools address a dashboard this
# agent already reaches over MCP.
#
# The MCP spz tools are NOT at risk here. _get_platform_tools unions every
# globally-enabled MCP server back in unless the list names one explicitly or
# carries the no_mcp sentinel, so scoping the native side leaves the entire
# dashboard surface intact — which is the only surface these agents ever use.
# That is what makes this safe to do from config, and it is why the narrow lists
# below can afford to be as short as they are.
#
# Two lists, because the two surfaces genuinely differ. A Discord turn is a
# conversation with Zach and wants memory, history and skills; a cron turn is an
# unattended pipeline whose every real action is an MCP call. The literal "full"
# on either restores that platform's framework default — the way back without a
# code change, if an agent turns out to need something cut here.
SPZ_TOOLSETS="${SPZ_TOOLSETS:-discord,clarify,memory,session_search,todo,skills}"
SPZ_CRON_TOOLSETS="${SPZ_CRON_TOOLSETS:-clarify,memory,todo}"

# $1 = comma-separated toolset names -> a YAML sequence indented under a platform
# key. Names are emitted unquoted on purpose: these are bare lowercase
# identifiers, none of which YAML 1.1 coerces. Do not extend this to values that
# could — the quoting trap that has already bitten channel ids and tool_progress
# twice applies to anything else that ends up in this file.
emit_toolset_list() {
  _emit_old_ifs="$IFS"
  IFS=','
  for _ts in $1; do
    if [ -n "${_ts}" ]; then
      printf '    - %s\n' "${_ts}"
    fi
  done
  IFS="${_emit_old_ifs}"
}

TOOLSETS_BODY=""
if [ "${SPZ_TOOLSETS}" != "full" ]; then
  # cronjob rides along only on hermes-manager, scoped by the same dedicated flag
  # that scopes the poll itself rather than by a service-name check. It is the one
  # service where "change how often you poll" is a real thing to ask an agent,
  # because it is the only one that owns a schedule worth changing.
  SPZ_DISCORD_TOOLSETS="${SPZ_TOOLSETS}"
  if [ -n "${SPZ_CONTENT_OPS_POLL:-${CONTENT_OPS_POLL_ENABLED}}" ]; then
    SPZ_DISCORD_TOOLSETS="${SPZ_DISCORD_TOOLSETS},cronjob"
  fi
  # A value that names no toolsets at all (a stray comma, a half-finished Railway
  # edit) must not reach the file. Emitting a bare `discord:` gives it a null
  # value, and _get_platform_tools treats a non-list as unconfigured and hands
  # back the full bundle — so the saving quietly disappears while the boot log
  # still says the toolsets were scoped. Fail open the same way, but say so.
  DISCORD_TOOLSETS_YAML="$(emit_toolset_list "${SPZ_DISCORD_TOOLSETS}")"
  if [ -n "${DISCORD_TOOLSETS_YAML}" ]; then
    TOOLSETS_BODY="  discord:
${DISCORD_TOOLSETS_YAML}"
  else
    echo "[spz-boot] Warning: SPZ_TOOLSETS names no toolsets (${SPZ_TOOLSETS}); leaving discord on the framework default"
  fi
fi
if [ "${SPZ_CRON_TOOLSETS}" != "full" ]; then
  # cron is its own platform key with its own default (hermes-cron), so narrowing
  # discord alone would leave every scheduled turn — including the hourly
  # content-ops poll, the most frequent recurring cost on this fleet — still
  # paying for the full bundle.
  CRON_TOOLSETS_LIST="$(emit_toolset_list "${SPZ_CRON_TOOLSETS}")"
  if [ -z "${CRON_TOOLSETS_LIST}" ]; then
    echo "[spz-boot] Warning: SPZ_CRON_TOOLSETS names no toolsets (${SPZ_CRON_TOOLSETS}); leaving cron on the framework default"
  else
    CRON_TOOLSETS_YAML="  cron:
${CRON_TOOLSETS_LIST}"
    if [ -n "${TOOLSETS_BODY}" ]; then
      TOOLSETS_BODY="${TOOLSETS_BODY}
${CRON_TOOLSETS_YAML}"
    else
      TOOLSETS_BODY="${CRON_TOOLSETS_YAML}"
    fi
  fi
fi
if [ -n "${TOOLSETS_BODY}" ]; then
  TOOLSETS_BLOCK="platform_toolsets:
${TOOLSETS_BODY}
"
  echo "[spz-boot] Toolsets scoped (discord=${SPZ_DISCORD_TOOLSETS:-full}, cron=${SPZ_CRON_TOOLSETS})"
else
  TOOLSETS_BLOCK=""
fi

# Fork-local skills, shipped in the image rather than written to the volume.
#
# `skills.external_dirs` (agent/skill_utils.py:420) takes a list of read-only
# directories scanned alongside $HERMES_HOME/skills. Shipping them this way is
# deliberate on all three counts:
#
#   - IN THE IMAGE, not the volume. A skill written into $HERMES_HOME/skills is
#     writable by the agent's own skill_manage tool and survives redeploys, so a
#     model edit silently outlives the commit that was supposed to define it.
#     An external dir is read-only to the framework, version-controlled here,
#     and replaced wholesale by the next deploy.
#   - NO Dockerfile CHANGE. `COPY --link . .` already lands the whole repo at
#     /opt/hermes, so a new top-level directory ships for free. That matters
#     because Dockerfile is one of the four files an upstream merge can
#     conflict on; this adds nothing to that surface.
#   - CHEAP PER CALL. build_skills_system_prompt (agent/prompt_builder.py:1445)
#     puts only each skill's name and description in the system prompt; the body
#     loads on demand through skill_view. A reference file costs nothing until
#     it is read.
#
# Resolved from $0 so the same line works in the container (invoked as
# `sh /opt/hermes/docker/spz-boot.sh`, giving /opt/hermes) and in the local
# harness (invoked as `sh docker/spz-boot.sh`, giving the repo root). It must be
# ABSOLUTE: get_external_skills_dirs resolves a relative entry against
# HERMES_HOME, not the working directory, so a relative path would point into
# the volume and find nothing. `cd && pwd` is the POSIX way to absolutize.
#
# Gated on the directory actually existing, because a missing external dir is
# skipped with a debug-level log and nothing else — an emitted path that does
# not resolve is the silent-failure shape this file keeps running into, so it is
# better to say so at boot. `SPZ_SKILLS_DIR=none` disables the block entirely,
# the same escape hatch shape as SPZ_RELAY_CHANNELS=none.
SPZ_SKILLS_DIR="${SPZ_SKILLS_DIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/spz-skills}"
if [ "${SPZ_SKILLS_DIR}" = "none" ]; then
  SKILLS_BLOCK=""
  echo "[spz-boot] Fork skills disabled (SPZ_SKILLS_DIR=none)"
elif [ -d "${SPZ_SKILLS_DIR}" ]; then
  # Quoted: a path is a string, and an unquoted one with a stray colon or a
  # leading digit is the YAML 1.1 coercion trap this file documents elsewhere.
  SKILLS_BLOCK="skills:
  external_dirs:
    - \"${SPZ_SKILLS_DIR}\"
"
  echo "[spz-boot] Fork skills dir: ${SPZ_SKILLS_DIR}"
else
  SKILLS_BLOCK=""
  echo "[spz-boot] WARNING: skills dir ${SPZ_SKILLS_DIR} not found - fork skills will be absent"
fi

# The model block is a MAPPING, not the bare string this file emitted until an
# OPENAI_API_KEY took the whole fleet down.
#
# `provider` is the load-bearing key. With no provider pinned anywhere, the
# framework auto-detects one, and the precedence in hermes_cli/auth.py (the
# comment at ~1705 spells it out) is: 2. config.yaml model.provider, 3. the
# OPENAI/OPENROUTER env keys, 5. provider-specific env keys. So OPENAI_API_KEY
# outranks ANTHROPIC_API_KEY and returns "openrouter" — and with no
# OPENROUTER_API_KEY set, every request goes out with no Authorization header
# and OpenRouter answers `401 Missing Authentication header`. Setting the key
# that voice needs silently repointed inference at a provider with no
# credentials, and because the chat error is sanitized to "Provider
# authentication failed", it reads as a bad Anthropic key. It is not: rotating
# ANTHROPIC_API_KEY cannot fix it, because Anthropic is never called.
#
# Step 2 above is the fix, and it only exists for a mapping — `isinstance(cfg,
# dict)` is False for a bare string, so the string form this file used could
# never pin a provider at all. Emitting the mapping restores exactly the
# pre-voice behaviour, since auto-detect previously fell through to the
# ANTHROPIC_API_KEY branch and chose anthropic anyway.
#
# SPZ_INFERENCE_PROVIDER exists only as the escape hatch for genuinely moving
# off Anthropic; leave it unset. HERMES_INFERENCE_PROVIDER does NOT override it,
# despite what this comment claimed until now: resolve_requested_provider
# (runtime_provider.py:535-551) reads config.yaml model.provider BEFORE the env
# var, and this script always writes model.provider — so the env var is dead on
# this deployment and reaching for it during an outage would waste the outage.
# The claim was written the same day the pin was added and was wrong from the
# moment it landed; the pin is exactly what invalidated it.
#
# THE DEFAULT IS HAIKU, not Sonnet. The agent's whole job here is reading the
# dashboard over MCP and answering in #spz — 16 MCP tools plus a scoped native
# set, well inside Haiku's 200k window — and Haiku 4.5 still uses the OLD
# tokenizer, while Sonnet 5 and every other 4.7+ model count roughly 30% more
# tokens for the same text. So the real gap is nearer 2.6x than the 2x the
# published rates suggest, and it is paid on every cron firing whether or not
# anyone is listening.
#
# What this gives up is stated plainly because it is not nothing: a free-typed
# "YES 1234" in #approvals is resolved by the AGENT — list_pending_approvals,
# match the code, then resolve_pending_approval, which executes the original
# action — and that two-step exact-match chain is where a smaller model degrades
# first. The Discord buttons resolve the same approval deterministically with no
# model involved, so that path is unaffected. If the free-typed path ever picks
# a wrong code, the fix is a channel_overrides block pinning a stronger model on
# #approvals alone (gateway/run.py:3747-3782, priority: session /model >
# channel override > this default) rather than reverting the whole service.
#
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
model:
  default: "${HERMES_MODEL:-anthropic/claude-haiku-4-5}"
  provider: "${SPZ_INFERENCE_PROVIDER:-anthropic}"
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
${VOICE_BLOCK}${TOOLSETS_BLOCK}${SKILLS_BLOCK}${PLATFORMS_BLOCK}
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
# Removals run UNCONDITIONALLY, outside the enable check below — the same shape
# the content-ops poll uses further down, and for the same reason it had to be
# given one. Cron jobs live in $HERMES_HOME, which is the Railway volume, so
# they survive every redeploy. Nested inside the `if`, unsetting
# SPZ_ROUNDUP_ENABLED only stopped the job being RECREATED and did nothing
# about the one already there, which would keep posting a 12PM roundup into
# #spz after its own switch was gone. That is not a hypothetical for this file:
# it is exactly what happened to spz-content-ops-poll, and this block was the
# last one still carrying the bug once that one was fixed.
#
# The two legacy names are one-time migrations, not manual steps. Each
# superseded name has to be removed explicitly, because the name check below
# only ever asks whether the CURRENT name exists — an old job it doesn't know
# about would sit there forever, still firing on its old schedule and delivery.
# `daily-roundup` was the SMS-era job; `daily-roundup-discord` is the
# pre-SPZ-naming one, which is otherwise a live duplicate that would post the
# roundup twice.
#
# Removing is safe to attempt on every boot — once gone the command just fails
# and is suppressed. `hermes cron remove` resolves by name as well as id
# (cron/jobs.py resolve_job_ref), so no id lookup is needed.
hermes cron remove daily-roundup >/dev/null 2>&1 || true
hermes cron remove daily-roundup-discord >/dev/null 2>&1 || true
if [ -z "${SPZ_ROUNDUP_GUARD}" ]; then
  hermes cron remove spz-daily-roundup >/dev/null 2>&1 || true
fi

if [ -n "${SPZ_ROUNDUP_GUARD}" ]; then
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
# system prompt, SOUL.md, the Hermes core toolset and the whole spz MCP schema
# block are re-sent on the first round trip, and the prompt below loops
# approve_video + scan_video over every pending video.
#
# The MCP half of that is the biggest single item and is worth measuring rather
# than guessing, because it has grown: this comment said "~19 MCP tool schemas"
# until a recount put it at 41 tools and roughly 5,100 tokens -- 28 dynamic from
# TOOLS in api/_lib/spzAgent.ts at ~2,700, plus 12 static registerTool blocks in
# api/mcp.ts at ~2,400. scan_video alone is ~440 and submit_video ~374. Re-derive
# it rather than trusting this number; the dashboard grows tools and nothing on
# this side notices:
#
#   cd ../spz-dashboard && wc -c api/_lib/spzAgent.ts api/mcp.ts   # rough proxy
#
# It cannot be scoped away either. `no_mcp` in a platform_toolsets list drops all
# MCP servers (tools_config.py:1881), but it is all-or-nothing per server and
# this job needs three of them, so a cron turn pays for all 41 to use
# get_pending_videos, approve_video and scan_video. That is the argument for
# widening the interval rather than trimming the turn.
#
# So the floor is roughly 6,800 tokens per firing before any work happens, paid
# 24 times a day whether or not the queue has anything in it -- and it was 48
# times at */30. Hourly halved it; business hours only (0 8-20 * * *) would take
# another 46% off, and the pipeline is unattended, so nothing downstream notices
# the latency. That is a Railway edit, which is why the schedule is a variable.
# Business hours rather than round the clock, since 2026-09-01. Editors upload
# during the day, so the overnight firings were polling a queue that nothing had
# added to since the evening — 11 of the 24 daily firings did the full ~6,800
# token setup to find nothing. 0 8-20 takes 46% off the floor and the pipeline is
# unattended, so nothing downstream notices an hour's latency.
#
# The hours are London, not UTC: `timezone: "Europe/London"` in the generated
# config.yaml is what cron/scheduler.py reads, so this window stays 08:00-20:00
# local across the BST/GMT change without a seasonal edit — the same property the
# 12:00 roundup relies on.
#
# THE DEFAULT ONLY APPLIES IF RAILWAY DOES NOT SET THE VARIABLE. If
# SPZ_CONTENT_OPS_CRON exists there, it wins and this line is never read — check
# Railway before concluding a schedule change did not take. That is the same trap
# HERMES_MODEL has, and it is why the job below is removed and recreated on every
# boot rather than checked by name.
SPZ_CONTENT_OPS_CRON="${SPZ_CONTENT_OPS_CRON:-0 8-20 * * *}"

# Removals run UNCONDITIONALLY, outside the enable check below. This is the
# mirror of the trap this file already documents for renamed jobs, and it bit
# for real: cron jobs live in $HERMES_HOME, which is the Railway volume, so they
# survive every redeploy. With the removals inside the `if`, unsetting
# SPZ_CONTENT_OPS_POLL skipped the whole block — the variable stopped the job
# being RECREATED and did nothing about the one already there, which kept firing
# hourly against a pipeline Vercel had taken over. Turning a feature off has to
# be as reachable as turning it on.
#
# `hermes cron remove` on an absent job just fails and is suppressed, so running
# these on every boot costs nothing when there is nothing to remove.
#
# content-ops-poll is the pre-SPZ-naming job; without its own line it would keep
# polling every 30 minutes alongside its replacement, doubling every
# approve_video/scan_video call on the dashboard side.
hermes cron remove content-ops-poll >/dev/null 2>&1 || true
if [ -z "${SPZ_CONTENT_OPS_POLL:-${CONTENT_OPS_POLL_ENABLED}}" ]; then
  hermes cron remove spz-content-ops-poll >/dev/null 2>&1 || true
fi

if [ -n "${SPZ_CONTENT_OPS_POLL:-${CONTENT_OPS_POLL_ENABLED}}" ]; then

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
