# Diagnosing why something is not working

The most operationally useful material in the whole corpus, because it turns
"it's not working" into a decision tree instead of a guess — and none of it needs
data Zach cannot get.

## The funnel test — run this first, always

| Symptom | Diagnosis |
|---|---|
| Views, but no website sessions | **The product is bad.** |
| Views + sessions, but few add-to-carts | **The offer is bad** — price, shipping terms, missing upsell. NOT the product. |
| Views + sessions + reasonable add-to-carts | Keep running it. You are close. |

The middle row is the one people get wrong: they kill a product that was fine and
had a broken offer.

## Then check WHO the traffic is

**Always segment sessions by geography before concluding anything about the offer
or the site.** Two worked cases:

- Reported CVR **0.3%** across mixed US/India/other traffic. Isolating genuine US
  sessions gave **"a fat 1%"**. The bottleneck was targeting.
- Reported **3%**; roughly 10,000 US + 10,000 India + 10,000 other of ~33,000
  sessions. Real US-only was **"1.1"**.

Fix in both: push traffic to US, UK, Germany, Western Europe.

**Compute CVR on real sessions only**, stripping countries with no purchasing
power. And upstream of that: **chase view quality, not view count** — 100,000 US
views beat 1,000,000 from a market that cannot buy. Purchasing power is called one
of the single biggest conversion factors.

## Benchmarks
- Typical organic CVR: **0.8-0.9% to 1-1.2%**. **Above 1.5-2% is good.**
- A value product should sit "around 2%".
- Adjusted target: "just under 1%" on real sessions.
- Engagement floor: about **100 likes per 1,000 views**, with 80-90 the lowest
  acceptable.

## Finding the outlier, then the variable
- An outlier is measured **against your own baseline**, never an absolute count.
- **A small outlier still counts** — it does not have to be a 7x.
- Once a variable looks like the driver, **double down on it** and keep testing
  others around it.
- To fix a weak creative, check retention/drop-off in native insights, find where
  viewers leave, change the variable **at that exact point**, and retest.
- **Test the hook independently** from the rest of the creative — the first ~2
  seconds is its own variable.

## Two failure modes that look like creative problems but are not
1. **Account health.** Most creative underperformance is attributed to an account
   that was never properly warmed up, not to the creative. Do not polish creatives
   while skipping warm-up.
2. **Virality without product awareness.** A video can go viral with nobody
   registering what is being sold, and it converts nothing. Red Bull can afford
   pure virality; an unknown store cannot. Controversy must never take more visual
   attention than the product, or cast it negatively.

## What Zach can and cannot run
He can run **all of this except the first step of finding the outlier**, because no
SPZ tool sees per-post performance. The data exists in native Instagram/TikTok
insights and behind a VidIQ overlay — it is simply not connected.

So the right move when he says something is or is not working: **ask him which
posts were the outliers, then apply the tree.** Counting how many videos have gone
out for a product IS something SPZ can do, and that is the input the 7-10 rule and
the 10-13 day cadence both turn on.
