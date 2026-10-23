# Modeling decisions

Choices made building this, what was rejected, and why. Written as I went, so
the reasoning is the actual reasoning rather than a reconstruction.

---

## Raw stays untyped

Every column in `nfip_raw.nfip_claims` is `text`.

A reload is then byte-for-byte reproducible, and no value is lost to a cast
that silently fails or coerces. All 84 columns land regardless of what FEMA
changes between refreshes. Typing happens in staging, where a failure is
visible and attributable.

**Rejected:** typing on load. It's faster, but a schema change upstream then
breaks the load rather than the transform, and you lose the ability to see what
the source actually sent.

---

## NULL payment is not zero payment

The single most consequential decision here.

| State | Claims | Meaning |
|---|---:|---|
| No building payment | 567,072 | Claim closed without any building payment |
| Paid zero | 150,854 | Adjudicated, came to zero |
| Negative | 84 | Re-issued check |
| Paid | 2,007,979 | Positive payment |

`AVG(amount_paid_on_building_claim)` treats these as the same thing and is
wrong by roughly 26% of the denominator. `payment_status` keeps them separate,
and `non_payment_reason_building` explains the first group.

**Why it matters:** "average claim severity" means *average over claims that
paid*. Including closed-without-payment claims answers a different question —
one nobody asked.

---

## Negative payments are kept, not filtered

84 claims have a negative building payment. FEMA's definition: these occur when
a check issued to a policyholder isn't cashed and has to be re-issued.

They're flagged (`is_negative_adjustment`) rather than dropped. Dropping rows
because they look odd is how a total stops reconciling to its source, and the
reconciliation test would catch it anyway.

---

## Water depth is left in its ambiguous unit

FEMA's own field definition: *"Depth of flood water in inches. Note: there are
instances where measurements were provided in feet."*

There's no flag distinguishing them. A value of `8` could be eight inches or
eight feet.

`water_depth_suspect` marks values above 120 (ten feet). The value itself is
**not** converted, because picking a unit per row would invent precision the
source doesn't have. The flag lets an analyst exclude them; a silent conversion
would let them believe a number that was guessed.

**Rejected:** converting anything over 120 by dividing by 12. It assumes the
threshold is right, and a genuine 11-foot flood becomes 11 inches.

---

## Occupancy codes span two generations

Single-digit codes are legacy; two-digit codes (11–19) came in with Risk
Rating 2.0. Code `1` and code `11` both mean single-family residence.

Grouping on the raw code splits the largest category into three
(`1`: 1.79M, `11`: 418k, `16`: 10.7k) and makes single-family look smaller
than it is. `occupancy_group` collapses them; the raw code stays available for
drill-down.

---

## Flood zone groups on the leading letter

`rated_flood_zone` has around 70 distinct values. The meaning lives in the
first character — A and V are Special Flood Hazard Areas, B/C/X are not — and
the digits distinguish mapping vintages (`A07` vs `AE`) rather than risk.

Grouping on the full code produces a long tail of near-identical categories.
`dim_flood_zone` carries both, so a dashboard can group on `zone_group` and
drill to `flood_zone_code`.

---

## Three cause codes aren't perils

Codes B, C and D describe the *claim handling process* — expedited handling,
remote adjustment — not what damaged the building. They sit in the same column
as real perils.

`is_peril` separates them. Charting them together implies "expedited claim
handling" is a kind of flood.

Five values (`5`, `6`, `@`, `N`, `Z`, 25 rows total) appear in the data but not
in FEMA's published list. They're kept, marked `is_published_code = false`, and
grouped as unknown. Someone will eventually ask what `@` means; the honest
answer is recorded rather than hidden.

---

## Administrative non-payment codes aren't denials

Codes 98 (*error — delete claim*) and 99 (*erroneous assignment*) are data
corrections, not claim outcomes. Together they're about 86,000 rows.

`is_real_outcome` excludes them. A denial rate that includes clerical cleanup
overstates denials.

---

## Reference dimensions are sized to the data

