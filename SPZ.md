# SPZ

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read AGENTS.md first

`AGENTS.md` (~1500 lines) is the canonical development guide for this codebase: contribution
rubric, footprint ladder, plugin/skill/toolset internals, prompt-caching policy, profile rules,
known pitfalls, and testing standards. This file is a short orientation layer on top of it —
it does not replace it. `CONTRIBUTING.md` adds the cross-platform (Windows) rules and the
skill-vs-tool decision guide.

## SPZ: a deployment fork, not an upstream dev checkout

This project is **SPZ**. `origin` is `github.com/zachshilton/hermes-agent` (a fork of
NousResearch/Hermes-Agent), deployed on Railway as the `hermes-spz` and `hermes-manager` services, plus one service per persona
(see "One container per persona" below);
the dashboard and MCP server it talks to (`api/mcp.ts`, `api/discord-inbound.ts`) live in a separate
SPZ repo. Refer to the project as SPZ, not Hermes — "Hermes" means the vendored upstream framework.
Every commit unique to this fork touches exactly three files:

- `docker/spz-boot.sh` — Railway start command (`railway.json` → `sh /opt/hermes/docker/spz-boot.sh`).
  Regenerates `$HERMES_HOME/config.yaml` and `SOUL.md` from Railway env vars on **every** container
  start (idempotent by design, always overwrites), creates cron jobs idempotently by name, then
  `exec hermes gateway run`.
- `docker/stage2-hook.sh` — s6-overlay UID remap / `HERMES_HOME` ownership.
- `railway.json`.

**No Python has ever been written in this fork.** The working convention, stated explicitly in the
commit messages, is to reach for existing framework config before customizing core. Examples: the
Discord per-persona relay is `platforms.discord.extra.channel_prompts` (read by
`resolve_channel_prompt` in `gateway/platforms/base.py`), not a forwarding endpoint; the daily
roundup is a `hermes cron create --deliver discord` job, not code. Prefer the same route — if a
change can be made in generated `config.yaml` or env vars, do it there.

### Naming: `SPZ_` is for us, `DISCORD_*`/`HERMES_*` belong to the framework

Every variable `spz-boot.sh` alone consumes carries an `SPZ_` prefix: `SPZ_MCP_URL`,
`SPZ_MCP_TOKEN`, `SPZ_SOUL_MD`, `SPZ_CHANNEL_{TRAINER,CLINIC,MANAGER,CLZ,CONTENT,HOME,APPROVALS}`,
`SPZ_ROUNDUP_ENABLED`, `SPZ_CONTENT_OPS_POLL`, `SPZ_ROLE`, `SPZ_PERSONA_CHANNEL`,
`SPZ_RELAY_CHANNELS`. Cron jobs follow suit: `spz-daily-roundup`, `spz-content-ops-poll`.

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
pre-rename name (`${SPZ_ROUNDUP_ENABLED:-${DISCORD_ALLOWED_USERS}}`), so boots survive a redeploy
that lands before the Railway variables are updated — drop the fallbacks once Railway is renamed.

Three conventions in `spz-boot.sh`, each of which has caused a silent failure:

- **Instances are scoped by which env var Railway sets**, not a service-name check:
  `SPZ_ROUNDUP_ENABLED` ⇒ `hermes-spz`; `SPZ_CONTENT_OPS_POLL` ⇒ `hermes-manager`. These are now
  dedicated flags precisely because the previous approach — piggybacking on whichever credential
  happened to be unique to a service — broke twice, as `SMS_ALLOWED_USERS` and then
  `DISCORD_ALLOWED_USERS` were retired and took the roundup cron with them.
- **Renaming a cron job needs a removal line.** The existence check only asks whether the *current*
  name is present, so a superseded job keeps running on its old schedule forever. `spz-boot.sh`
  removes `daily-roundup`, `daily-roundup-discord` and `content-ops-poll` on every boot.
