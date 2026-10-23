-- 40_facts.sql
-- The claims fact table.
--
--   psql -d portfolio -v ON_ERROR_STOP=1 -f sql/40_facts.sql
--
-- GRAIN: one row per NFIP claim. Same grain as staging and raw - this dataset
-- does not need aggregating, it needs conforming.
--
-- Every dimension reference resolves to a key, including the unknown cases,
-- so the fact table has no NULL foreign keys and a dashboard never silently
-- drops rows on an inner join. Unknowns get a real dimension row rather than
-- a NULL, which is the standard way to keep "we don't know" visible instead
-- of invisible.
--
-- Safe to re-run.

\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS nfip_mart;

DROP TABLE IF EXISTS nfip_mart.fact_claim CASCADE;

CREATE TABLE nfip_mart.fact_claim AS
SELECT
    s.claim_id,

    -- ---------- dimension keys ---------------------------------------------
    d.date_key,
    s.date_of_loss,
    st.state_fips,
    s.state_abbr,
    s.county_fips,
    z.flood_zone_key,
    o.occupancy_key,
    cz.cause_key,
    r.reason_key,
    e.event_key,

    -- ---------- degenerate dimensions --------------------------------------
    -- Kept on the fact rather than given their own tables: high cardinality,
    -- no attributes of their own, only ever used as a filter or label.
    s.reported_city,
    s.reported_zip,
    s.community_name,
    s.payment_status,

    -- ---------- measures: money --------------------------------------------
    s.building_coverage,
    s.contents_coverage,
    s.building_damage_amount,
    s.building_paid,
    s.contents_paid,
    s.icc_paid,
    s.total_paid,

    -- Share of the building limit consumed. NULLIF guards the divide and also
    -- excludes zero-coverage rows, where the ratio would be meaningless.
    CASE WHEN s.building_paid > 0
         THEN round(s.building_paid / NULLIF(s.building_coverage, 0), 4)
    END                                                     AS building_loss_ratio,

    -- ---------- measures: physical -----------------------------------------
    s.water_depth_raw,
    s.water_depth_suspect,
    s.elevation_difference,
    s.number_of_floors,
    s.number_of_units,
    s.crs_class_code,
    s.latitude,
    s.longitude,

    -- ---------- attributes -------------------------------------------------
    s.is_post_firm,
    s.is_elevated_building,
    s.is_primary_residence,
    s.is_small_business,
    s.policy_count,

    -- ---------- operational ------------------------------------------------
    s.open_date,
    s.most_recent_payment_date,
    s.days_open_to_payment,

    -- ---------- derived flags ----------------------------------------------
    (s.payment_status = 'paid')                             AS is_paid,
    (s.payment_status IN ('no building payment','paid zero')) AS is_closed_without_payment,
    (s.payment_status = 'negative adjustment')              AS is_negative_adjustment,

    -- Building age at the time of loss. Negative values would mean a loss
    -- recorded before the building existed, which the tests check for.
    CASE WHEN s.original_construction_date IS NOT NULL
          AND s.date_of_loss IS NOT NULL
         THEN extract(year FROM age(s.date_of_loss, s.original_construction_date))::int
    END                                                     AS building_age_at_loss

  FROM nfip_stg.claims s
  LEFT JOIN ref.dim_date                 d  ON d.full_date      = s.date_of_loss
  -- COALESCE routes the one genuinely blank state to the '--' unknown member,
  -- so the fact table has no NULL state key. 'UN' already matches its own member.
  LEFT JOIN ref.dim_state                st ON st.state_abbr    = COALESCE(s.state_abbr, '--')
  LEFT JOIN nfip_mart.dim_flood_zone     z  ON z.flood_zone_code = s.flood_zone_code
  LEFT JOIN nfip_mart.dim_occupancy      o  ON o.occupancy_code  = s.occupancy_code
  LEFT JOIN nfip_mart.dim_cause_of_damage cz ON cz.cause_code    = s.cause_code
  LEFT JOIN nfip_mart.dim_non_payment_reason r ON r.reason_code  = s.non_payment_reason_building_code
  LEFT JOIN nfip_mart.dim_event          e  ON e.event_name      = COALESCE(s.flood_event, '(unnamed)');


