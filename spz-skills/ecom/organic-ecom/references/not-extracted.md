# What was not extracted, and why

52 of ~139 videos were extracted. This lists the remainder precisely, so picking
it up later is a matter of running the recipe rather than re-deriving the list.

## Why these were left
Two reasons, and neither is that they were skipped casually:

1. **21 videos have permanently broken transcript panels.** The panel opens and
   never populates. One serves a zero-byte caption file at YouTube's end, so it is
   unrecoverable rather than flaky. Roughly a third of both channels behaves this
   way.
2. **The final batch hit a run of infrastructure failures** — five consecutive
   agents died on stalls and connection errors, not on the task. The remaining
   material is the lowest-value in the corpus, so it was not worth fighting.

## Still unextracted

### Lifestyle vlogs (@SmithRees) — lowest expected yield
7jjc7MeOTfo raw reality $75k/month (40:25)
2zGQUmmEbDk raw reality $60k/month (30:14)
eKzXe4Lxxog Realistic Day in the Life (14:52)
SIu2XCkLwzo Day in the Life 17yo (24:35)
YupwkhSf_kc day in my life $70k/month (13:05)
j_chc424Gpc day in the life $77k/month (34:17)
KkMDzkoH4jE week in my life $78k/month (50:05)
FIDzlHwF1iw building a 7 figure company (42:12)
X5ylqp7fR_s Week in the Life, Europe (48:01)
TIRpi0FRErU Week in the Life, LA (51:21)
QaAyb15S29g Swiss Alps (31:10)
uXedDtuRIy0 $20k weekend LA (18:32)
gLdaNpHoo1I 24 Hours in Paris (9:12)
pmrcLU_Hnso life in italy (7:03)
2rjTKR0SawI life in switzerland (14:07)
GV8QaDSFCg8 $23,000 in Romania (23:58)
htP77pAEAqQ mclarens in LA (29:36)
QUOjHOAQXkg mclarens in LA (37:51) -- possible re-upload of the above, unverified
c2RpvVbpw50 mclarens in miami (47:42)
5SiLToFrYoA flew to croatia (15:56)
M8tryvB8Fdk almost crashed a lambo (41:37)
uf4bPIyLhCo Malibu Alpaca Farm (7:12)

### Mindset (@SmithRees)
iAc5gsS5TSQ the exact mindset that made me $1M at 17 (59:39)
EzGSOkwBU6g Brainwash yourself to be rich (39:53)
e2yzfDzzAQg law of attraction to make $1M at 18 (26:29)
ieZ1AQANrGc i told myself i was rich (27:49)

### Origin stories (@SmithRees)
AitUgaTL60o Highschool Dropout to $75k/month (My Story) (45:45)
dr-AZRNy7GU broke to $75k a month at 18 (38:46)

### Mindset (@SmithReesBusiness)
M7trUVr4Nqo onlyfans money without selling your soul (9:10)
YvW4u9ATP2s rich so quick they think you're illuminati (18:32)
2MqFbKEXEL8 laziest way to become a millionaire (32:15)
RW0UnfZuORs brainwashed myself to get rich (21:44)
74bcqzyxF2A Raise Your Frequency (17:21)

## Expected yield if these are done later
**Low, and that is an evidence-based estimate rather than a guess.**

- Of nine identity/mindset videos already extracted, only two were substantially
  original and one added nothing at all. The four mindset videos above are very
  likely covered by `mindset.md` already.
- Of the lifestyle vlogs already mined, one in six produced anything — but the one
  that did produced the **double test order**, the best single tactic in the
  corpus. So the yield is low-probability, high-value, not zero.
- The two origin stories are the most likely of this list to contain something,
  because they may resolve the open conflict between "first three to five stores
  are proof of concept" and "first sale on my 7th store, $10k/month on my 12th".

## The recipe, if picking this up
It is documented in the commit history and in the agent prompts. The essentials:
open the transcript panel, strip the leading timestamp AND the compound
"1 minute, 2 seconds" label as LINES (never regex the whole text for durations --
that destroys genuinely spoken figures), then for vlogs regex-search the stored
text rather than reading it linearly.
