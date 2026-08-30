# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Where the guidance lives

This repo is **SPZ**, a deployment fork of the vendored Hermes framework, so its documentation is
split by who owns it. Nothing fork-specific is written here — this file exists to load the file that
holds it, because `SPZ.md` is not auto-loaded, and reading only the upstream guide would leave you
editing a fork as though it were the framework. **`AGENTS.md` is not loaded either**, despite what
this file used to claim — verified twice now, most recently in a session where only `CLAUDE.md` and
the expanded `@SPZ.md` were injected. Read it before any framework-side work; nothing will prompt
you to, and an instance that assumes it holds the contribution rubric and testing standards applies
them from memory and never finds out it was guessing.

@SPZ.md

If that import did not expand, read `SPZ.md` before touching anything — it is the only place the
fork's own conventions are written down, and most are there because something broke here first.

| File | Owner | Covers |
|---|---|---|
| `SPZ.md` | this fork | What SPZ is, the files every fork commit touches, the generated `config.yaml`, the `SPZ_`-vs-framework naming rule, per-persona containers, commands, and the invariants that have actually broken here |
| `AGENTS.md` (~1350 lines) | upstream | The canonical development guide: contribution rubric, footprint ladder, plugin/skill/toolset internals, prompt-caching policy, profile rules, testing standards |
| `CONTRIBUTING.md` | upstream | Cross-platform (Windows) rules and the skill-vs-tool decision guide |
| `../spz-dashboard/CLAUDE.md` | sibling SPZ repo | The dashboard and the MCP server this agent talks to — `api/mcp.ts`, `api/_lib/spzAgent.ts`. A separate checkout, but present beside this one, so every claim `SPZ.md` makes about the MCP surface is checkable rather than remembered |

`AGENTS.md` and `CONTRIBUTING.md` describe the framework as an upstream dev checkout. `SPZ.md`
describes what this fork actually does with it, and where the two disagree about scope — most often
about whether to write Python at all — `SPZ.md` governs.

**Every number in `SPZ.md` is re-derivable, so re-derive it rather than quoting it.** The counted
facts there — the MCP tool count, the insertion and hunk totals in the merge section, the fork
point, the file counts — were each true when written, and each goes stale silently, because nothing
recounts them when the thing they count changes. Two have already drifted and been corrected in
place; both sections now carry the command that regenerates the figure. Run it instead of repeating
the number, and correct it there when it has moved.
