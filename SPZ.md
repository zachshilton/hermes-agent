# SPZ

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
repository. It is loaded through `CLAUDE.md`, which imports it and contains nothing else.

## Read AGENTS.md first

`AGENTS.md` (~1350 lines) is the canonical development guide for this codebase: contribution
rubric, footprint ladder, plugin/skill/toolset internals, prompt-caching policy, profile rules,
known pitfalls, and testing standards. This file is a short orientation layer on top of it —
it does not replace it. `CONTRIBUTING.md` adds the cross-platform (Windows) rules and the
skill-vs-tool decision guide.

## SPZ: a deployment fork, not an upstream dev checkout

This project is **SPZ**. `origin` is `github.com/zachshilton/hermes-agent` (a fork of
NousResearch/Hermes-Agent), deployed on Railway as a single service, `hermes-spz`
(it was briefly one service per persona — see "One container, and the fleet that used to be four" below);
the dashboard and MCP server it talks to (`api/mcp.ts`, `api/discord-inbound.ts`) live in a separate
SPZ repo, checked out beside this one at `../spz-dashboard`. Every claim here about the MCP surface —
the tool count, the deleted approval queue, `submit_video` executing unguarded — is checkable only
there. Refer to the project as SPZ, not Hermes — "Hermes" means the vendored upstream framework.
Every commit unique to this fork touches the same small set of files, and in practice only the
first two are still moving:

- `docker/spz-boot.sh` — Railway start command (`railway.json` → `sh /opt/hermes/docker/spz-boot.sh`).
  Regenerates `$HERMES_HOME/config.yaml` and `SOUL.md` from Railway env vars on **every** container
  start (idempotent by design, always overwrites), creates cron jobs idempotently by name, then
  `exec hermes gateway run`. Every behavioural fork commit is a diff to this file.
- `SPZ.md` (and `CLAUDE.md`, which only imports it) — the fork's own guidance. Four of the last six
  commits touch it, because the reasoning behind a `spz-boot.sh` change does not fit in the shell
  diff. Treat a behaviour change here as incomplete until this file describes it.
- `docker/stage2-hook.sh` — s6-overlay UID remap / `HERMES_HOME` ownership. Settled; last touched
  July 2026, and superseded in practice because Railway's custom start command runs `spz-boot.sh`
  directly as root and bypasses the s6 entrypoint entirely (which is why `spz-boot.sh` does its own
  `chown` at the end).
- `railway.json` — three lines, unchanged since the gateway invocation was first wired up.
- `spz-skills/` — the fork's own skill tree, shipped in the image and named in the generated
  config as `skills.external_dirs`. Prose, not code: it changes what the agent knows rather than
  what the container does, so it is the one entry here that no boot harness can check.
- `Dockerfile` — two lines, both forced by the deployment target rather than chosen.
  `--extra tts-premium` bakes the ElevenLabs SDK in rather than lazy-installing it into an immutable
  layer (see "ElevenLabs" below); and the upstream `VOLUME [ "/opt/data" ]` instruction is
  **deleted**, because Railway's build pipeline rejects any Dockerfile containing one outright and
  tells you to use a Railway Volume instead. Nothing is lost by that deletion — persistence at that
  path comes from a real Railway Volume mounted there at deploy time, not from Docker's own volume
  metadata — but it is the fork hunk most likely to be silently undone by an upstream merge, and it
  fails the *build* rather than degrading at runtime, so it is not subtle when it goes.

The generated `config.yaml` is the whole fork surface at runtime. It contains exactly seven things:
`timezone` (hardcoded `Europe/London`), `model` (a **mapping** of `default` from `${HERMES_MODEL}`,
defaulting to `anthropic/claude-haiku-4-5` — see "Haiku is the default" below — and `provider`
from `${SPZ_INFERENCE_PROVIDER}`,
defaulting to `anthropic` — see "Pin the provider" below; it must not go back to a bare string), a
`display.platforms.discord` block, the single `mcp_servers.spz`
entry built from `SPZ_MCP_URL`/`SPZ_MCP_TOKEN` with `timeout: 180`, a `platform_toolsets` block
scoping what each surface loads, a `skills.external_dirs` list pointing at the fork's own skills
(see "Fork skills" below), and — only when at least one relay channel id is set —
`platforms.discord.extra.channel_prompts`. An `stt`/`tts` pair appears as an eighth only when a
voice key is present.

**This fork contains almost no Python, and adding more is a last resort.** The working convention,
stated explicitly in the commit messages, is to reach for existing framework config before
customizing core. Examples: the Discord per-persona relay is
`platforms.discord.extra.channel_prompts` (read by `resolve_channel_prompt` in
`gateway/platforms/base.py`), not a forwarding endpoint; the daily roundup is a
`hermes cron create --deliver discord` job, not code. Prefer the same route — if a change can be
made in generated `config.yaml` or env vars, do it there.

There are exactly **two** Python exceptions, and the bar they had to clear is the point:

1. Two settings in `gateway/run.py` controlling what a spoken turn writes into the text channel (see
   "Keeping a voice conversation in the voice channel"). Taken only after confirming no config path
   existed — both behaviours were unconditional, and the agent has no tool that could route output
   to chat itself.
2. Two additions in `tools/tts_tool.py`, both closing gaps where a delivery control existed in the
   provider's API but not in the framework: an `instructions` field for OpenAI TTS (style steering
   the `gpt-4o*-tts` models accept), and `voice_settings.speed` for ElevenLabs. The latter matters
   more than it sounds — ElevenLabs carries rate on `voice_settings` rather than as a top-level
   argument, so `_generate_elevenlabs` sent no rate at all and a slow-reading voice could not be
   sped up by any means.

Anything added here should meet the same test — no config path exists *and* the behaviour is
actually wrong — and follow the same shape: read from `config.yaml`, default to the framework's
existing behaviour, and keep the diff to hunks that are trivial to re-apply over an upstream merge.

### How an upstream merge would be done, and why none ever has been

That "trivial to re-apply" is a claim about an operation nobody here has performed, against
machinery that does not exist yet. `git log --merges` is empty across every commit on `main`. No
commit total is quoted for it, deliberately: the emptiness is the claim, and any count of commits is
stale the moment the next one lands — including the commit that writes the count down. `git remote
-v` lists exactly one remote — `origin`, this fork. **There is no `upstream` remote
configured**, so the first step is to make one:

```bash
git fetch --unshallow origin     # do this FIRST — see below
git remote add upstream https://github.com/NousResearch/Hermes-Agent.git
git fetch upstream
```

**The `--unshallow` is not optional, and it is the part that is invisible until it bites.** This
working copy is a shallow clone: `git rev-parse --is-shallow-repository` answers `true`, and
`.git/shallow` grafts the history at `3a1a3c7` ("add 5.6 (#61578)", rob-maron), which is why
`git log` presents a 6205-file upstream snapshot as a parentless root commit rather than as one
commit in a long upstream history. Nothing before that graft exists locally, so a three-way merge
would be looking for a merge base in a history this repo does not have. Unshallow and the graft goes
away; skip it and the failure surfaces as a merge that either refuses outright or resolves against
the wrong base — neither a thing to start debugging at that moment. Note also that `origin`'s
refspec is `+refs/heads/main:refs/remotes/origin/main`, `main` alone, so `upstream` needs its own
fetch regardless.

**The graft commit is not the fork point, and diffing against it is the mistake this section used to
invite.** Seven upstream commits follow `3a1a3c7` — the GPT-5.6 registration series, authored by
Kshitij Kapoor and rob-maron, touching `agent/model_metadata.py`, `agent/usage_pricing.py`, four
files under `hermes_cli/`, two under `tests/hermes_cli/`, and `website/static/api/model-catalog.json`.
None of it is ours. **The true fork point is `111544d`**, the last commit not authored by Zach
Shilton, and `git log --format='%h %an' | grep -v 'Zach Shilton' | head -1` is how to re-derive it
after the next upstream catch-up rather than trusting this hash forever. The difference is not
cosmetic:

| Baseline | Reports | Verdict |
|---|---|---|
| `git diff 3a1a3c7 HEAD` | 20 files | Wrong — sweeps in ten files of pure upstream work |
| `git diff 111544d HEAD` | 9 files | The fork's own surface, but measured over a set that includes this file |
| the same, plus `-- . ':(exclude)SPZ.md' ':(exclude)CLAUDE.md'` | 20 files, 2264 insertions, 10 deletions | The code surface, and the only row here that holds still |

