-- 50_analysis.sql
-- Analytical queries against the mart. These are the questions the model was
-- built to answer, and the ones worth putting on a dashboard.
--
-- Run them one at a time. Each is annotated with what it shows and what to be
-- careful about.
--
-- A note on averages: flood severity is heavily right-skewed - the mean sits
-- roughly three times the median. Every severity query here uses percentiles.
-- A dashboard that leads with "average claim" is reporting a number that
-- describes almost no actual claim.

-- ===========================================================================
-- 1. Severity by flood zone, and whether floodplain standards show up
-- ===========================================================================
-- Post-FIRM buildings were constructed to floodplain management standards;
-- pre-FIRM ones were not. If the standards work, post-FIRM buildings in the
-- same zone should show lower median payments. Comparing across zones instead
-- of within them would confound the two effects.
SELECT z.zone_group,
       f.is_post_firm,
       count(*)                                                     AS paid_claims,
       round(percentile_cont(0.50) WITHIN GROUP
             (ORDER BY f.building_paid)::numeric)                   AS median_paid,
       round(percentile_cont(0.90) WITHIN GROUP
             (ORDER BY f.building_paid)::numeric)                   AS p90_paid,
       round(avg(f.building_loss_ratio), 3)                         AS avg_share_of_limit
  FROM nfip_mart.fact_claim f
  JOIN nfip_mart.dim_flood_zone z ON z.flood_zone_key = f.flood_zone_key
 WHERE f.is_paid
   AND f.is_post_firm IS NOT NULL
 GROUP BY 1, 2
HAVING count(*) >= 100
 ORDER BY z.zone_group, f.is_post_firm;


-- ===========================================================================
-- 2. The denial picture
-- ===========================================================================
-- Why claims close without payment. Administrative codes (98, 99) are data
-- corrections rather than real outcomes, so is_real_outcome filters them out -
-- including them would inflate any denial rate with clerical noise.
SELECT r.reason_group,
       r.reason_description,
       count(*)                                        AS claims,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct_of_non_payments
  FROM nfip_mart.fact_claim f
  JOIN nfip_mart.dim_non_payment_reason r ON r.reason_key = f.reason_key
 WHERE f.is_closed_without_payment
   AND r.is_real_outcome
 GROUP BY 1, 2
 ORDER BY claims DESC;


-- ===========================================================================
-- 3. Event ranking, named storms only
-- ===========================================================================
-- is_named_storm excludes the generic 'Flooding' and 'Not a named storm'
-- labels, which together cover hundreds of thousands of claims and would
-- otherwise top this list without being events.
SELECT e.event_name,
       e.first_loss_date,
       count(*)                                           AS claims,
       round(sum(f.total_paid))                           AS total_paid,
       round(percentile_cont(0.50) WITHIN GROUP
             (ORDER BY f.building_paid) FILTER (WHERE f.is_paid)::numeric) AS median_paid,
       count(DISTINCT f.state_abbr)                       AS states_hit
  FROM nfip_mart.fact_claim f
  JOIN nfip_mart.dim_event e ON e.event_key = f.event_key
 WHERE e.is_named_storm
 GROUP BY 1, 2
 ORDER BY total_paid DESC
 LIMIT 20;


-- ===========================================================================
-- 4. Loss development over time, with a rolling view
-- ===========================================================================
-- Window functions over a yearly aggregate. The 3-year moving average smooths
-- the single-event spikes (Katrina 2005, Sandy 2012, Harvey 2017) enough to
-- show the underlying trend without hiding them.
WITH yearly AS (
  SELECT d.year,
         count(*)                   AS claims,
         sum(f.total_paid)          AS total_paid
    FROM nfip_mart.fact_claim f
    JOIN ref.dim_date d ON d.date_key = f.date_key
   GROUP BY 1
)
SELECT year,
       claims,
       round(total_paid)                                                AS total_paid,
       round(avg(total_paid) OVER (ORDER BY year
                                   ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)) AS paid_3yr_avg,
       round(100.0 * (total_paid - LAG(total_paid) OVER (ORDER BY year))
             / NULLIF(LAG(total_paid) OVER (ORDER BY year), 0), 1)      AS yoy_pct_change
  FROM yearly
 ORDER BY year;


