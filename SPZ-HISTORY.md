# SPZ history

The reasoning and incidents behind the rules in `SPZ.md`, moved out of it so they are not loaded
into every session. `SPZ.md` holds the rules; this file holds how each one was learned. It is not
auto-loaded — read the relevant section before changing a rule, or before splitting the
deployment back out into per-persona services.

Each section is the original `SPZ.md` text, moved verbatim, in the order it appeared there. Every
number here was true when written and is **not** maintained: "this file" and "above"/"below"
refer to `SPZ.md`, and counts are historical. Re-derive anything before quoting it.

## Why only the code-only diff total is quoted

**A total that counts `SPZ.md` can never be right at rest, because writing the number changes the
number.** The first two rows once carried file counts for that reason — the theory being that a
file count is the stable half and only the insertion total moves. That theory was wrong, and this
table proved it: those rows read 20 and 9 files, and by the time anyone checked they were 42 and 31.
Their insertion totals had already read 2003, then 2105, then 2131 — each recount dated by its own
edit, by exactly the lines that edit added, and each one true for about the length of one commit.
Neither half was measuring code. **`spz-skills/` is what settles it**: a skill tree is prose, it
grows by hundreds of lines at a time, and it moved every figure in this table without one line of
code changing. So the exclusion list has to name it alongside this file. The third row is the way
out: a pathspec excluding `SPZ.md`, `CLAUDE.md` and `spz-skills/` measures the code alone, so it
moves only when code moves, and it is the only figure here worth quoting. Re-run `git diff --stat`
rather than trusting even that one, the same way the fork point above is re-derived rather than
remembered; the shape of the claim — which files can
conflict, and that the Python half is eight small hunks — is what is meant to survive, not the
arithmetic.

## The 11-and-181 miscount

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

## The poll that outlived its own switch

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

## The voice-key outage

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

## How the MCP tool count drifted

**Count the tools, not the `registerTool` calls — and re-count them rather than quoting this
number.** It said 16 for a long time, which is the number of call sites in the dashboard repo's
`api/mcp.ts` — but one of them sits inside a `for (const schema of TOOL_SCHEMAS)` loop that
registers every entry of `TOOLS` in `api/_lib/spzAgent.ts`. Correcting that gave 13 static + 25
dynamic = 38, which was true when it was written and is **wrong now**: `TOOLS` has since grown three
finance tools (`get_account_balances`, `search_transactions`, `get_spend_by_category`), so the real
exposure is 13 + 28 = **41**. It was 15 + 25 = 40 before that, until `list_pending_approvals` and
`resolve_pending_approval` went with the approval queue. The ~4k-token figure for the schema block
was measured at 25 dynamic tools and has not been re-measured since; treat it as a floor.

## Haiku: the cost arithmetic, and how the approval queue's removal moved the risk

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

## The fleet that used to be four, and what collapsing it cost

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

## Why the fleet was shaped the way it was

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

## The stale worktree under `.claude/`

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

## Why `spz-daily-roundup` recreates itself on every boot

- **Idempotency** — block 1, which is why it boots twice into one `HERMES_HOME`. `config.yaml`
  must be byte-identical across the two, and the second run must not create a duplicate cron job.
  Note that "no duplicate" is not "no churn": `spz-content-ops-poll` and `spz-persona-checkin`
  deliberately remove and recreate themselves on every boot (see the rule above), so expect a
  remove+create pair for each in the stub log — the check is `sort "$SPZ/.stub-cron-jobs"` showing
  one line per name at the end, not one create in the log. **`spz-daily-roundup` now has that same
  shape and no longer is the exception this bullet used to describe.** It was created by name check
  until `cd2238e` moved it to 2PM, which is exactly when the name check became the bug — it asked
  only whether the job existed, never whether its schedule still matched this file, so the hour was
  pinned to whatever the container's first boot wrote. Boot 2 therefore shows a remove+create pair
  for it too, and no `hermes cron list` at all. A run that shows one create per name and two jobs at
  the end is correct; treating the roundup's recreate as a duplicate is reading this bullet's old
  version.