Run the first one unrestricted and `usage_pricing.py`, `models.py` and the model catalog look
fork-touched; re-applying those over a merge would be re-applying upstream's own commits back on top
of upstream. The four-path figure below survives the correction — `git diff` over those paths is
byte-identical from either baseline, because none of the seven commits touched them — but the
*habit* of reaching for `3a1a3c7` does not.

**A total that counts `SPZ.md` can never be right at rest, because writing the number changes the
number.** The first two rows carry file counts only for that reason. Their insertion totals read
2003, then 2105, then 2131 — each recount dated by its own edit, by exactly the lines that edit
added, and each one true for about the length of one commit. That is not drift to be corrected
again; it is the wrong thing to measure. The third row is the way out: a pathspec excluding this
file and `CLAUDE.md` measures the code alone, so it moves only when code moves, and it is the only
figure here worth quoting. Re-run `git diff --stat` rather than trusting even that one, the same way
the fork point above is re-derived rather than remembered; the shape of the claim — which files can
conflict, and that the Python half is eight small hunks — is what is meant to survive, not the
arithmetic.

**The conflict surface is much smaller than the fork-touched list above suggests, and which half a
file falls into follows entirely from who added it.** A file this fork created has no upstream
counterpart to disagree with, so it can never conflict however large it grows; only a file that
arrived in the upstream snapshot and was subsequently edited here can. `git log --diff-filter=A
--oneline -- <path>` settles it per file, and the split is clean:

| Fork-touched file | Added by | Can conflict? |
|---|---|---|
| `docker/spz-boot.sh` | this fork (`299a14c`) | No — fork-only, and 932 lines of it |
| `SPZ.md` | this fork (`3af59e8`) | No |
| `CLAUDE.md` | this fork (`331da16`) | No |
| `railway.json` | this fork (`a166836`) | No |
| `spz-skills/` | this fork | No — fork-only, and upstream has no such path |
| `Dockerfile` | upstream root (`3a1a3c7`) | **Yes** |
| `docker/stage2-hook.sh` | upstream root (`3a1a3c7`) | **Yes** |
| `gateway/run.py` | upstream root (`3a1a3c7`) | **Yes** |
| `tools/tts_tool.py` | upstream root (`3a1a3c7`) | **Yes** |
| `.gitignore` | upstream root (`3a1a3c7`) | **Yes** — three lines, ignoring `.claude/` |

That is a better result than it looks. The one file every behavioural fork commit touches —
`spz-boot.sh`, the largest and by far the most edited thing here — sits in the half that cannot
conflict at all, and so does this file. The entire conflictable surface is `git diff 111544d HEAD`
over the five paths marked **Yes** above: **12 hunks, 184 insertions and 10 deletions**, of which
the `Dockerfile` (the `--extra` line and the deleted `VOLUME`) and `stage2-hook.sh` (the chown
safety net) halves are
both settled and in code upstream is unlikely to be moving. Watch the `VOLUME` deletion specifically:
it is the one hunk a merge can undo by *restoring* a line rather than by clobbering one of ours,
which no conflict marker will point at.

**That figure stood at 11 and 181 for one commit, and how it got there matters more than the
number.** It was written as a correction, with the earlier 12 and 184 dismissed in passing as "a
miscount, not drift" — but the two counts were never measuring the same thing. 11 and 181 is this
diff over *four* paths, silently dropping `.gitignore`, which the table above marks conflictable and
which contributes exactly the missing hunk and the missing three insertions. Nothing had drifted and
nothing was miscounted: the pathspec narrowed, the prose kept saying "four" while the table went on
saying five, and the arithmetic was impeccable on both sides of the disagreement. That is the
failure mode this whole section is written against, and it is worse than a stale number — a stale
number is at least wrong about something checkable. **So re-derive the pathspec from the table, not
just the figure**, and note that the hunk count is context-dependent (`-U0` reports 13, not 12):

```bash
git diff --stat 111544d HEAD -- Dockerfile docker/stage2-hook.sh gateway/run.py tools/tts_tool.py .gitignore
```

**So re-applying the two Python changes by hand is the expected outcome of a merge, not a sign one
went wrong.** That is precisely why the bar above is set where it is, and why each change is shaped
as a small helper plus call sites reading from `config.yaml` rather than as a rewrite of the
function around it: take upstream's copy of `gateway/run.py` and `tools/tts_tool.py` wholesale
(`git checkout --theirs`), then re-apply eight hunks you can read on one screen. Resolving a
conflict *inside* upstream's own logic is the slower and more dangerous route, and nothing in those
eight hunks is worth it.

**None of this has been rehearsed.** With no merge ever having run, the first one is a diff against
6205 upstream files rather than the routine catch-up the phrase "upstream merge" implies — budget
for it as an exercise, and remember that `docker/spz-boot.sh` comes out of it with no test coverage
either way (see "Verifying a `spz-boot.sh` change — nothing else does" below, which is the only
thing that would catch a merge having broken it).

### Naming: `SPZ_` is for us, `DISCORD_*`/`HERMES_*` belong to the framework

Every variable `spz-boot.sh` alone consumes carries an `SPZ_` prefix: `SPZ_MCP_URL`,
`SPZ_MCP_TOKEN`, `SPZ_SOUL_MD`, `SPZ_CHANNEL_{TRAINER,CLINIC,MANAGER,CLZ,HOME,APPROVALS}`,
`SPZ_ROUNDUP_ENABLED`, `SPZ_CONTENT_OPS_POLL`, `SPZ_CONTENT_OPS_CRON`, `SPZ_ROLE`,
`SPZ_PERSONA_CHANNEL`,
`SPZ_RELAY_CHANNELS`, `SPZ_SKILLS_DIR`, `SPZ_STT_PROVIDER`, `SPZ_TTS_PROVIDER`, `SPZ_TTS_VOICE`,
`SPZ_TTS_MODEL`.
Cron jobs follow suit: `spz-daily-roundup`, `spz-content-ops-poll`.

The names that stay upstream-spelled do so because the framework reads them, and renaming one fails
silently — nothing errors, the adapter just never sees the value:

| Variable | Framework consumer |
|---|---|
| `DISCORD_ALLOWED_USERS` | `gateway/authz_mixin.py`, `gateway/pairing.py` |
| `DISCORD_FREE_RESPONSE_CHANNELS`, `DISCORD_REQUIRE_MENTION`, `DISCORD_ALLOWED_CHANNELS` | `plugins/platforms/discord/adapter.py` |
| `DISCORD_HOME_CHANNEL` | `cron/scheduler.py`, `gateway/config.py` |
| `HERMES_MODEL` | `cron/scheduler.py` (per-job override > env) |
| `HERMES_HOME` | core, everywhere |

Check for a consumer before renaming anything else. Each `SPZ_` name currently falls back to its
pre-rename name, so boots survive a redeploy that lands before the Railway variables are updated —
drop the fallbacks once Railway is renamed. The pairs are not all guessable, so before deleting an
old Railway variable check which new name still reads it:

| `SPZ_` name | Falls back to |
|---|---|
| `SPZ_ROUNDUP_ENABLED` | `DISCORD_ALLOWED_USERS` (honoured only when `SPZ_ROLE` is `spz`) |
| `SPZ_CONTENT_OPS_POLL` | `CONTENT_OPS_POLL_ENABLED` |
| `SPZ_CHANNEL_{TRAINER,CLINIC,MANAGER,CLZ}` | `DISCORD_CHANNEL_{TRAINER,CLINIC,MANAGER,CLZ}` |
| `SPZ_CHANNEL_HOME` | `DISCORD_CHANNEL_SPZ` — **not** `DISCORD_CHANNEL_HOME` |
| `SPZ_CHANNEL_APPROVALS` | `DISCORD_CHANNEL_APPROVALS` |

Four conventions in `spz-boot.sh`, each of which has caused a silent failure:

- **Instances are scoped by which env var Railway sets**, not a service-name check:
  `SPZ_ROUNDUP_ENABLED` and `SPZ_CONTENT_OPS_POLL` both ⇒ `hermes-spz`, which since the collapse is
  the only service — but the rule outlives the fleet and must be kept. These are
  dedicated flags precisely because the previous approach — piggybacking on whichever credential
  happened to be unique to a service — broke twice, as `SMS_ALLOWED_USERS` and then
  `DISCORD_ALLOWED_USERS` were retired and took the roundup cron with them.
- **Renaming a cron job needs a removal line.** The existence check only asks whether the *current*
  name is present, so a superseded job keeps running on its old schedule forever. `spz-boot.sh`
  removes `daily-roundup`, `daily-roundup-discord` and `content-ops-poll` on every boot.
