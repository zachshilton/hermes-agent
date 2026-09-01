---
name: organic-ecom
description: "Zach's ecom: zenpup, hushora, captions, posting, growth."
version: 1.0.0
author: SPZ
license: MIT
metadata:
  hermes:
    tags: [ecom, ecommerce, organic, social, captions, oneup, clz, zenpup, hushora]
    category: ecom
    # Same gate as zach-finances: a cron turn has no skill_view to load this
    # with, so listing it there bills the roundup for an index it cannot use.
    requires_toolsets: [skills]
---

# Organic Ecom

Zach runs organic ecom stores: short-form video posted to social accounts to
drive store sales, rather than paid ads. Read this before answering anything
about the stores, captions, posting or what is working.

## The two stores

| Store | Slug |
|---|---|
| ZenPup | `zenpup` |
| Hushora | `hushora` |

Each is a row in `organic_ecom_stores` carrying its own OneUp API key, Google
Drive folder, OneUp category and a list of social network account ids. They
are independent: a rule that works for one is not automatically right for the
other, and their accounts never share a post.

## How a video becomes a post

    Drive folder -> caption drafted -> queued with a time -> OneUp -> one post PER ACCOUNT

Two details that are easy to get wrong:

- **One post per account, each with its own caption.** Not one shared post
  fanned out. If Zach asks how many posts a video made, the answer is the
  number of accounts in that store's category.
- **Schedules are Europe/London wall-clock, not UTC.** The code converts
  explicitly and is DST-correct. A time quoted back to Zach should be London
  local, because that is what he set.

## What you can and cannot do here

| | |
|---|---|
| `get_clz_memory` | Read what CLZ has learned and its recent corrections |
| `instruct_clz` | Correct CLZ's caption/scheduling behaviour, in Zach's words |
| Publishing to a store | **You cannot.** No MCP tool touches the store queues — that is the dashboard UI |

CLZ is the agent that drafts captions and schedules for these stores. Your
role is to shape CLZ, not to do CLZ's job. Before suggesting an
`instruct_clz`, read `get_clz_memory` — the instruction may already be there
and repeating it dilutes rather than reinforces.

**Do not confuse this with content-ops.** You *do* hold `submit_video`, which
is a real irreversible OneUp publish, but it belongs to the content-ops
pipeline (editors, cuts, categories), not to these stores. Calling it because
someone asked about ZenPup would publish the wrong thing, permanently.

## The blind spot, and it is the big one

**Nothing in this system measures whether any of it sells.** There is no
Shopify, TikTok Shop, Stripe or any commerce integration; no views,
impressions, engagement or click data; no per-post performance of any kind.
The entire ecom surface is publish-side.

So you can say *what was posted, to which accounts, and when*. You cannot say
what is working, what is winning, what to scale, or what a video did.

**But the data exists — it is just not connected to you.** Views, retention and
drop-off live in native Instagram/TikTok insights, and his method reads
outliers off a VidIQ overlay (see `references/playbook.md`). So this is an
integration gap, not an absence, and that changes what a good answer looks
like. Do not stop at "I cannot see that": **ask Zach which posts were the
outliers**, then apply the method to what he tells you. He can see them in
seconds; you cannot see them at all. Counting how many videos have gone out
for a product IS something you can do, and it is the input his testing
timeline turns on.

## Going deeper

- `references/playbook.md` — the growth rules Zach works to (mostly still blank)
- `references/extracted-lessons.md` — what was captured from the course itself
- `references/course-map.md` — all 33 lesson titles, so you can ask him about a specific one
- `references/operations.md` — the traps in the posting pipeline

## When a fact is missing

`[UNCONFIRMED]` means Zach has not supplied it yet. Treat it as unknown and
ask. **Never fill one with a plausible-sounding rule**: an invented posting
cadence or hook formula sounds exactly like a real one, and he will act on it.
