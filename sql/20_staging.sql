-- 20_staging.sql
-- Typed, cleaned claims. One row per claim, same grain as raw.
--
--   psql -d portfolio -v ON_ERROR_STOP=1 -f sql/20_staging.sql
--
-- The raw layer is all text on purpose so a reload is reproducible and nothing
-- is lost to a bad cast. This is where types are applied and where the
-- awkward parts of the source are handled explicitly rather than silently.
--
-- Decisions made here, each with its reason:
--
--  1. NULL payment is not zero. 567,072 claims have no building payment value,
--     150,854 have an explicit zero. Those mean different things: closed
--     without payment versus adjudicated to nothing. payment_status keeps them
--     apart so an average severity figure cannot quietly include both.
--
--  2. Negative payments are kept. 84 rows are negative. Per FEMA these occur
--     when a check is not cashed and has to be re-issued - an accounting
--     artifact, not an error. They are flagged, not filtered, because dropping
--     rows silently is how totals stop reconciling.
--
--  3. water_depth is in inches "except where measurements were provided in
--     feet" (FEMA's own wording). There is no flag telling you which. Values
--     above 120 are treated as suspect rather than converted, because guessing
--     at the unit would invent precision the source does not have.
--
--  4. post_firm_construction_indicator arrives as both 'true'/'false' and
--     '1'/'0'. Normalised to a real boolean.
--
--  5. date_of_loss is an ISO 8601 timestamp with a Z suffix, defaulting to
--     midnight when no time was recorded. Cast to date - the time component
--     carries no information.
--
--  6. Columns over ~80% blank are carried through but not relied on. The
--     recovery columns (98.6% blank) are the clearest example: present in the
--     schema, almost never populated, and misleading if charted.
--
-- Safe to re-run.

\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS nfip_stg;

DROP TABLE IF EXISTS nfip_stg.claims CASCADE;