- **A removal line has to live OUTSIDE the enable check**, or the feature cannot be turned off.
  Cron jobs are stored in `$HERMES_HOME`, which is the Railway volume, so they survive every
  redeploy. With the removals nested inside `if [ -n "${SPZ_CONTENT_OPS_POLL}" ]`, unsetting that
  variable skipped the whole block: it stopped the job being *recreated* and did nothing about the
  one already there, which kept firing hourly against a pipeline the dashboard had taken over. This
  is not hypothetical — it happened, and the symptom was a poll that survived the removal of its own
  switch. `hermes cron remove` on an absent job fails harmlessly, so an unconditional removal costs
  nothing. **`spz-daily-roundup` was the last block still carrying this shape, and no longer is**:
  the two legacy-name removals now run unconditionally, and a separate
  `if [ -z "${SPZ_ROUNDUP_GUARD}" ]` removes `spz-daily-roundup` itself when the switch is off —
  the content-ops poll's shape exactly, arrived at the same way. Verified with the harness below:
  boot once with `SPZ_ROUNDUP_ENABLED` set, then again with it (and `DISCORD_ALLOWED_USERS`, which
  it still falls back to) unset, and the second boot logs `hermes cron remove spz-daily-roundup`,
  leaving the poll as the only job. The rule stays stated as a rule because it governs the next
  block added here, not because anything is still outstanding.
- **Anything YAML 1.1 would coerce must stay quoted** in the emitted config, because it is read with
  `yaml.safe_load`. Two live instances, both of which failed silently: Discord channel ids unquoted
  parse as ints, and every `channel_prompts` lookup (which keys on the adapter's string id) misses;
  and `tool_progress: off` unquoted is the boolean `False`, while the resolver compares against the
  string `"off"` — so the setting reads as valid and does nothing. Assume the next scalar you add is
  a third one.

### The Discord display block, and why it is per-platform

`spz-boot.sh` emits four `display.platforms.discord` settings — `tool_progress: "off"`,
`interim_assistant_messages: false`, `long_running_notifications: false`, `busy_ack_detail: false`.
Discord is the framework's most verbose display tier by default (`_TIER_HIGH` in
`gateway/display_config.py`), and with no display block the persona channels narrated the relay they
exist to hide: a `⚙️ mcp__spz__instruct_trainer` bubble, any preamble SPZ emitted alongside the tool
call as its own message, a `⏳ Working` heartbeat, none of it cleaned up. These four leave the
channel showing the question and the answer.

Display settings resolve on the **platform** key alone — `ChannelOverride` carries only
model/provider/system_prompt, so there is no per-channel layer to hang them on. That means this
quietens `#spz` too, which is accepted rather than desired. Don't try to scope it per channel
without first adding that layer upstream.

### Pin the provider, or a voice key takes the fleet down

`model` is emitted as a mapping with an explicit `provider`, and that key is load-bearing. This is
the one outage this fork has caused itself, so it is worth stating exactly.

With no provider pinned anywhere, the framework auto-detects one. The precedence is spelled out in
a comment in `hermes_cli/auth.py` (~line 1718, with the full ladder in the docstring at
1636-1643): **2.** `config.yaml` `model.provider`, **3.** the
`OPENAI_API_KEY`/`OPENROUTER_API_KEY` env keys, **5.** provider-specific env keys. So
`OPENAI_API_KEY` **outranks** `ANTHROPIC_API_KEY` and returns `openrouter`. With no
`OPENROUTER_API_KEY` set, every request then goes out with no Authorization header, and OpenRouter
answers `401 Missing Authentication header`.

That is exactly what setting `OPENAI_API_KEY` for voice did. Inference silently repointed at a
provider with no credentials, and because `_gateway_provider_error_reply` sanitizes the chat reply to
"Provider authentication failed", it reads as a bad Anthropic key. **It is not** — rotating
`ANTHROPIC_API_KEY` cannot fix it, because Anthropic is never called. Two rotations were spent
before the real error surfaced in the logs.

Step 2 above is the fix, and it only works for a **mapping**: `isinstance(cfg, dict)` is `False` for
a bare string, so the string form this file used until then could never pin a provider at all.
Emitting the mapping restores exactly the pre-voice behaviour, because auto-detect used to fall
through to the `ANTHROPIC_API_KEY` branch and pick `anthropic` anyway. Verified both ways against a
generated config with `OPENAI_API_KEY` set: the bare string resolves to `openrouter`, the mapping to
`anthropic`.

Two consequences worth keeping:

- **Any service that gets a voice key needs this**, which today means the only one — but the pin
  belongs in the generated config rather than a per-service Railway variable, so that it survives
  ever splitting out again.
- **`HERMES_INFERENCE_PROVIDER` does NOT override it, despite what this file used to say.**
  `resolve_requested_provider` (`runtime_provider.py:535-551`) reads config.yaml `model.provider`
  *before* the env var, and this script now always writes `model.provider` — so the env var is dead
  on this deployment and reaching for it in an outage would waste the outage. The earlier claim was
  written the same day the pin was added and was wrong from the moment it landed: the pin is exactly
  what invalidated it.
- **`SPZ_INFERENCE_PROVIDER` is the real lever**, since it is what `model.provider` is generated
  from. Changing provider means setting it *and* `HERMES_MODEL` to a model id spelled the way that
  provider expects — `hermes_cli/model_normalize.py:327-467` requires a `vendor/` prefix for
  aggregators (`openrouter`, `nous`) and strips it for `anthropic`. A mismatch 404s on the first
  message rather than failing at boot, which is the same shape as putting a voice name in
  `SPZ_TTS_MODEL`.

### Haiku is the default, and what that trades away

`HERMES_MODEL` defaults to `anthropic/claude-haiku-4-5`, not Sonnet. The agent's whole job on this
deployment is reading the dashboard over MCP and answering in `#spz`: 41 MCP tools plus the scoped
native set, nowhere near Haiku's 200k window, and none of it needs a frontier model to dispatch.

**Count the tools, not the `registerTool` calls — and re-count them rather than quoting this
number.** It said 16 for a long time, which is the number of call sites in the dashboard repo's
`api/mcp.ts` — but one of them sits inside a `for (const schema of TOOL_SCHEMAS)` loop that
registers every entry of `TOOLS` in `api/_lib/spzAgent.ts`. Correcting that gave 13 static + 25
dynamic = 38, which was true when it was written and is **wrong now**: `TOOLS` has since grown three
finance tools (`get_account_balances`, `search_transactions`, `get_spend_by_category`), so the real
exposure is 13 + 28 = **41**. It was 15 + 25 = 40 before that, until `list_pending_approvals` and
`resolve_pending_approval` went with the approval queue. The ~4k-token figure for the schema block
was measured at 25 dynamic tools and has not been re-measured since; treat it as a floor.

The number moves whenever the dashboard ships a tool, and nothing on this side notices — which is
why the two commands matter more than the figure. Both are cheap now that `../spz-dashboard` is
checked out beside this repo:

```bash
cd ../spz-dashboard
grep -c 'registerTool(' api/mcp.ts    # minus 1: one site IS the TOOL_SCHEMAS loop
grep -c "^    name: '" api/_lib/spzAgent.ts  # TOOLS is the file's only such array
```

The economics are better than the published rates suggest, for a reason that is not on any pricing
page. **Haiku 4.5 still uses the OLD tokenizer.** Sonnet 5 — and every other Claude 4.7-or-later
model — counts roughly 30% more tokens for the same text, so Sonnet's effective rate on this
workload is nearer `$2.60/$13.00` than the published `$2/$10`. Against Haiku's `$1/$5` that makes
the real gap about **2.6x, not 2x**, and it is paid on every cron firing whether or not anyone is
listening. Cache reads are half the price too (`$0.10` against `$0.20`).

One thing genuinely moves the other way: **Haiku's hidden tool-use preamble is larger** — Anthropic
bills roughly 496 tokens on Haiku 4.5 against 354 on Sonnet 5 with `tool_choice: auto` (588 against
474 with `any`), on top of our own schemas. It rides every call and claws a little back. Haiku is
still clearly cheaper; it is just not the full 2.6x.

**What this gives up changed shape when the approval queue was removed, and it got bigger.** This
section used to name one path: a free-typed `YES 1234` in `#approvals`, where the AGENT — not the
dashboard — called `list_pending_approvals`, matched the code, then called
`resolve_pending_approval`, whose own description said approving *executes the original action*. A
two-step chain ending in an exact-match argument with an irreversible consequence is precisely where
a smaller model degrades first. That path is gone.

