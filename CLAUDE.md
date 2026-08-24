# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Where the guidance lives

This repo is **SPZ**, a deployment fork of the vendored Hermes framework, so its documentation is
split by who owns it. Nothing fork-specific is written here — this file exists to load the file that
holds it, because `SPZ.md` is not auto-loaded, and reading only the upstream guide would leave you
editing a fork as though it were the framework. **Do not assume `AGENTS.md` is loaded either**,
despite what this file used to claim — in a session here only `CLAUDE.md` and the expanded `@SPZ.md`
were injected. Check, and read it before any framework-side work. Nothing will prompt you to: an
instance that assumes it holds the contribution rubric and testing standards applies them from
memory and never finds out it was guessing.

@SPZ.md

If that import did not expand, read `SPZ.md` before touching anything — it is the only place the
fork's own conventions are written down, and most are there because something broke here first.

| File | Owner | Covers |
|---|---|---|
| `SPZ.md` | this fork | What SPZ is, the files every fork commit touches, the generated `config.yaml`, the `SPZ_`-vs-framework naming rule, per-persona containers, commands, and the invariants that have actually broken here |
| `AGENTS.md` (~1350 lines) | upstream | The canonical development guide: contribution rubric, footprint ladder, plugin/skill/toolset internals, prompt-caching policy, profile rules, testing standards |
| `CONTRIBUTING.md` | upstream | Cross-platform (Windows) rules and the skill-vs-tool decision guide |

`AGENTS.md` and `CONTRIBUTING.md` describe the framework as an upstream dev checkout. `SPZ.md`
describes what this fork actually does with it, and where the two disagree about scope — most often
about whether to write Python at all — `SPZ.md` governs.