- **Discord channel ids must stay quoted** in the emitted YAML. Unquoted they parse as ints and
  every `channel_prompts` lookup (which keys on the adapter's string id) misses.

### One container per persona

The original shape was one container: `hermes-spz` answered every persona channel itself, primed by
`channel_prompts` to relay each message to that persona's MCP tool. Each persona is now moving onto
its own Railway service with its own Discord bot and its own `SOUL.md`, scoped to its own channel,
so Zach talks to the agent directly instead of through a carrier. Three variables drive the move:

| Variable | Meaning |
|---|---|
| `SPZ_ROLE` | `spz` (default) \| `trainer` \| `clinic` \| `manager` \| `clz`. Which container this is. Unrecognized values warn and are treated as a persona, not as `spz` — a start command must not refuse to boot over a typo. |
| `SPZ_PERSONA_CHANNEL` | The one channel id this persona owns. On a non-`spz` role it derives `DISCORD_ALLOWED_CHANNELS` (whitelist: the bot ignores every other channel) and `DISCORD_FREE_RESPONSE_CHANNELS` (waives `DISCORD_REQUIRE_MENTION`, which defaults to true). Both only when Railway hasn't set them explicitly. |
| `SPZ_RELAY_CHANNELS` | Comma-separated persona keys (`trainer,clinic,manager,clz`, no spaces) this instance still emits `channel_prompts` for. Unset means all four on `spz` and none on a persona. The literal `none` spells out an empty list. |

`SPZ_ROLE` defaults to `spz` so that a service whose Railway variables have not been touched boots
exactly as it did before the variable existed — landing the change is a no-op until Railway says
otherwise, which is the whole safety story. Every role-dependent branch is written as "spz is the
status quo, a persona is the departure" for the same reason.

The migration is one persona at a time: stand up the persona's service, then drop its key from
`SPZ_RELAY_CHANNELS` on `hermes-spz`. Because `DERIVED_FREE_CHANNELS` is accumulated inside
`add_persona_channel`, a persona that drops out of the relay list leaves the free-response list in
the same breath — there is no second place to edit. #spz and #approvals are added to that list
regardless of how many relays survive, so the boot where the last persona moves out doesn't
silently cost #approvals its free-typed `YES <code>`.

A persona service needs: `SPZ_ROLE`, `SPZ_PERSONA_CHANNEL`, `SPZ_SOUL_MD`, `SPZ_MCP_URL`,
`SPZ_MCP_TOKEN`, `ANTHROPIC_API_KEY`, `DISCORD_BOT_TOKEN` (its own bot, invited to the guild with
read/send on its one channel), `DISCORD_ALLOWED_USERS`, `DISCORD_HOME_CHANNEL` (set to the same id as `SPZ_PERSONA_CHANNEL` — it
is the destination for cron and proactive delivery, and is not derived), and optionally
`HERMES_MODEL`.
`HERMES_HOME` is baked in by the image (`ENV HERMES_HOME=/opt/data`) and only needs a Railway
volume mounted there. It must **not** get `SPZ_ROUNDUP_ENABLED` or `SPZ_CONTENT_OPS_POLL` —
those stay on `hermes-spz` and `hermes-manager` respectively, per the dedicated-flag rule above.
The roundup's deprecated `DISCORD_ALLOWED_USERS` fallback is honoured only when `SPZ_ROLE` is
`spz`, because every persona service sets `DISCORD_ALLOWED_USERS` and would otherwise inherit a
12PM roundup cron; the guard itself still keys on `SPZ_ROUNDUP_ENABLED`.

## Commands

Run these from Git Bash on this Windows machine (`scripts/run_tests.sh` is POSIX sh).

```bash
# Tests — ALWAYS via the wrapper, never bare pytest. It enforces CI parity:
# unset credential env vars, TZ=UTC, LANG=C.UTF-8, -n auto xdist, and a fresh
# Python subprocess per test file (so module-level state can't leak between files).
scripts/run_tests.sh                                   # full suite
scripts/run_tests.sh tests/gateway/                    # one directory
scripts/run_tests.sh tests/agent/test_foo.py::test_x   # one test
scripts/run_tests.sh -v --tb=long                      # pass-through pytest flags

ruff check .                       # lint (only PLW1514 is enabled — see below)
ty check                           # typecheck (Python)
python scripts/check-windows-footguns.py --all   # Windows-unsafe primitives; CI runs this on every PR

# TypeScript packages: ui-tui, web, apps/bootstrap-installer, apps/desktop, apps/shared
npm run --prefix ui-tui typecheck  # CI runs `typecheck` for each of the five packages
npm run --prefix apps/desktop build  # CI also runs the real vite build for desktop

cd ui-tui && npm run dev           # TUI watch mode; also build / lint / fmt / test (vitest)

./hermes --help                    # local CLI launcher (same entry as installed `hermes`)
python run_agent.py --help
```

Ruff has **all rules intentionally disabled except `PLW1514`** (unspecified-encoding). Bare
`open()`/`read_text()`/`write_text()` in text mode defaults to cp1252 on Windows and silently
corrupts non-ASCII content. Don't "fix" unrelated style; do always pass `encoding=`.

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