**So are both of the things this file said contained it.** The Discord Approve/Deny buttons
(`api/discord-interactions.ts` in the dashboard repo) resolved an approval deterministically with no
model involved at all — that route is deleted outright. And `reject_video`, `submit_video` and
`mark_posted` sat in `MANAGER_ALWAYS_GATED`, so no model could take a destructive action
unilaterally — that set is deleted too, along with `UNGATED_SPZ_TOOLS` and the whole gate. **Every
MCP tool now executes the moment the agent calls it**, `submit_video` — a real, irreversible OneUp
publish — included.

The exposure is therefore no longer picking the wrong code out of several pending approvals. It is a
wrong `submit_video`, with nothing behind it: the tool schema and whichever model `HERMES_MODEL`
names are the only things in front of an irreversible publish. That is a stronger argument for
revisiting this default than anything this section carried before. It is written down rather than
acted on because the cost case below is unchanged and the choice is Zach's — but the risk half of
the trade is materially worse than it was when Haiku was chosen, and nothing here should read as
though it still balances the way it did.

**If it does take a wrong action, the lever is a channel override, not a service revert.** A
`platforms.discord.channel_overrides.<spz-id>.model` block pins a stronger model on `#spz` alone.
That is live, not aspirational — `gateway/run.py:3747-3782` looks the override up by chat id and
applies it, priority `session /model` > channel override > this default — and
`gateway/config.py:404-419` confirms `ChannelOverride` carries exactly model/provider/system_prompt.
Two limits, and the first is new: `#spz` is now the only channel SPZ converses in, so an override
there is close to service-wide rather than the narrow scalpel `#approvals` used to be. And it cannot
help a **cron** turn at all — those are not channel-scoped and always take the service-wide model,
so the daily roundup is composed by whatever `HERMES_MODEL` says.

**Changing the default in this file only moves the fallback.** If Railway has `HERMES_MODEL` set
explicitly, that wins and the default is never read — check the variable before concluding a model
change did not take.

### Scoping the toolsets, and why it is the biggest cost lever here

Claude spend is a standing constraint on this deployment, and the largest thing driving it was not
the model or the cron frequency — it was the tool schema block re-sent on **every** API call.

With no `platform_toolsets` key, `_get_platform_tools` (`hermes_cli/tools_config.py`) falls back to
the platform default: `hermes-discord` for an adapter turn, `hermes-cron` for a scheduled one. Both
resolve to a 51-tool bundle that serialises to **~9.8k tokens** measured on a machine with no API
keys, and more on Railway where the keys gating the browser, web, image and vision tools are
present. This fleet opens almost none of it — there is no repo on the container to read or patch,
no browser, nothing to shell out to, and the kanban tools address a dashboard the agent already
reaches over MCP. So `spz-boot.sh` emits two narrow lists:

| Variable | Default | Resolves to |
|---|---|---|
| `SPZ_TOOLSETS` | `discord,clarify,memory,session_search,todo,skills` | 7 tools, ~4.4k tokens (was ~9.8k) |
| `SPZ_CRON_TOOLSETS` | `clarify,memory,todo` | 3 tools, ~1.5k tokens (was ~9.8k) |

`cronjob` is appended to the Discord list only where `SPZ_CONTENT_OPS_POLL` is set — the service
owning a schedule worth asking an agent to change, which is now `hermes-spz` and both crons. The literal `full` on
either variable omits that key entirely and restores the framework default; that is the way back
without a code change if an agent turns out to need something cut here.

Three things that make this safe, each of which would otherwise look like a bug:

- **MCP tools are never at risk.** `_get_platform_tools` unions every globally-enabled MCP server
  back in unless the list names one explicitly or carries the `no_mcp` sentinel. Scoping the native
  side leaves the whole `spz` dashboard surface intact — which is the only surface these agents
  actually use, and the reason the lists can afford to be this short.
- **`cron` is its own platform key** with its own default. Narrowing `discord` alone would leave
  every scheduled turn — including the hourly content-ops poll, the most frequent recurring cost on
  this fleet — still paying for the full bundle. That one is the bigger saving of the two.
- **`kanban` still appears** in the resolved list and is *not* a mistake. It is not in
  `CONFIGURABLE_TOOLSETS`, so `platform_toolsets` cannot exclude it; it is gated by a `check_fn`
  (`_check_kanban_mode`) instead, which fails here, so it contributes no schema. Don't try to remove
  it from the list — it was never read from there.

