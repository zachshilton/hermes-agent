# Personal money

Day-to-day spending and balances. Everything here is bank data — see
`../SKILL.md` for what the tools exclude.

## Accounts

| Account | Source | Visible to you? |
|---|---|---|
| Monzo | Monzo API, live | Yes, via `get_account_balances` |
| [UNCONFIRMED] any other current account | CSV import | Only if imported |
| [UNCONFIRMED] savings | — | No |
| [UNCONFIRMED] credit cards | — | No |

Zach has not yet confirmed which accounts exist beyond Monzo. Until he does,
say "your Monzo balance" rather than "your balance".

## How transactions arrive

- Monzo syncs on a cron, upserting on `(user_id, source, external_id)`. A
  re-run over the same window changes nothing, so a duplicate-looking
  transaction is a real second payment, not a sync artefact.
- CSV import exists for banks with no API. An imported month may stop
  abruptly — the end of a CSV is not the end of his spending.
- Categorisation is substring matching against his own rules, applied at
  write time. Re-categorising means editing a rule, not editing the row.

## Recurring costs

[UNCONFIRMED] — Zach has not listed his subscriptions and standing orders.
`search_transactions` can find a specific one by name, but nothing enumerates
them, so do not present a list as complete.

## How he wants spending framed

[UNCONFIRMED] — no budget, target or threshold has been set. Until one is,
report what he spent and compare months when asked; do not editorialise about
whether an amount is high, and do not invent a budget to measure it against.

## Useful shapes

- "How much did I spend at X" -> `search_transactions`, quote the total out
  and the count, note the window is whatever matched.
- "What did I spend on food last month" -> `get_spend_by_category` with the
  month as `YYYY-MM`. Category names are his, so echo them as returned.
- "Am I up or down this month" -> you cannot answer this. Income is filtered
  out of every tool. Say that.
