---
name: zach-finances
description: "Zach's money: balances, spending, income, tax and VAT."
version: 1.0.0
author: SPZ
license: MIT
metadata:
  hermes:
    tags: [finance, money, tax, vat, self-employment, monzo, hmrc]
    category: finance
    # Hidden on any turn without the `skills` toolset. A cron turn
    # (SPZ_CRON_TOOLSETS=clarify,memory,todo) has no skill_view to load
    # this with, so listing it there is schema nobody can act on.
    requires_toolsets: [skills]
---

# Zach's finances

Read this before answering any money question. It exists because the finance
tools return *prose*, not labelled data, and several of the things they leave
out look exactly like zeroes.

## What you can actually see

Three MCP tools, all reading the same Supabase table plus the Monzo API:

| Tool | Returns | Watch out |
|---|---|---|
| `get_account_balances` | Live Monzo balance per account | Monzo only. Any other bank is absent, not zero. |
| `search_transactions` | Matches on merchant or description, newest first | The total it quotes is **money out only**. Refunds and income matching the query are listed but not counted. |
| `get_spend_by_category` | One month's outgoings by category | One month per call. Money in is excluded by design. |

## The four things that will make you wrong

1. **Income is invisible, not absent.** Money-in rows are stored in
   `hmrc_transactions` with a positive `amount_minor`, and every tool above
   filters them out. Never conclude Zach has no income, or compute a
   profit, a margin, or a savings rate from these tools. You can see
   outgoings. You cannot see earnings. Say so rather than implying a
   number.
2. **"HMRC" in this system is a misnomer.** The `hmrc_transactions` and
   `hmrc_category_rules` tables, and the finance hub's name, are bank data
   from Monzo and CSV imports. There is **no HMRC API connection** — no
   filed returns, no VAT obligations, no self-assessment position, nothing
   owed. If asked what HMRC says, the honest answer is that you cannot see
   HMRC at all.
3. **Balances are not one bank.** `get_account_balances` covers Monzo.
   The store is deliberately source-agnostic and NatWest/Revolut are
   expected to arrive by CSV import, so "his balance" from this tool is a
   partial view whenever another account exists.
4. **Categories are his, not a standard chart of accounts.** They come from
   `hmrc_category_rules` — hand-typed substring matches, highest priority
   wins, falling back to Monzo's own category and then `uncategorised`.
   They are not HMRC expense categories and do not map onto a tax return
   without judgement. A large `uncategorised` total usually means a missing
   rule, not unusual spending.

## How to talk about money here

- Amounts arrive already formatted as GBP strings. Underneath they are
  minor units (pence) and are divided exactly once, at the edge. Do not
  re-scale anything you are handed.
- Give the figure, then the caveat, in that order. He wants the number
  first.
- Round to whole pounds when summarising a month; keep the pence when
  quoting a single transaction he asked about.
- Never invent a figure you did not get from a tool. "I can see X, I
  cannot see Y" is always better than a confident total that quietly
  excludes income.

## Acting, not just reporting

Every MCP tool on this deployment executes the moment you call it — there is
no approval step and no confirmation prompt. For finance that means read
freely, but treat anything that would move money, publish, or change a
record as needing Zach's explicit go-ahead in the same conversation.

## Going deeper

Load only what the question needs:

- `references/personal.md` — day-to-day money, accounts, recurring costs, how he wants spending framed
- `references/self-employment.md` — sole-trader income, allowable expenses, tax set-aside, self-assessment
- `references/vat.md` — VAT registration, scheme, returns and the MTD position

## When a fact is missing

These references carry `[UNCONFIRMED]` markers where Zach has not yet
supplied the detail. Treat an `[UNCONFIRMED]` line as unknown, not as a
default: ask him, or answer generally and say which specific fact you are
missing. **Never fill an `[UNCONFIRMED]` slot with a plausible-sounding
number, date, rate or reference.** A wrong VAT rate or year end stated
confidently is worse than no answer, because he will act on it.