`ref.dim_date` spans **1968–2035**. The lower bound is the year the National
Flood Insurance Program was created; the earliest loss in the data is 1978. A
date dimension that starts later leaves early claims with a NULL date key, and
a NULL key disappears from a Power BI relationship silently rather than
failing — so the range is chosen against `min(date_of_loss)`, not a default.

`ref.dim_state` covers the 50 states, DC, and the US territories. The claims
data contains 57 distinct state values because the NFIP writes in Puerto Rico,
Guam and the US Virgin Islands.

Both live in `ref` rather than `nfip_mart` because they are conformed: a second
dataset loaded into this database joins to the same calendar and the same
geography, which is what makes cross-source analysis possible later.

`tests/data_quality.sql` fails the build if any fact row has an unresolved
dimension key.

---

## Grain is declared and enforced

One row per claim, at every layer. `claim_id` is the primary key on both
`nfip_stg.claims` and `nfip_mart.fact_claim`, so a duplicate fails the build
rather than double-counting a total months later.

Confirmed on the real data: 2,725,989 rows, 2,725,989 distinct ids.

**Caveat worth stating:** `policy_count` is not always 1. A Residential
Condominium Building Association Policy covers many units under one contract.
Claim count and policy count are different numbers, and `COUNT(*)` gives the
former.

---

## What this dataset cannot do

FEMA removed policy and policyholder identifiers in 2019. Claims cannot be
traced to a property or deduplicated, so repeat-loss analysis is impossible
here — FEMA publishes a separate Multiple Loss Properties dataset for that.

Latitude and longitude are rounded to one decimal place, roughly 11 km. Usable
for a state or regional heat map, useless for anything finer.

Both limits are recorded in the column comments, so an analyst hits the
explanation before they hit the wrong conclusion.

---

## What the tests found on the real 2.7M rows

Every structural check passed — grain, row-count reconciliation across layers,
referential integrity, payment logic, total reconciliation. The interesting
output was the four things that *didn't* come back clean. None are pipeline
bugs; all are properties of the source worth knowing before charting it.

### 14,988 claims were paid before they were opened (0.55%)

`most_recent_payment_date` precedes `open_date`. The most plausible reading is
that `open_date` records when the claim file was created in FEMA's current
system rather than when the claim was originally reported — a migration
artifact in older records, not time travel.

**Consequence:** any cycle-time metric has to filter `days_open_to_payment >= 0`
or a handful of large negative durations drag the average sideways.
`sql/50_analysis.sql` query 7 bounds it to 0–3650 days for exactly this reason.

### 8,015 claims have a loss date before construction (0.29%)

Either `original_construction_date` is wrong, or the building was substantially
rebuilt after an earlier loss and re-dated. Both happen. `building_age_at_loss`
goes negative for these, so it needs the same guard.

### 9,069 claims paid more than 105% of the building limit (0.33%)

This one is **correct behaviour, not an error**. Increased Cost of Compliance
coverage sits outside the building limit, so a claim can legitimately pay more
than `total_building_insurance_coverage`. The test reports it as a note rather
than a failure because the alternative — flagging it as bad data — would train
you to ignore the check.

### 16,442 claims have no usable geography (0.60%)

16,441 carry the state code `UN` and one is blank. The `UN` rows have **zero**
distinct county codes between them, and the code stops appearing after June
2011 — a legacy FEMA placeholder for "location not recorded," retired rather
than meaningful.

They get an explicit unknown member in `ref.dim_state` flagged
`is_unknown_member`, so they stay countable but can be excluded from a map in
one predicate. Leaving them to resolve as NULL would have dropped them from
every state visual without saying so.

### 5,069 claims have an implausible water depth (0.19%)

Over 120 inches, i.e. more than ten feet. Flagged, not converted — see the
water depth section above.

---

## Unknown members instead of NULL keys

Every dimension has a row for the unrecorded case (`(blank)`), and the fact
table has no NULL foreign keys.

A NULL key drops the row from an inner join. In a BI tool that happens silently
and the totals just come out low. An explicit unknown member keeps "we don't
know" visible in the output, where someone can see it and ask.
