# The UK tax system, structurally

Written for reasoning, not for filing. **Structure is stable; rates and
thresholds change every April and several are frozen only until a stated year.
Never quote a rate from this file as current — say what the mechanism is and
send Zach to GOV.UK or his accountant for the number.** Written against
knowledge current to mid-2026; today's date is later than that.

## The shape of it

Three separate charges land on the same money and are often confused:

1. **Income Tax** — on income above the personal allowance, in bands. The
   allowance itself tapers away once income passes a high threshold, which
   creates an effective marginal rate well above the headline band rate in
   that taper zone. This is the single most commonly missed feature of the
   system and it matters most to someone with a good year.
2. **National Insurance** — a separate charge with its own thresholds. The
   self-employed pay Class 4 on profits; Class 2 was abolished from April 2024
   but remains payable voluntarily to protect the State Pension record for
   those below the small profits threshold. NI is not charged on dividends,
   which is the mechanic behind most sole-trader-vs-company comparisons.
3. **VAT** — not a tax on him at all, but on his customers, collected by him.
   See `vat.md`. Treating VAT-inclusive turnover as income is the error that
   makes a business look more profitable than it is.

## Sole trader versus limited company

The comparison Zach is most likely to face, and it is not only about tax.

| | Sole trader | Limited company |
|---|---|---|
| Legal identity | None separate — his debts | Separate legal person |
| Liability | Unlimited, personal | Limited to share capital, subject to director duties |
| Profit taxed as | Income Tax + Class 4 NI on profits | Corporation Tax on profits, then Income Tax on how he extracts it |
| Extraction | Just take it — drawings are not an expense | Salary (deductible, NI applies) and/or dividends (not deductible, no NI, own rates) |
| Losses | Can often be set against other income | Locked in the company |
| Filing | Self Assessment | Annual accounts + CT return + confirmation statement, all public |
| Admin cost | Low | Meaningfully higher, ongoing |

**The usual crossover logic:** at low profits the sole trader wins on
simplicity and total cost; as profits rise, a salary-plus-dividend mix through
a company usually wins on tax, because dividends escape NI and Corporation Tax
is charged before extraction. Where that crossover sits depends on current
rates, how much he needs to draw, and whether he wants to leave profit in the
business — so it is an accountant's calculation with his actual numbers, not
a rule of thumb. **Do not tell Zach a crossover figure.** State the mechanism,
say it depends on the numbers, offer to help assemble them.

Two things that are not about tax and often decide it anyway: limited
liability, and how suppliers, platforms and payment processors treat a company
versus an individual.

## Allowable expenses, and the test that governs them

The statutory test is **wholly and exclusively for the purposes of the trade**.
Not "mostly", and not "reasonable". Where something serves both business and
private purposes, only an identifiable business proportion is allowable, and
the apportionment has to be defensible if asked.

Categories that plausibly arise for content-and-ecommerce work:

- Cost of goods, packaging, fulfilment and shipping
- Platform, software and subscription fees — including AI tooling, editing
  software, scheduling tools, hosting
- Advertising and marketing
- Professional fees — accountant, legal
- Equipment: cameras, lighting, computers. Larger items are capital rather
  than a simple expense; capital allowances (and the annual investment
  allowance) are the mechanism, and the treatment differs from a consumable.
- Use of home as office — either a defensible proportion of actual costs, or
  the flat monthly rate
- Travel and motoring — either actual costs apportioned, or flat mileage rates.
  **Ordinary commuting is not allowable**, which surprises people.
- Phone and broadband — business proportion only

**Two hard limits worth stating plainly.** Client entertaining is not
allowable. And clothing is not allowable unless it is genuinely protective or
a uniform — ordinary clothes worn for filming are not deductible however much
they exist for the business.

## Why none of this can be computed from his data

His categories come from `hmrc_category_rules`, which are hand-typed substring
matches over a personal current account (see `personal.md`). They were built
to answer "what did I spend on food", not "what is allowable". So:

- a category total mixes allowable and private spending
- nothing marks the business proportion of a dual-use cost
- capital items are not separated from consumables
- and income is invisible entirely, so profit cannot be derived

**A category total is a conversation starter, never a figure for a return.**
Say that whenever a number from `get_spend_by_category` is about to be treated
as an expense claim.

## Records

Records must be kept and be adequate to support the return; digital
record-keeping and periodic filing through compatible software applies under
Making Tax Digital, already for VAT and phasing in for Income Tax from April
2026 by qualifying-income band. Retention periods differ between the
self-employed and companies. Check the current requirement rather than
assuming — this is an area that has changed repeatedly and is still changing.