-- ===========================================================================
-- 5. Where the exposure concentrates
-- ===========================================================================
-- Claims and dollars by state, with each state's share of the national total.
-- The concentration here is extreme - a handful of Gulf and Atlantic states
-- carry most of the program.
SELECT s.state_name,
       s.is_territory,
       count(*)                                            AS claims,
       round(sum(f.total_paid))                            AS total_paid,
       round(100.0 * sum(f.total_paid)
             / sum(sum(f.total_paid)) OVER (), 1)          AS pct_of_national_paid,
       round(sum(sum(f.total_paid)) OVER (ORDER BY sum(f.total_paid) DESC)
             / sum(sum(f.total_paid)) OVER () * 100, 1)    AS running_pct
  FROM nfip_mart.fact_claim f
  JOIN ref.dim_state s ON s.state_fips = f.state_fips
 GROUP BY 1, 2
 ORDER BY total_paid DESC
 LIMIT 20;


-- ===========================================================================
-- 6. Occupancy mix and severity
-- ===========================================================================
-- occupancy_group collapses the legacy and Risk Rating 2.0 code generations.
-- Grouping on the raw code instead would split single-family into codes 1, 11
-- and 16 and make the largest category look like three smaller ones.
SELECT o.occupancy_group,
       o.is_residential,
       count(*)                                         AS claims,
       round(percentile_cont(0.50) WITHIN GROUP
             (ORDER BY f.building_paid) FILTER (WHERE f.is_paid)::numeric) AS median_paid,
       round(100.0 * count(*) FILTER (WHERE f.is_closed_without_payment)
             / count(*), 1)                             AS pct_closed_unpaid
  FROM nfip_mart.fact_claim f
  JOIN nfip_mart.dim_occupancy o ON o.occupancy_key = f.occupancy_key
 GROUP BY 1, 2
 ORDER BY claims DESC;


-- ===========================================================================
-- 7. Claim cycle time
-- ===========================================================================
-- Days from opening a claim to the most recent payment. An operational metric
-- rather than an underwriting one, and the kind of thing a dashboard audience
-- actually acts on.
SELECT d.year,
       count(*) FILTER (WHERE f.days_open_to_payment IS NOT NULL) AS claims_with_both_dates,
       round(percentile_cont(0.50) WITHIN GROUP
             (ORDER BY f.days_open_to_payment)::numeric)          AS median_days,
       round(percentile_cont(0.90) WITHIN GROUP
             (ORDER BY f.days_open_to_payment)::numeric)          AS p90_days
  FROM nfip_mart.fact_claim f
  JOIN ref.dim_date d ON d.date_key = f.date_key
 WHERE f.days_open_to_payment IS NOT NULL
   AND f.days_open_to_payment BETWEEN 0 AND 3650
 GROUP BY 1
HAVING count(*) >= 50
 ORDER BY d.year DESC
 LIMIT 25;


-- ===========================================================================
-- 8. Cause of loss, perils only
-- ===========================================================================
-- is_peril excludes codes B, C and D, which describe how the claim was
-- adjusted rather than what caused the loss. Charting them alongside real
-- perils would imply "expedited handling" is a kind of flood.
SELECT c.cause_description,
       count(*)                                         AS claims,
       round(percentile_cont(0.50) WITHIN GROUP
             (ORDER BY f.building_paid) FILTER (WHERE f.is_paid)::numeric) AS median_paid
  FROM nfip_mart.fact_claim f
  JOIN nfip_mart.dim_cause_of_damage c ON c.cause_key = f.cause_key
 WHERE c.is_peril
 GROUP BY 1
 ORDER BY claims DESC;