Two related levers deliberately **not** taken. `prompt_caching.cache_ttl: 1h` is available and
tempting, since every cron firing starts a fresh conversation and the default `5m` is always cold by
then — but the 1h tier costs 2× on write against 1.25×, and an hourly poll sits exactly on the
boundary, so it could cost more rather than less. And a per-cron model override is simply not
reachable from here: `hermes cron create` has no `--model` flag (it is absent from both
`hermes_cli/subcommands/cron.py` and `cron_create`'s argument pass-through), and only the agent's
own `cronjob` tool can write one. The lever that does exist is `HERMES_MODEL` per Railway service,
which crons honour — but it is service-wide, so a cheap model on `hermes-spz` also makes the
interactive `#spz` agent cheap.

### Fork skills, and the two caps that make or break one

`spz-skills/` is the fork's own skill tree, shipped in the image and named in the generated
`config.yaml` as `skills.external_dirs`. It currently holds one skill, `finance/zach-finances`,
covering Zach's money — what the three MCP finance tools can and cannot see, plus his personal,
sole-trader and VAT position.

Three properties, each chosen against a specific alternative:

- **In the image, not on the volume.** A skill written to `$HERMES_HOME/skills` is writable by the
  agent's own `skill_manage` tool and survives every redeploy, so a model edit silently outlives the
  commit meant to define it. An external dir is read-only to the framework, version-controlled here,
  and replaced wholesale by the next deploy.
- **No Dockerfile change.** `COPY --link . .` already lands the whole repo at `/opt/hermes`, so a new
  top-level directory ships for free — which matters because `Dockerfile` is one of the paths an
  upstream merge can conflict on, and this adds nothing to that surface.
- **Config, not Python.** `skills.external_dirs` is read by `get_external_skills_dirs`
  (`agent/skill_utils.py:420`), so this clears the bar in "This fork contains almost no Python"
  without going near it.

**The layout is load-bearing and fails silently if you get it wrong.** Category is
`parts[0]` of the path relative to the external dir, and only when there are at least three parts
(`tools/skills_tool.py:565-583`) — so it must be
`<external_dir>/<category>/<skill-name>/SKILL.md`. Put `SKILL.md` one level shallower and the skill
still loads with no category. A `references/` subdirectory is excluded from discovery as a support
dir (`iter_skill_index_files`), which is exactly what makes progressive disclosure work: the body
loads on demand through `skill_view`, so a reference file costs nothing until it is read.

**Two caps decide whether any of this is read, and neither announces itself:**

| Cap | Where | What happens past it |
|---|---|---|
| **60 characters** on a skill `description` | `extract_skill_description`, `agent/skill_utils.py:777` | Silently truncated to 57 + `...` in the system-prompt index |
| ~4000 characters read from `SKILL.md` for frontmatter | `tools/skills_tool.py` scan | Frontmatter past that is not parsed |

The 60-char cap is the one that bites. The description is the *only* thing the model sees before
deciding whether to load the skill, so every trigger word has to fit inside it. `zach-finances`
first shipped with a 206-character description and was cut mid-sentence at "what the finance tools
can and cannot see, ..." — dropping the words "balances", "tax" and "VAT", which are precisely the
ones a routing decision turns on. Category descriptions in `DESCRIPTION.md` are *not* capped, but
they ride every call, so keep them short anyway.

**Gate a skill on `requires_toolsets` or the crons pay for it.** The index is rendered from the
skills on disk regardless of whether the `skills` toolset is loaded — `_skill_should_show`
(`agent/prompt_builder.py:1398`) filters per skill on frontmatter `conditions`, and nothing else
suppresses the block. A cron turn takes `SPZ_CRON_TOOLSETS=clarify,memory,todo`, which has no
`skill_view`, so an ungated skill bills the hourly content-ops poll and the daily roundup for an
index neither can act on. `metadata.hermes.requires_toolsets: [skills]` fixes it. Measured on a
fresh process against the generated config:

| Turn | Ungated | Gated on `[skills]` |
|---|---|---|
| Discord | ~432 tokens | ~432 tokens |
| Cron | ~432 tokens | **0** |

**Most of that 432 is not the skill.** About 400 tokens are the framework's own mandatory
skills preamble, which appears as soon as *any* skill is visible; `zach-finances` itself adds ~35.
That is the real price of the first skill, and it is worth knowing which side of it this deployment
starts from — which is a question about the volume, not the repo:

```bash
# In the container. If this is empty or missing, the skills index costs nothing today
# and the fork skill introduces the ~400-token preamble.
ls "$HERMES_HOME/skills"
```

`stage2-hook.sh` is what creates that directory and syncs the 18 bundled skill packs into it, and
**Railway's custom start command bypasses `stage2-hook.sh` entirely** — so on a volume that has
never seen it, the directory does not exist and `build_skills_system_prompt` returns an empty
string. If it *does* exist, the sync has put 61 skills in the index at roughly **2088 tokens on
every call**, for GitHub, MLOps, Apple Notes and smart-home packs that cannot do anything on this
container. That would be a bigger cost item than anything in the toolset section above, and it is
checkable with the one command.

`SPZ_SKILLS_DIR` overrides the path; the literal `none` omits the block entirely, the same escape
hatch shape as `SPZ_RELAY_CHANNELS=none`. A path that does not exist is skipped by the framework at
debug level and nothing else, so `spz-boot.sh` checks for the directory itself and warns at boot
rather than letting a typo become a skill that is simply never there.

### One container, and the fleet that used to be four

SPZ runs as a single Railway service, `hermes-spz`, with one Discord bot answering `#spz` and
`#approvals` — though `#approvals` now has nothing to carry, since the dashboard's approval queue
was removed and no longer posts requests there (see the note on `SPZ_CHANNEL_APPROVALS` below). It
owns both crons: the 12PM roundup and the hourly content-ops poll. That is the whole deployment.

It was not always. For a stretch each persona — The Trainer, The Medical Team, The Manager, CLZ —
was moving onto its own Railway service with its own bot and its own `SOUL.md`, scoped to its own
channel, so that Zach talked to each agent directly instead of through a carrier. Before that,
`hermes-spz` answered all four persona channels itself, primed by `channel_prompts` to hand each
message to that persona's MCP tool and echo the reply back untouched. Both shapes are gone. The
persona channels are abandoned rather than reassigned: SPZ does not relay them and does not answer
them in its own voice either. Everything happens in `#spz`.

The collapse cost exactly one Railway variable, `SPZ_RELAY_CHANNELS=none`, plus moving
`SPZ_CONTENT_OPS_POLL` and `SPZ_CONTENT_OPS_CRON` off the deleted `hermes-manager`. That it was
that cheap is not luck — it is the `SPZ_ROLE` default paying out. Every role-dependent branch in
`spz-boot.sh` is written as "spz is the status quo, a persona is the departure", so a service that
never sets `SPZ_ROLE` takes the same path it took before the variable existed. The one-container
deployment is the branch the file was always written to favour.

**The persona machinery is still in `spz-boot.sh`, dormant, and that is deliberate.** `SPZ_ROLE`,
`SPZ_PERSONA_CHANNEL`, `SPZ_PERSONA_CRON`, the `DISCORD_ALLOW_BOTS` line and the fleet roster are
all gated on a role this deployment never sets, and grepping the repo for them returns only this
file and that script — no Python reads any of it, so "dormant" is provable rather than assumed.
Deleting it would buy nothing at runtime and would foreclose ever splitting out again, at the
price of a large untested diff in the one file whose first real run is a production boot. It stays.
What must not stay is prose describing it as live, which is why this section exists in this shape.

**Two variables in that machinery are not dormant, and one of them is the trap.**
`SPZ_RELAY_CHANNELS` must remain set to the literal `none`. Deleting it does not mean "no relays":
`spz-boot.sh` reads an unset value on the `spz` role as *all four*, so removing the variable during
a tidy-up restores every persona relay at once, with the boot log cheerfully announcing the derived
channels. And **`SPZ_CHANNEL_HOME` must survive any cleanup of the other `SPZ_CHANNEL_*` ids**,
because with no relays left it and `SPZ_CHANNEL_APPROVALS` are the *only* remaining source of
`DISCORD_FREE_RESPONSE_CHANNELS`. Remove every id and the variable is never exported at all, at
which point `#spz` silently starts requiring an `@mention` — SPZ stops answering the one channel it
exists to answer, and nothing errors. Verified by hand: with `SPZ_RELAY_CHANNELS=none` and both ids
set, the boot logs `Free-response channels derived: <approvals>,<spz>`; with the ids removed it logs
nothing at all and the variable is never exported.

**`SPZ_CHANNEL_APPROVALS` is now the one that can go, and only it.** The dashboard's approval queue
is deleted — no `pendingActions.ts`, no Approve/Deny buttons, no `list_pending_approvals` /
`resolve_pending_approval` — so nothing posts to `#approvals` and there is no free-typed `YES <code>`
left to miss. Dropping the variable costs a free-response channel nobody writes to. Dropping
`SPZ_CHANNEL_HOME` alongside it is the failure above. The pairing this file used to insist on has
become a single dependency, and the two halves must not be tidied up together.

#### Why the fleet was shaped the way it was

Worth keeping, because it is the reasoning any future split-out would otherwise have to rediscover
the hard way, and because two of the rules still constrain what can be built here.

There was deliberately **no shared `#agents` channel**, and the argument was structural rather than
stylistic. This framework has no loop guard — nothing counts bot-to-bot turns or breaks a cycle.
It did not need one, because exactly one bot listened per channel and no bot wakes on its own
messages, so an exchange ran out on its own. Two listeners in one room is the single arrangement
nothing here stops. **That rule survives the collapse and still applies**: if a second bot is ever
pointed at `#spz`, nothing in this framework prevents the two of them from talking until a budget
runs out.

For the same reason `hermes-spz` was kept blind to bot messages (`DISCORD_ALLOW_BOTS` left at its
`none` default, set to `all` on persona roles only). It relayed the persona channels and posted
those answers back as a bot, so if it had also listened to bots it would have answered and
re-relayed its own relays. The hazard was removed structurally instead of by getting a cutover order
right — which is why the collapse needed no cutover order either.

The outbound half was a roster of the other three agents, each as `send_message with target
discord:<id>`, concatenated into `SPZ_SOUL_MD` before `SOUL.md` was written. It went in SOUL rather
than `channel_prompts` because SOUL is the only context that survives into a **cron-triggered**
turn, and it concatenated into the variable rather than appending to the file so that a restart
could not accumulate a roster per boot. Self was excluded from that roster: an agent handed its own
channel id will post to it, and since a bot never wakes on its own messages that send looks
delivered and goes nowhere.

None of it runs now. All of it is one Railway variable away from running again.

### Talking to an agent in a Discord voice channel

Sit in a voice channel, then type `/voice join` in a text channel the bot answers in (`#spz` for
SPZ). It connects, transcribes what you say, and speaks its replies back; `/voice leave` disconnects
and `/voice off` mutes the speech without leaving. All of that is upstream — the adapter's
`VoiceReceiver`, `gateway/run.py`'s `_handle_voice_channel_join`, `tools/transcription_tools.py` for
STT and `tools/tts_tool.py` for TTS. The fork adds nothing but a provider for each, because **neither
half picks a working one here by default**:

| | Framework default | Why it fails in this image |
|---|---|---|
| STT | `local` (faster-whisper) | Not installed — `[all]` excludes the `voice` extra |
| TTS | `edge` (edge-tts) | Not installed — `[all]` excludes it too |

Both would fall through to `tools/lazy_deps.py`, which pip-installs into `/opt/hermes/.venv` — inside
the immutable image layer, owned by root, while the gateway runs as the `hermes` user (the shim drops
privileges with `s6-setuidgid`). The install fails, and even where it succeeded it would vanish on
the next redeploy. That is the same reasoning the Dockerfile already applies to `hindsight-client`.

So `spz-boot.sh` emits an `stt` and a `tts` block naming providers whose SDK is baked in.
`openai==2.24.0` is a **core** dependency, and it drives all three usable paths — OpenAI STT, Groq STT
(same SDK, different `base_url`), and OpenAI TTS. Setting `stt.provider` explicitly matters for a
second reason: left unset, the auto-detect ladder is `local > groq > openai`, so it tries the missing
local backend first.

| Variable | Default | Meaning |
|---|---|---|
| `SPZ_STT_PROVIDER` | `openai` | `openai` or `groq`. Groq's `whisper-large-v3-turbo` is the cheap/fast option. |
| `SPZ_TTS_PROVIDER` | `openai` | `openai` or `elevenlabs` — see below. `edge` is still lazy-installed and will not work here. |
| `SPZ_ELEVENLABS_MODEL_ID` | `eleven_flash_v2_5` | ElevenLabs only. `eleven_turbo_v2_5` and `eleven_multilingual_v2` trade latency for fidelity. |
| `SPZ_ELEVENLABS_VOICE_ID` | unset | ElevenLabs only. A real id from the voice library — no default is invented here. |
| `SPZ_ELEVENLABS_SPEED` | unset | ElevenLabs only, 0.7–1.2. **Not** `SPZ_TTS_SPEED`, which the OpenAI backend alone reads. |
| `SPZ_TTS_VOICE` | `alloy` | Any OpenAI voice — `alloy`, `echo`, `fable`, `onyx`, `nova`, `shimmer`. `fable` is the British-accented male. |
| `SPZ_TTS_MODEL` | `gpt-4o-mini-tts` | |
| `SPZ_TTS_SPEED` | unset | Rate multiplier, clamped to 0.25–4.0. Omitted when unset. |
| `SPZ_TTS_INSTRUCTIONS` | unset | Free-text delivery direction, e.g. "Refined British butler. Measured, formal, dry." Omitted when unset. |

#### ElevenLabs, and the `uv sync` line this fork has changed

OpenAI's voices read as synthetic and are slow enough to be felt in a spoken exchange, so
`SPZ_TTS_PROVIDER=elevenlabs` is the realism/latency option. It needs `ELEVENLABS_API_KEY` and a
`SPZ_ELEVENLABS_VOICE_ID` from the voice library.

This is one of the fork's **two** Dockerfile changes: `--extra tts-premium` on the `uv sync` line.
(The other is the deleted `VOLUME` instruction, which has nothing to do with voice — see the
fork-touched file list near the top.) The
reasoning is the one the Dockerfile already applies to `hindsight-client` — `tools/lazy_deps.py`
would pip-install the SDK into `/opt/hermes/.venv`, inside the immutable image layer, owned by root
while the gateway runs as `hermes`. The install fails, and would vanish on the next redeploy even
where it succeeded. Without that extra the provider is silently unavailable at *runtime* rather than
failing at build.

Three things worth knowing before touching this:

- **STT and TTS no longer share a credential**, so they are gated separately. An ElevenLabs key
  alone buys a voice that speaks but cannot listen; a Groq key alone is the reverse. Emitting
  `stt.enabled: true` with no usable key would fail on the first spoken word rather than at boot,
  which is why each half checks for its own.
- **`SPZ_ELEVENLABS_*` are deliberately not named `SPZ_TTS_VOICE`/`SPZ_TTS_MODEL`.** Those are the
  OpenAI voice *name* and model; these are ElevenLabs *ids*, a different namespace. Sharing the
  names would invite the transposition that already cost one debugging session — a voice name in a
  model slot 404s at speak time, never at boot.
- **No `voice_id` default is invented.** The framework's own fallback is Adam, which is American; a
  made-up id would 404 at speak time. Unset emits no key and warns, so the framework default applies
  and the log says so.

**Voice, speed and instructions are three different things, and only the first is timbre.**
`SPZ_TTS_VOICE` picks who is speaking; `SPZ_TTS_SPEED` and `SPZ_TTS_INSTRUCTIONS` shape how. None of
them touch *what* is said — TTS reads the reply text verbatim, so a chatty agent in a British voice
is still chatty. Register and brevity come from `SPZ_SOUL_MD`. This is the distinction that makes
"it doesn't sound right" a SOUL fix far more often than a voice fix.

Four traps here, all of which this file has hit variants of before:

- **`fable` in `SPZ_TTS_MODEL` is a 404, not a validation error.** The framework passes both straight
  through (`tts_tool.py`), so a voice name in the model slot fails at OpenAI with
  `The model 'fable' does not exist`, at speak time rather than at boot. The two variable names sit
  next to each other and are easy to transpose — check the model slot first when TTS goes quiet.
- **`instructions` is the fork's second Python change**, three lines in `_generate_openai_tts`. It is
  gated on the model: the `gpt-4o*-tts` family accepts it, legacy `tts-1`/`tts-1-hd` reject the
  parameter outright, so it is dropped with a warning there rather than turned into a 400.
- **`speed` is emitted UNQUOTED** because `tts_tool` calls `float()` on it, which raises on a
  non-numeric — that would take the reply down rather than degrade. `spz-boot.sh` validates it and
  drops a non-number with a warning instead of passing it on.
- **`instructions` is emitted as a YAML block scalar**, not a quoted string, because it is prose
  someone will iterate on. An apostrophe or a stray double quote inside a quoted scalar breaks the
  whole document, and a config that will not parse takes the gateway down over a wording tweak.

> **Setting `OPENAI_API_KEY` on a service will break inference unless `model.provider` is pinned.**
> It outranks `ANTHROPIC_API_KEY` in provider auto-detection and silently routes the agent at
> OpenRouter, which then 401s with no Authorization header. `spz-boot.sh` pins the provider for this
> reason — see "Pin the provider, or a voice key takes the fleet down" above before adding a voice
> key anywhere. Prefer `VOICE_TOOLS_OPENAI_KEY`, which the voice block accepts and auto-detection
> does not read.

The block is **gated on a key being present** (`OPENAI_API_KEY`, `VOICE_TOOLS_OPENAI_KEY` or
`GROQ_API_KEY`), following the same rule as every other instance-scoped feature here: the Railway
variable is the switch. With no key set the generated `config.yaml` is byte-identical to what it was
before this existed, so landing it changed nothing anywhere — verified by diffing the output against
the pre-change script. Note `GROQ_API_KEY` alone enables the block but not TTS, which still needs an
OpenAI key; STT-only is a legitimate setup (SPZ listens, answers in text) but is not the default.

Four things deliberately *not* done:

- **`voice.auto_tts` is not set.** That is the global "speak every reply" switch, and it would have
  SPZ reading its ordinary text answers in `#spz` aloud. `/voice join` already flips that one chat to
  voice mode and persists it to `gateway_voice_mode.json` on the volume, so the opt-in stays
  per-channel and survives a restart.
- **No Dockerfile change.** Voice *transport* already works: `discord.py[voice]` (which pulls PyNaCl
  and `davey` for Discord's DAVE E2EE) arrives via the `messaging` extra the image installs, and
  ffmpeg and libopus are already there. Only the two providers were missing.
- **No per-persona scoping.** Any role that has a key gets the block, so a persona can be talked to
  in voice on the same terms. What a persona *does* need is its text channel in
  `DISCORD_ALLOWED_CHANNELS` — `/voice join` is typed in a text channel, and the whitelist gates
  slash commands as well as messages.
- **`VOICE_TIMEOUT` is left alone.** The adapter auto-disconnects after 300s of silence, and it is a
  class attribute (`plugins/platforms/discord/adapter.py`), not config. Changing it would mean a
  second Python patch for a value nobody has complained about — the bar described above is "no
  config path exists *and* the behaviour is actually wrong", and this clears only the first half.

#### Keeping a voice conversation in the voice channel

By default a spoken turn writes itself into the text channel twice: the transcript of what Zach said
is posted as `**[Voice]** @zach: …`, and SPZ's answer is posted as text *and* spoken. Two
`config.yaml` settings turn each off, emitted by `spz-boot.sh` from Railway variables:

| Variable | Default | Config key | Effect when flipped |
|---|---|---|---|
| `SPZ_VOICE_ECHO_TRANSCRIPT` | `true` | `voice.echo_transcript` | Zach's speech stops appearing in the text channel |
| `SPZ_VOICE_SUPPRESS_TEXT` | `false` | `voice.suppress_text_reply` | SPZ's answer is spoken but not posted |
| `SPZ_VOICE_STARTUP_NOTE` | `false` | `voice.startup_voice_note` | The "gateway online" notice is also sent as a spoken voice note |

Turning `SPZ_VOICE_STARTUP_NOTE` on makes every redeploy post the "gateway online" notice as a
voice note as well as text. It exists because tuning a voice is a listen-adjust-redeploy loop and
the voice-channel connection does **not** survive a restart — `_voice_clients` is an in-memory dict
with nothing restoring it at boot, so hearing a change otherwise means sitting in a voice channel
and running `/voice join` after every single deploy. The note is a plain audio attachment, so it
needs no voice connection at all. It is strictly additive: the text notice is sent and counted
before the audio is attempted, so a TTS provider that is slow, unconfigured or broken can never stop
the gateway coming up.

**This is one of the fork's Python changes**, in `gateway/run.py`: a `_voice_chat_visibility` helper plus
two call sites. It was necessary because neither behaviour had a config path — the transcript post
was unconditional, and the reply text is the agent's only output channel. There is no
agent-callable `send_message` (withheld on purpose, `toolsets.py:373`) and the `discord` tool stops
at read/pin/delete/role, so an agent cannot choose to write to chat separately from what it says.
That last point is the real constraint: **"speak briefly, put the detail in chat" is not currently
expressible** — one string is both spoken and posted, so the only lever is making the reply itself
short, via `SOUL.md`.

Three details that are load-bearing:

- **The suppression is nested inside the send.** It can only apply once the audio has actually gone
  out, so a TTS failure falls back to posting the text rather than swallowing the answer, and it is
  skipped entirely when streaming already delivered the reply (blanking it then would not unsend
  what has been read).
- **It is a delivery decision, not a transcript mutation** — the assistant turn stays in session
  history, so later turns keep normal user/assistant alternation. This deliberately mirrors the
  `_intentional_silence` branch a few lines above it, which is the precedent that makes the change
  safe rather than novel.
- **The two booleans are emitted UNQUOTED**, the inverse of the quoting rule everywhere else in this
  file, because the reader takes `bool()` of what it finds and `bool("false")` is `True` — quoting
  them would make "off" mean "on", silently. `spz-boot.sh` normalises the Railway value to a strict
  `true`/`false` and warns on anything else, because a bare `nope` would otherwise emit a string and
  every string is truthy. That is the third instance of this trap here, as this file predicted.

Discord-side, the bot needs **Connect** and **Speak** on the voice channel; `voice_states` is a
non-privileged intent the adapter already requests. `scripts/discord-voice-doctor.py`, run inside the
container, checks every dependency, the opus load, and the bot's permissions in one pass — start
there if it joins but neither hears nor speaks.

## Commands

Run these from Git Bash on this Windows machine (`scripts/run_tests.sh` is POSIX sh).

**First, a search rule, and the trap this checkout used to contain.** `.claude/` is gitignored
(that is the whole `.gitignore` hunk above), so `git grep` never looks inside it — but `grep -r` and
`find` do, and `.claude` sorts before every real directory, so anything living there comes back
**first**. An agent worktree once left a complete second copy of this repo at
`.claude/worktrees/agent-…` — 2938 Python files, 145 MB — and every unrestricted search returned the
stale copy ahead of the file it shadowed:

```
$ grep -rln "resolve_requested_provider" --include=*.py .
./.claude/worktrees/agent-.../hermes_cli/runtime_provider.py   <- stale copy, returned first
./hermes_cli/runtime_provider.py                                <- the file you actually want
```

Editing the wrong one fails silently in the worst way: the change is real, the file is right, and
nothing you deploy ever contains it.

**That copy is gone** — deleted after checking that every fork-touched file in it hashed to a blob
already in history, so nothing was lost with it, along with the stale `.git/worktrees/` admin entry
that made every `git commit` print a `Permission denied` prune error. `.claude/worktrees/` itself
survives as an empty directory — it shadows nothing, and the search above now returns one hit per
path, but the path existing is not evidence the copy is back. The rule outlives it: the next
agent worktree lands in the same place, is ignored by the same line, and announces itself just as
loudly, which is to say not at all. Search with `git grep`, or exclude the directory explicitly
(`grep -r --exclude-dir=.claude`; `rg` honours the ignore file already). And if an unrestricted
search ever returns two hits for a path that exists once, read the prefix before believing either.

```bash
# FIRST, on a fresh checkout: there is no .venv here, and uv/ruff/ty are not on
# PATH on this machine. Every command below then dies as `command not found`,
# which reads as a broken tool rather than a missing bootstrap — the same trap
# the npm half documents further down. CI installs with `uv sync --locked`
# (which also fails if uv.lock has drifted from pyproject.toml); do the same.
uv sync --locked                   # creates .venv; run_tests.sh probes for it
uv lock --check                    # what uv-lockfile-check.yml enforces on every PR

# Tests — ALWAYS via the wrapper, never bare pytest. It enforces CI parity:
# unset credential env vars, TZ=UTC, LANG=C.UTF-8, PYTHONHASHSEED=0, and a fresh
# Python subprocess per test file (so module-level state can't leak between files).
# NOT xdist — scripts/run_tests_parallel.py replaced it precisely because its
# persistent workers accumulated state across files, which is the leak being fixed.
scripts/run_tests.sh                                   # full suite
scripts/run_tests.sh tests/gateway/                    # one directory
scripts/run_tests.sh tests/agent/test_foo.py::test_x   # one test
scripts/run_tests.sh -v --tb=long                      # pass-through pytest flags

ruff check .                       # lint (only PLW1514 is enabled — see below)
ty check                           # typecheck (Python)
python scripts/check-windows-footguns.py --all   # Windows-unsafe primitives; CI runs this on every PR

# TypeScript packages: ui-tui, web, apps/bootstrap-installer, apps/desktop, apps/shared.
# Root package.json is the npm workspace root and this checkout has NO node_modules, so an
# install comes first or every --prefix below dies as a missing script, not a type error.
npm ci --ignore-scripts            # enough for typecheck; skips node-pty's node-gyp fetch, as CI does
npm run --prefix ui-tui typecheck  # CI runs `typecheck` for each of the five packages
npm ci                             # desktop's vite build needs node-pty's native binary, so scripts run
npm run --prefix apps/desktop build  # CI also runs the real vite build for desktop

cd ui-tui && npm run dev           # TUI watch mode; also build / lint / fmt / test (vitest)

./hermes --help                    # local CLI launcher (same entry as installed `hermes`)
python run_agent.py --help
```

### Verifying a `spz-boot.sh` change — nothing else does

Note what the suite above does *not* cover: `scripts/run_tests.sh` tests upstream Python, and this
fork has never written any. **`docker/spz-boot.sh` has no behavioural test.** The one automated
check it does get is shellcheck at `--severity=error` — `.github/workflows/docker-lint.yml` runs it
over `scandir: ./docker`, gated by `ci.yml` on the `docker_meta` change class, which
`scripts/ci/classify_changes.py` defines as `_DOCKER_META = ("docker/", ".hadolint.yml",
"Dockerfile")`. That catches unquoted variables
and syntax errors, not one line of what the script actually *does*. Its first real run of that is a
Railway container boot, so verify it by hand before pushing, the way the commit history describes:
a temp `HERMES_HOME` and a stubbed `hermes` earlier on `PATH`.

**The heading is about `spz-boot.sh` specifically — the fork's other docker surface is not
unguarded.** That same workflow's second job runs hadolint over the `Dockerfile` at
`failure-threshold: warning`, and because `Dockerfile` is its own entry in the tuple above, a
Dockerfile-only change triggers the lane on its own rather than riding a `docker/` edit. Worth
knowing before touching either of the two fork hunks there. It does not, however, cover the one that
matters most: **nothing in CI notices the `VOLUME` instruction being restored**, since hadolint has
no opinion about an instruction upstream wrote deliberately. Railway's build pipeline rejecting the
push is still the only thing that catches it, which is the whole reason that deletion is called out
as the hunk a merge can undo without leaving a conflict marker.

Put a stub `hermes` (log `$*`, `exit 0`) and a stub `chown` (`exit 0`, since there's no `hermes`
user locally) in a temp dir, then run the script with that dir prepended to `PATH` and `HERMES_HOME`
pointed at an empty temp dir. The final `exec hermes gateway run` lands on the stub, so the script
exits cleanly and leaves the two generated files behind to inspect.

That is the whole harness, and it is written out below rather than described because a recipe nobody
runs is exactly the failure this section exists to prevent. Paste it into Git Bash from anywhere in
the repo; it prints one labelled section per check and exits 0 when they all pass. **The stub
`hermes` keeps a fake cron store inside `$HERMES_HOME`** rather than merely logging, which is the
one embellishment on the prose above and is load-bearing: without it the existence check always sees
an empty fleet, every job is created on every boot, and "the second run must not create a duplicate"
cannot be checked at all.

```bash
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
```

What each labelled section is actually asking, and why none of the five can be dropped:

- **Both role paths** — blocks 1 and 3. `SPZ_ROLE=<persona>` (the script accepts `trainer`,
  `clinic`, `manager`, `clz`; anything unrecognized warns and is treated as a persona) and the
  default `spz` take different branches almost everywhere. A persona emits the fleet roster into
  `SOUL.md` and logs `Role trainer admits messages from other agents`; `spz` emits neither and
  instead logs `Free-response channels derived: …`. Both lines appear in the run above, and their
  absence is the check. Still worth running both precisely *because* Railway no longer does —
  since the collapse the persona path is exercised only by hand, so a change that breaks it will not
  surface until someone tries to split out again.
- **Self-exclusion** — block 3. A persona's roster must contain the other three channel ids and
  *not* its own, which is why the trainer run passes `333…` as both `SPZ_PERSONA_CHANNEL` and
  `SPZ_CHANNEL_TRAINER`: that is the arrangement in which a self-exclusion bug would show.
- **Quoted scalars** — `grep '"' config.yaml`, in blocks 1 and 4. The `channel_prompts` keys must
  come out as `"111"`, not `111`, and `tool_progress` as `"off"`, not `off`. Unquoted, the ids parse
  as ints and every lookup misses; unquoted, `off` parses as `False` and the display setting is
  ignored. Both silent. Note that block 1 cannot check the first half of that at all — the live
  shape sets `SPZ_RELAY_CHANNELS=none`, so no `channel_prompts` block is emitted and the grep passes
  vacuously. That is the entire reason block 4 exists: it turns one relay back on so there is a key
  to look at.
- **The toolsets block** — blocks 1 and 5. `platform_toolsets` must carry both a `discord` and a
  `cron` key. `cron`
  is a separate platform key with its own default, so a run that narrows `discord` alone leaves
  every scheduled turn still paying for the full bundle — the bigger of the two savings, lost with
  nothing in the config looking wrong. `cronjob` must appear in the `discord` list only where
  `SPZ_CONTENT_OPS_POLL` is set. The original reason — sparing every persona a schema for a
  schedule it did not own — is moot with one container, but the check is still the cheap way to
  catch the rider being wired to the wrong flag.
  And `SPZ_TOOLSETS=full SPZ_CRON_TOOLSETS=full` must leave the key out of the file altogether: an
  emitted key whose list is empty resolves to a platform with no native tools at all, the opposite
  of what `full` promises, so the way back has to be checked as an absence rather than assumed.
- **Fork skills** — block 4b. Three things, and the third is the one that would otherwise rot:
  the emitted path must be **absolute** (`get_external_skills_dirs` resolves a relative entry
  against `HERMES_HOME`, not the working directory, so a relative path silently points into the
  volume and finds nothing) and **quoted**; `SPZ_SKILLS_DIR=none` must omit the key rather than
  emit an empty one; and a path that does not exist must produce a boot warning. The framework
  skips a missing external dir at debug level and says nothing, so without that warning a typo in a
  Railway variable presents as a skill the agent simply never mentions. Note this block cannot
  check the part that actually matters — whether the model *loads* the skill — which is a
  60-character description away from being wrong and is not observable from the config at all.

- **Idempotency** — block 1, which is why it boots twice into one `HERMES_HOME`. `config.yaml`
  must be byte-identical across the two, and the second run must not create a duplicate cron job.
  Note that "no duplicate" is not "no churn": `spz-content-ops-poll` and `spz-persona-checkin`
  deliberately remove and recreate themselves on every boot (see the rule above), so expect a
  remove+create pair for each in the stub log — the check is `sort "$SPZ/.stub-cron-jobs"` showing
  one line per name at the end, not one create in the log. `spz-daily-roundup` is the opposite
  shape: created by name check, so boot 2 should show `hermes cron list --all` and no second create.

Keep it **POSIX sh**. The shebang is `#!/bin/sh` and `railway.json` invokes it as
`sh /opt/hermes/docker/spz-boot.sh`, so bashisms — `[[ ]]`, arrays, `local`, `+=` — break it in the
container while working fine in Git Bash, where you'd be testing. `set -e` is on, which is why every
tolerated failure (`hermes cron remove`, the `chown`) is explicitly suffixed `|| true` or `|| echo`.

### Commit messages

Fork commits carry long prose bodies (14–44 lines) explaining *why*, including the counterfactual —
what breaks if it were done the other way, and what already broke once. Match that; the reasoning
behind these decisions lives in the log, not in the one-line shell diff it usually accompanies.

Ruff has **all rules intentionally disabled except `PLW1514`** (unspecified-encoding). Bare
`open()`/`read_text()`/`write_text()` in text mode defaults to cp1252 on Windows and silently
corrupts non-ASCII content. Don't "fix" unrelated style; do always pass `encoding=`.

Two things about that lint are easy to undo by accident. **`PLW1514` is a preview rule, so
`[tool.ruff] preview = true` is what makes it fire at all** — drop that line while tidying
`pyproject.toml` and `ruff check .` still exits 0 on every file, now enforcing nothing. And
`per-file-ignores` exempts `tests/**`, `skills/**`, `optional-skills/**` and `plugins/**`, so a
missing `encoding=` in those trees is deliberate rather than an oversight to go fix.

Python is pinned to `>=3.11,<3.14`, and every direct dependency is exact-pinned (`==X.Y.Z`) as a
supply-chain measure — bump the pin in `pyproject.toml` and regenerate `uv.lock` with `uv lock`;
never reintroduce ranges.

## Architecture

One agent core, many front ends. `run_agent.py` (`AIAgent`) holds the conversation loop; every
surface — CLI, gateway, TUI, desktop, ACP, cron — drives that same class.

```
tools/registry.py      (no deps; imported by every tool file)
      ↑
tools/*.py             (each calls registry.register() at import time — auto-discovered)
      ↑
model_tools.py         (tool discovery + handle_function_call dispatch)
      ↑
run_agent.py, cli.py, batch_runner.py, gateway/, tui_gateway/
```

- `run_agent.py` — `AIAgent.run_conversation()`: a synchronous while-loop over model calls and tool
  calls, bounded by `max_iterations` and an `iteration_budget`, with interrupt checks and a
  one-turn grace call. Messages are OpenAI-format; reasoning lives in `assistant_msg["reasoning"]`.
- `toolsets.py` — the single `TOOLSETS` dict plus `_HERMES_CORE_TOOLS` (the default bundle each
  platform's base toolset inherits). Registering a tool is not enough to expose it; its name must
  appear in a toolset.
- `cli.py` — `HermesCLI`, the prompt_toolkit/Rich interactive CLI. Slash commands resolve through
  the central registry in `hermes_cli/commands.py`.
- `gateway/` — messaging gateway. `run.py` + `session.py` + one adapter per platform under
  `platforms/` (telegram, discord, slack, signal, matrix, email, sms, api_server, …).
- `ui-tui/` (Ink/React) ↔ `tui_gateway/` (Python) over newline-delimited JSON-RPC on stdio.
  TypeScript owns the screen; Python owns sessions, tools, model calls, slash logic.
  `apps/desktop/` is a *separate* Electron chat surface with its own composer and transcript; the
  `hermes dashboard` web chat instead embeds the real `hermes --tui` through a PTY bridge.
- `hermes_state.py` — `SessionDB`, the SQLite session store (FTS5 search).
- `hermes_constants.py` — `get_hermes_home()` / `display_hermes_home()`.
- Extension points, in the order you should prefer them: extend existing code → CLI command +
  skill → service-gated tool (`check_fn`) → plugin (`plugins/`, `~/.hermes/plugins/`) → MCP server
  → new core tool (last resort). Every core tool ships on every API call.

## Non-obvious invariants

- **Prompt caching is sacred.** Never mutate past context, swap toolsets, or rebuild the system
  prompt mid-conversation — context compression is the sole exception. Slash commands that change
  system-prompt state default to deferred invalidation with an opt-in `--now`.
- **Never hardcode `~/.hermes`.** Use `get_hermes_home()` for paths and `display_hermes_home()` for
  user-facing text, or you break profiles (multi-instance isolation set up by
  `_apply_profile_override()` in `hermes_cli/main.py` before any module imports).
- **`.env` is for secrets only.** All behavioral settings — timeouts, thresholds, feature flags,
  display prefs — belong in `config.yaml`. A PR that tells users to "set `HERMES_*` in .env" for
  non-credential config gets rejected.
- **No change-detector tests.** Don't assert model-catalog membership, config version literals, or
  enumeration counts. Assert invariants (e.g. every catalog model has a context-length entry).
- **Tests must not write to `~/.hermes/`** — the `_isolate_hermes_home` autouse fixture in
  `tests/conftest.py` redirects `HERMES_HOME`; profile tests must also patch `Path.home()`.
- **Windows footguns are real here.** `os.kill(pid, 0)` broadcasts Ctrl+C to the console process
  group on Windows — use `psutil.pid_exists`. Guard `termios`/`fcntl`, `SIGALRM`/`SIGKILL`/`SIGHUP`,
  `os.setsid`; use `shutil.which()` before shelling out. See CONTRIBUTING.md "Cross-Platform
  Compatibility" for the full list of 16 rules.
- **Two gateway message guards** exist (`gateway/platforms/base.py` queueing and `gateway/run.py`
  interception). Any command that must reach the runner while an agent is blocked must bypass both.
