# Operational traps

Facts about the pipeline, derived from the dashboard code rather than from
experience. These are stable and checkable in `../spz-dashboard`.

## Posts are created one at a time, on purpose

Deletes fan out concurrently; **creates do not**. Every account in a store is
handed the same Drive video URL, and OneUp fetches that URL itself to build
the post. Concurrent creates therefore become concurrent fetches of one Drive
file, and OneUp answers all but the first with
`{"message":"Please provide a valid video URL"}`.

This already broke content-ops once and was fixed there before the same shape
was fixed here. If a scheduling run reports most accounts failing with a
"valid video URL" complaint, this is the cause — not a bad file, and not a
Drive permissions problem, which is what it looks like.

## Times are London wall-clock

OneUp's `schedulevideopost` takes `YYYY-MM-DD HH:MM` as Europe/London local
time, not UTC and not ISO. The dashboard converts both ways using a real
offset lookup so it stays correct across the March and October changes.

Consequence for you: never convert a time to UTC when discussing a schedule,
and never assume a fixed +00:00 or +01:00. Quote what Zach set.

## Store config is a database row, not code

`organic_ecom_stores` plus a write-only `organic_ecom_store_secrets` table
holds each store's OneUp key, Drive folder, category and accounts. It used to
be two hand-synced hardcoded arrays. So a store's setup can change without any
deploy, and anything you remember about a store's accounts may be stale —
prefer asking over asserting.

## A blank secret means "keep the current one"

When a store is edited, an empty OneUp key field deliberately leaves the
stored key untouched rather than clearing it. If Zach thinks he cleared a key
and it still works, this is why.