ALTER TABLE nfip_mart.fact_claim ADD CONSTRAINT pk_fact_claim PRIMARY KEY (claim_id);

CREATE INDEX ix_fact_claim_date   ON nfip_mart.fact_claim (date_key);
CREATE INDEX ix_fact_claim_state  ON nfip_mart.fact_claim (state_abbr);
CREATE INDEX ix_fact_claim_zone   ON nfip_mart.fact_claim (flood_zone_key);
CREATE INDEX ix_fact_claim_occ    ON nfip_mart.fact_claim (occupancy_key);
CREATE INDEX ix_fact_claim_event  ON nfip_mart.fact_claim (event_key);
CREATE INDEX ix_fact_claim_paid   ON nfip_mart.fact_claim (is_paid) WHERE is_paid;

COMMENT ON TABLE nfip_mart.fact_claim IS
  'GRAIN: one row per NFIP claim (2.7M rows, losses from 1978). Connect Power BI here. Filter is_paid for severity analysis; total_paid sums safely across all rows but averaging it across unpaid claims is wrong - use payment_status.';
COMMENT ON COLUMN nfip_mart.fact_claim.total_paid IS
  'Building + contents + ICC, treating missing components as zero. Safe to SUM. Do NOT average across all claims - 26% had no payment at all.';
COMMENT ON COLUMN nfip_mart.fact_claim.building_loss_ratio IS
  'building_paid / building_coverage, only where a payment was made. A value of 1.0 means the loss exhausted the policy limit.';
COMMENT ON COLUMN nfip_mart.fact_claim.water_depth_suspect IS
  'True where water_depth exceeds 120. FEMA records depth in inches but notes some values were entered in feet, with no flag distinguishing them.';

ANALYZE nfip_mart.fact_claim;


-- ---------------------------------------------------------------------------
-- A convenience view for Power BI: the fact joined to its dimensions, so the
-- semantic model can be thin. Measures still live in SQL.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS nfip_mart.vw_claim_detail;
CREATE VIEW nfip_mart.vw_claim_detail AS
SELECT f.claim_id,
       f.date_of_loss,
       d.year, d.quarter_label, d.month_name,
       f.state_abbr, st.state_name, f.county_fips, f.reported_city,
       z.flood_zone_code, z.zone_group, z.is_sfha,
       o.occupancy_group, o.is_residential,
       c.cause_description, c.is_peril,
       e.event_name, e.is_named_storm,
       r.reason_description, r.reason_group,
       f.payment_status, f.is_paid,
       f.building_coverage, f.building_paid, f.contents_paid, f.total_paid,
       f.building_loss_ratio, f.days_open_to_payment,
       f.is_post_firm, f.is_elevated_building, f.building_age_at_loss
  FROM nfip_mart.fact_claim f
  LEFT JOIN ref.dim_date d  ON d.date_key = f.date_key
  LEFT JOIN ref.dim_state st ON st.state_fips = f.state_fips
  LEFT JOIN nfip_mart.dim_flood_zone z ON z.flood_zone_key = f.flood_zone_key
  LEFT JOIN nfip_mart.dim_occupancy  o ON o.occupancy_key  = f.occupancy_key
  LEFT JOIN nfip_mart.dim_cause_of_damage c ON c.cause_key = f.cause_key
  LEFT JOIN nfip_mart.dim_event e ON e.event_key = f.event_key
  LEFT JOIN nfip_mart.dim_non_payment_reason r ON r.reason_key = f.reason_key;

COMMENT ON VIEW nfip_mart.vw_claim_detail IS
  'Flattened claim detail for Power BI. One row per claim with dimension attributes resolved.';


\echo ''
\echo 'Fact table built.'
SELECT count(*) AS claims,
       count(*) FILTER (WHERE date_key IS NULL)       AS unmatched_dates,
       count(*) FILTER (WHERE state_fips IS NULL)     AS unmatched_states,
       count(*) FILTER (WHERE flood_zone_key IS NULL) AS unmatched_zones,
       count(*) FILTER (WHERE occupancy_key IS NULL)  AS unmatched_occupancy,
       count(*) FILTER (WHERE cause_key IS NULL)      AS unmatched_cause,
       count(*) FILTER (WHERE event_key IS NULL)      AS unmatched_event
  FROM nfip_mart.fact_claim;