CREATE TABLE nfip_stg.claims AS
SELECT
    -- ---------- identity ----------------------------------------------------
    c.id                                                        AS claim_id,
    nullif(c.as_of_date,'')::timestamptz::date                  AS as_of_date,

    -- ---------- when --------------------------------------------------------
    nullif(c.date_of_loss,'')::timestamptz::date                AS date_of_loss,
    nullif(c.year_of_loss,'')::int                              AS year_of_loss,
    nullif(c.open_date,'')::timestamptz::date                   AS open_date,
    nullif(c.most_recent_payment_date,'')::timestamptz::date    AS most_recent_payment_date,
    nullif(c.original_construction_date,'')::timestamptz::date  AS original_construction_date,
    nullif(c.original_nb_date,'')::timestamptz::date            AS original_new_business_date,

    -- Claim cycle time. Only meaningful where both dates exist.
    CASE WHEN nullif(c.open_date,'') IS NOT NULL
          AND nullif(c.most_recent_payment_date,'') IS NOT NULL
         THEN (c.most_recent_payment_date::timestamptz::date
               - c.open_date::timestamptz::date)
    END                                                         AS days_open_to_payment,

    -- ---------- where -------------------------------------------------------
    nullif(c.state,'')                                          AS state_abbr,
    nullif(c.reported_city,'')                                  AS reported_city,
    nullif(c.reported_zip_code,'')                              AS reported_zip,
    nullif(c.county_code,'')                                    AS county_fips,
    nullif(c.census_geoid,'')                                   AS census_geoid,
    nullif(c.latitude,'')::numeric                              AS latitude,
    nullif(c.longitude,'')::numeric                             AS longitude,
    nullif(c.nfip_community_name,'')                            AS community_name,
    nullif(c.nfip_rated_community_number,'')                    AS community_number,

    -- ---------- the event ---------------------------------------------------
    -- 'Flooding' and 'Not a named storm' are generic labels, not named storms.
    -- Separating them keeps event analysis honest.
    nullif(c.flood_event,'')                                    AS flood_event,
    CASE
      WHEN nullif(c.flood_event,'') IS NULL                     THEN 'unnamed'
      WHEN c.flood_event IN ('Flooding','Not a named storm')    THEN 'generic label'
      ELSE                                                           'named event'
    END                                                         AS event_kind,
    COALESCE(nullif(c.cause_of_damage,''),'(blank)')            AS cause_code,

    -- ---------- risk attributes --------------------------------------------
    COALESCE(nullif(c.rated_flood_zone,''),'(blank)')           AS flood_zone_code,
    CASE WHEN nullif(c.rated_flood_zone,'') IS NULL THEN '(blank)'
         ELSE left(upper(c.rated_flood_zone),1) END             AS flood_zone_letter,
    COALESCE(nullif(c.occupancy_type,''),'(blank)')             AS occupancy_code,

    -- Mixed 'true'/'1' and 'false'/'0' representations, normalised.
    CASE WHEN lower(c.post_firm_construction_indicator) IN ('true','1')  THEN true
         WHEN lower(c.post_firm_construction_indicator) IN ('false','0') THEN false
    END                                                         AS is_post_firm,
    CASE WHEN lower(c.pre_firm_indicator) IN ('true','1')  THEN true
         WHEN lower(c.pre_firm_indicator) IN ('false','0') THEN false
    END                                                         AS is_pre_firm,
    CASE WHEN lower(c.elevated_building_indicator) IN ('true','1')  THEN true
         WHEN lower(c.elevated_building_indicator) IN ('false','0') THEN false
    END                                                         AS is_elevated_building,
    CASE WHEN lower(c.primary_residence_indicator) IN ('true','1')  THEN true
         WHEN lower(c.primary_residence_indicator) IN ('false','0') THEN false
    END                                                         AS is_primary_residence,
    CASE WHEN lower(c.small_business_indicator_building) IN ('true','1')  THEN true
         WHEN lower(c.small_business_indicator_building) IN ('false','0') THEN false
    END                                                         AS is_small_business,

    nullif(c.number_of_floors_in_the_insured_building,'')::int  AS number_of_floors,
    nullif(c.number_of_units,'')::int                           AS number_of_units,
    nullif(c.base_flood_elevation,'')::numeric                  AS base_flood_elevation,
    nullif(c.lowest_floor_elevation,'')::numeric                AS lowest_floor_elevation,
    nullif(c.elevation_difference,'')::numeric                  AS elevation_difference,
    nullif(c.crs_class_code,'')::int                            AS crs_class_code,

    -- FEMA: "Depth of flood water in inches. Note: there are instances where
    -- measurements were provided in feet." No flag distinguishes them, so the
    -- value is kept as-is and the suspicious ones are marked.
    nullif(c.water_depth,'')::numeric                           AS water_depth_raw,
    CASE WHEN nullif(c.water_depth,'')::numeric > 120 THEN true
         WHEN nullif(c.water_depth,'') IS NULL        THEN NULL
         ELSE false END                                         AS water_depth_suspect,

    -- ---------- coverage and money -----------------------------------------
    -- policy_count is normally 1, but a condo association policy (RCBAP)
    -- covers many units under one contract. Claim count and policy count are
    -- therefore not the same number.
    nullif(c.policy_count,'')::int                              AS policy_count,
    nullif(c.total_building_insurance_coverage,'')::numeric     AS building_coverage,
    nullif(c.total_contents_insurance_coverage,'')::numeric     AS contents_coverage,
    nullif(c.building_damage_amount,'')::numeric                AS building_damage_amount,
    nullif(c.contents_damage_amount,'')::numeric                AS contents_damage_amount,
    nullif(c.building_property_value,'')::numeric               AS building_property_value,

    nullif(c.amount_paid_on_building_claim,'')::numeric         AS building_paid,
    nullif(c.amount_paid_on_contents_claim,'')::numeric         AS contents_paid,
    nullif(c.amount_paid_on_increased_cost_of_compliance_claim,'')::numeric AS icc_paid,

    -- Total paid treats a missing component as zero, which is correct for a
    -- sum but would be wrong for an average - hence payment_status below.
    COALESCE(nullif(c.amount_paid_on_building_claim,'')::numeric, 0)
      + COALESCE(nullif(c.amount_paid_on_contents_claim,'')::numeric, 0)
      + COALESCE(nullif(c.amount_paid_on_increased_cost_of_compliance_claim,'')::numeric, 0)
                                                                AS total_paid,

    COALESCE(nullif(c.non_payment_reason_building,''),'(blank)') AS non_payment_reason_building_code,
    COALESCE(nullif(c.non_payment_reason_contents,''),'(blank)') AS non_payment_reason_contents_code,

    -- The distinction that matters most in this dataset.
    CASE
      WHEN nullif(c.amount_paid_on_building_claim,'') IS NULL        THEN 'no building payment'
      WHEN c.amount_paid_on_building_claim::numeric  < 0             THEN 'negative adjustment'
      WHEN c.amount_paid_on_building_claim::numeric  = 0             THEN 'paid zero'
      ELSE                                                                'paid'
    END                                                         AS payment_status,

    -- ---------- recoveries (98.6% blank - present, rarely usable) -----------
    nullif(c.total_salvage_recovery,'')::numeric                AS salvage_recovery,
    nullif(c.total_subrogation_recovery,'')::numeric            AS subrogation_recovery,
    nullif(c.total_bldg_claim_pmt_recovery,'')::numeric         AS building_payment_recovery

  FROM nfip_raw.nfip_claims c;


-- ---------------------------------------------------------------------------
-- Constraints and indexes
-- ---------------------------------------------------------------------------
-- The primary key is the grain assertion: if claim_id were not unique this
-- would fail loudly at build time rather than quietly double-counting later.
ALTER TABLE nfip_stg.claims ADD CONSTRAINT pk_stg_claims PRIMARY KEY (claim_id);

CREATE INDEX ix_stg_claims_loss_date ON nfip_stg.claims (date_of_loss);
CREATE INDEX ix_stg_claims_state     ON nfip_stg.claims (state_abbr);
CREATE INDEX ix_stg_claims_zone      ON nfip_stg.claims (flood_zone_letter);
CREATE INDEX ix_stg_claims_status    ON nfip_stg.claims (payment_status);

COMMENT ON TABLE nfip_stg.claims IS
  'GRAIN: one row per NFIP claim. Typed from nfip_raw.nfip_claims. Payments distinguish null (no payment) from zero (adjudicated to nothing) via payment_status.';

ANALYZE nfip_stg.claims;

\echo ''
\echo 'Staging built.'
SELECT count(*) AS rows,
       count(*) FILTER (WHERE date_of_loss IS NULL)  AS null_loss_dates,
       count(*) FILTER (WHERE state_abbr   IS NULL)  AS null_states,
       min(date_of_loss) AS earliest,
       max(date_of_loss) AS latest
  FROM nfip_stg.claims;

SELECT payment_status, count(*) AS claims
  FROM nfip_stg.claims GROUP BY 1 ORDER BY 2 DESC;
