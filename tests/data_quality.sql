-- tests/data_quality.sql
-- Assertions that fail loudly.
--
--   psql -d portfolio -v ON_ERROR_STOP=1 -f tests/data_quality.sql
--
-- Every check RAISES EXCEPTION on failure, so a bad build stops the script
-- with a non-zero exit code instead of producing a dashboard full of quietly
-- wrong numbers. Run it after any rebuild.
--
-- Checks that are expected to find something are written as warnings with a
-- tolerance rather than hard failures - the point is to catch drift from a
-- known baseline, not to pretend public data is clean.

\set ON_ERROR_STOP on

DO $$
DECLARE
  v_bad      bigint;
  v_total    bigint;
  v_expected bigint;
  v_pct      numeric;
  v_failures int := 0;
BEGIN
  RAISE NOTICE '';
  RAISE NOTICE '=== NFIP claims data quality ===';
  RAISE NOTICE '';

  -- -------------------------------------------------------------------------
  -- 1. GRAIN: the fact table is one row per claim.
  -- -------------------------------------------------------------------------
  SELECT count(*), count(DISTINCT claim_id) INTO v_total, v_bad
    FROM nfip_mart.fact_claim;
  IF v_total <> v_bad THEN
    RAISE EXCEPTION 'GRAIN VIOLATION: fact_claim has % rows but only % distinct claim_id', v_total, v_bad;
  END IF;
  RAISE NOTICE 'PASS  grain: % rows, all claim_id distinct', v_total;

  -- -------------------------------------------------------------------------
  -- 2. COMPLETENESS: no rows lost or invented between layers.
  -- -------------------------------------------------------------------------
  SELECT count(*) INTO v_expected FROM nfip_raw.nfip_claims;
  SELECT count(*) INTO v_bad      FROM nfip_stg.claims;
  IF v_bad <> v_expected THEN
    RAISE EXCEPTION 'ROW COUNT MISMATCH: raw has %, staging has %', v_expected, v_bad;
  END IF;
  SELECT count(*) INTO v_bad FROM nfip_mart.fact_claim;
  IF v_bad <> v_expected THEN
    RAISE EXCEPTION 'ROW COUNT MISMATCH: raw has %, fact has %', v_expected, v_bad;
  END IF;
  RAISE NOTICE 'PASS  completeness: raw = staging = fact = % rows', v_expected;

  -- -------------------------------------------------------------------------
  -- 3. REFERENTIAL INTEGRITY: every dimension key resolves.
  --    A NULL key means a join will silently drop the row in Power BI.
  -- -------------------------------------------------------------------------
  SELECT count(*) INTO v_bad FROM nfip_mart.fact_claim WHERE flood_zone_key IS NULL;
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'ORPHANED: % fact rows have no flood_zone_key', v_bad;
  END IF;
  SELECT count(*) INTO v_bad FROM nfip_mart.fact_claim WHERE occupancy_key IS NULL;
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'ORPHANED: % fact rows have no occupancy_key', v_bad;
  END IF;
  SELECT count(*) INTO v_bad FROM nfip_mart.fact_claim WHERE cause_key IS NULL;
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'ORPHANED: % fact rows have no cause_key', v_bad;
  END IF;
  SELECT count(*) INTO v_bad FROM nfip_mart.fact_claim WHERE event_key IS NULL;
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'ORPHANED: % fact rows have no event_key', v_bad;
  END IF;
  RAISE NOTICE 'PASS  referential integrity: no orphaned dimension keys';

  -- -------------------------------------------------------------------------
  -- 4. DIMENSION UNIQUENESS: no duplicate business keys.
  -- -------------------------------------------------------------------------
  SELECT count(*) INTO v_bad FROM (
    SELECT flood_zone_code FROM nfip_mart.dim_flood_zone
     GROUP BY 1 HAVING count(*) > 1) x;
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'DUPLICATE KEYS: dim_flood_zone has % duplicated codes', v_bad;
  END IF;
  RAISE NOTICE 'PASS  dimension keys unique';

  -- -------------------------------------------------------------------------
  -- 5. PAYMENT LOGIC: payment_status agrees with the underlying amount.
  --    This is the distinction the whole model rests on.
  -- -------------------------------------------------------------------------
  SELECT count(*) INTO v_bad FROM nfip_mart.fact_claim
   WHERE payment_status = 'paid' AND (building_paid IS NULL OR building_paid <= 0);
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'PAYMENT LOGIC: % rows marked paid but have no positive building payment', v_bad;
  END IF;
  SELECT count(*) INTO v_bad FROM nfip_mart.fact_claim
   WHERE payment_status = 'no building payment' AND building_paid IS NOT NULL;
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'PAYMENT LOGIC: % rows marked unpaid but carry a building payment', v_bad;
  END IF;
  RAISE NOTICE 'PASS  payment_status consistent with building_paid';

  -- -------------------------------------------------------------------------
  -- 6. TOTALS RECONCILE: sum of components equals total_paid.
  -- -------------------------------------------------------------------------
  SELECT count(*) INTO v_bad FROM nfip_mart.fact_claim
   WHERE abs(total_paid - (COALESCE(building_paid,0)
                         + COALESCE(contents_paid,0)
                         + COALESCE(icc_paid,0))) > 0.01;
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'TOTALS: % rows where total_paid does not equal its components', v_bad;
  END IF;
  RAISE NOTICE 'PASS  total_paid reconciles to its components';

  -- -------------------------------------------------------------------------
  -- 7. DATE SANITY: losses fall inside the program's lifetime.
  --    The NFIP began in 1968; a loss date before that or in the future is wrong.
  -- -------------------------------------------------------------------------
  -- A handful of odd dates in 2.7M rows is public-data noise; a systematic
  -- problem is not. Fail above 0.1%, warn below it.
  SELECT count(*) INTO v_bad FROM nfip_mart.fact_claim
   WHERE date_of_loss < DATE '1968-01-01'
      OR date_of_loss > CURRENT_DATE + 1;
  SELECT count(*) INTO v_total FROM nfip_mart.fact_claim;
  v_pct := round(100.0 * v_bad / NULLIF(v_total,0), 3);
  IF v_pct > 0.1 THEN
    RAISE EXCEPTION 'DATE SANITY: % claims (% percent) fall outside 1968..today', v_bad, v_pct;
  ELSIF v_bad > 0 THEN
    RAISE WARNING 'DATE SANITY: % claims (% percent) fall outside 1968..today', v_bad, v_pct;
    v_failures := v_failures + 1;
  ELSE
    RAISE NOTICE 'PASS  all loss dates within the program lifetime';
  END IF;

  -- -------------------------------------------------------------------------
  -- 8. CHRONOLOGY: a payment cannot precede the claim being opened.
  -- -------------------------------------------------------------------------
  SELECT count(*) INTO v_bad FROM nfip_mart.fact_claim
   WHERE days_open_to_payment < 0;
  IF v_bad > 0 THEN
    RAISE WARNING 'CHRONOLOGY: % claims were paid before they were opened', v_bad;
    v_failures := v_failures + 1;
  ELSE
    RAISE NOTICE 'PASS  no payments precede claim open date';
  END IF;

  -- -------------------------------------------------------------------------
  -- 9. BUILDING AGE: a loss cannot predate construction.
  -- -------------------------------------------------------------------------
  SELECT count(*) INTO v_bad FROM nfip_mart.fact_claim
   WHERE building_age_at_loss < 0;
  IF v_bad > 0 THEN
    RAISE WARNING 'BUILDING AGE: % claims have a loss date before construction', v_bad;
    v_failures := v_failures + 1;
  ELSE
    RAISE NOTICE 'PASS  no losses predate construction';
  END IF;

  -- -------------------------------------------------------------------------
  -- 10. GEOGRAPHY: states resolve to the reference dimension.
  --     Expected to find some - the data includes territories beyond the
  --     50 states and DC. Tolerance rather than a hard fail.
  -- -------------------------------------------------------------------------
  -- Every state now resolves, including the unknown placeholders, so a NULL
  -- key here is a real failure rather than expected noise.
  SELECT count(*) INTO v_bad FROM nfip_mart.fact_claim WHERE state_fips IS NULL;
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'GEOGRAPHY: % fact rows have no state key', v_bad;
  END IF;
  RAISE NOTICE 'PASS  geography: every claim resolves to a state member';

  -- Separately, report how much of the data has no real location. This is
  -- information, not a failure - but a map built without excluding it is wrong.
  SELECT count(*) INTO v_bad
    FROM nfip_mart.fact_claim f
    JOIN ref.dim_state s ON s.state_fips = f.state_fips
   WHERE s.is_unknown_member;
  SELECT count(*) INTO v_total FROM nfip_mart.fact_claim;
  v_pct := round(100.0 * v_bad / NULLIF(v_total,0), 2);
  RAISE NOTICE 'NOTE  % claims (% percent) have no real geography - exclude from maps', v_bad, v_pct;

  -- -------------------------------------------------------------------------
  -- 11. LOSS RATIO: a payment should not exceed its coverage limit by much.
  --     Some excess is legitimate (ICC sits outside the building limit), so
  --     this warns rather than fails.
  -- -------------------------------------------------------------------------
  SELECT count(*) INTO v_bad FROM nfip_mart.fact_claim
   WHERE building_loss_ratio > 1.05;
  IF v_bad > 0 THEN
    RAISE NOTICE 'NOTE  % claims paid more than 105 percent of the building limit - check ICC handling', v_bad;
  ELSE
    RAISE NOTICE 'PASS  no payments materially exceed coverage';
  END IF;

  -- -------------------------------------------------------------------------
  -- 12. WATER DEPTH: flag the unit ambiguity rather than hide it.
  -- -------------------------------------------------------------------------
  SELECT count(*) INTO v_bad FROM nfip_mart.fact_claim WHERE water_depth_suspect;
  RAISE NOTICE 'NOTE  % claims have water_depth > 120 (inches vs feet ambiguity)', v_bad;

  RAISE NOTICE '';
  IF v_failures > 0 THEN
    RAISE NOTICE '=== %  warning(s). Nothing fatal, but worth a look. ===', v_failures;
  ELSE
    RAISE NOTICE '=== All checks passed. ===';
  END IF;
  RAISE NOTICE '';
END $$;


-- A readable summary to eyeball after the assertions pass.
\echo 'Distribution summary:'
SELECT payment_status,
       count(*)                                           AS claims,
       round(100.0*count(*)/sum(count(*)) OVER (), 1)     AS pct,
       round(avg(building_paid) FILTER (WHERE building_paid > 0)) AS avg_paid_when_paid
  FROM nfip_mart.fact_claim
 GROUP BY 1
 ORDER BY claims DESC;
