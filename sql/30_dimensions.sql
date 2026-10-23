-- 30_dimensions.sql
-- Dimension tables for the claims star schema.
--
--   psql -d portfolio -v ON_ERROR_STOP=1 -f sql/30_dimensions.sql
--
-- ref.dim_date and ref.dim_state already exist and are shared across datasets,
-- so they are not rebuilt here. These are the dimensions specific to flood
-- claims, built from the source code lists in nfip_stg plus the groupings that
-- analysis actually needs.
--
-- All are Type 1: the source publishes code lists, not slowly changing
-- attributes, so there is no history to track.
--
-- Safe to re-run.

\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS nfip_mart;

-- ---------------------------------------------------------------------------
-- dim_cause_of_damage
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS nfip_mart.dim_cause_of_damage CASCADE;
CREATE TABLE nfip_mart.dim_cause_of_damage (
    cause_key         int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cause_code        text NOT NULL UNIQUE,
    cause_description text NOT NULL,
    cause_group       text NOT NULL,
    is_peril          boolean NOT NULL,
    is_published_code boolean NOT NULL
);
COMMENT ON TABLE nfip_mart.dim_cause_of_damage IS
  'GRAIN: one row per cause code. is_peril excludes the claim-handling process codes (B, C, D), which describe how a claim was adjusted rather than what caused the loss.';

INSERT INTO nfip_mart.dim_cause_of_damage
       (cause_code, cause_description, cause_group, is_peril, is_published_code)
SELECT cause_code, cause_description, cause_group,
       cause_group = 'peril',
       is_published_code
  FROM nfip_stg.lk_cause_of_damage;


-- ---------------------------------------------------------------------------
-- dim_occupancy
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS nfip_mart.dim_occupancy CASCADE;
CREATE TABLE nfip_mart.dim_occupancy (
    occupancy_key         int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occupancy_code        text NOT NULL UNIQUE,
    occupancy_description text NOT NULL,
    occupancy_group       text NOT NULL,
    is_residential        boolean,
    code_generation       text NOT NULL
);
COMMENT ON TABLE nfip_mart.dim_occupancy IS
  'GRAIN: one row per occupancy code. occupancy_group collapses the legacy and Risk Rating 2.0 code generations - slice on it, not on the raw code, or single-family splits into two categories.';

INSERT INTO nfip_mart.dim_occupancy
       (occupancy_code, occupancy_description, occupancy_group, is_residential, code_generation)
SELECT occupancy_code, occupancy_description, occupancy_group, is_residential, code_generation
  FROM nfip_stg.lk_occupancy_type;


-- ---------------------------------------------------------------------------
-- dim_flood_zone
-- ---------------------------------------------------------------------------
-- Built from the zone letters actually present in the data, joined to the
-- published groupings. Keeping both the full code and the letter lets a
-- dashboard drill from "A" down to AE / A07 / A99.
DROP TABLE IF EXISTS nfip_mart.dim_flood_zone CASCADE;
CREATE TABLE nfip_mart.dim_flood_zone (
    flood_zone_key   int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    flood_zone_code  text NOT NULL UNIQUE,
    zone_letter      text NOT NULL,
    zone_group       text NOT NULL,
    zone_description text NOT NULL,
    is_sfha          boolean NOT NULL,
    has_base_flood_elevation boolean
);
COMMENT ON TABLE nfip_mart.dim_flood_zone IS
  'GRAIN: one row per distinct rated flood zone code found in the data. is_sfha marks the Special Flood Hazard Area (the 100-year floodplain), where coverage is mandatory for federally backed mortgages.';

INSERT INTO nfip_mart.dim_flood_zone
       (flood_zone_code, zone_letter, zone_group, zone_description, is_sfha, has_base_flood_elevation)
SELECT DISTINCT
       s.flood_zone_code,
       s.flood_zone_letter,
       COALESCE(g.zone_group, 'Unknown'),
       COALESCE(g.zone_description, 'Zone letter not in the published list.'),
       COALESCE(g.is_special_flood_hazard_area, false),
       -- Bare A and bare V have no Base Flood Elevation on the FIRM; the
       -- numbered and E-suffixed variants do.
       CASE WHEN s.flood_zone_code IN ('A','V')          THEN false
            WHEN s.flood_zone_letter IN ('A','V')        THEN true
       END
  FROM nfip_stg.claims s
  LEFT JOIN nfip_stg.lk_flood_zone_group g
         ON g.zone_letter = s.flood_zone_letter;


-- ---------------------------------------------------------------------------
-- dim_non_payment_reason
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS nfip_mart.dim_non_payment_reason CASCADE;
CREATE TABLE nfip_mart.dim_non_payment_reason (
    reason_key         int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reason_code        text NOT NULL UNIQUE,
    reason_description text NOT NULL,
    reason_group       text NOT NULL,
    is_real_outcome    boolean NOT NULL
);
COMMENT ON TABLE nfip_mart.dim_non_payment_reason IS
  'GRAIN: one row per non-payment reason code. is_real_outcome is false for administrative corrections (98, 99) - exclude those from any denial-rate metric or the rate is inflated by data cleanup.';

INSERT INTO nfip_mart.dim_non_payment_reason
       (reason_code, reason_description, reason_group, is_real_outcome)
SELECT reason_code, reason_description, reason_group, reason_group <> 'admin'
  FROM nfip_stg.lk_non_payment_reason
UNION ALL
SELECT '(blank)', 'No reason recorded (usually because the claim paid)', 'none', false;


-- ---------------------------------------------------------------------------
-- dim_event
-- ---------------------------------------------------------------------------
-- Named storms are the interesting dimension here. 'Flooding' and 'Not a named
-- storm' are generic labels covering hundreds of thousands of claims, so they
-- are kept but marked, otherwise "top events" is topped by a non-event.
DROP TABLE IF EXISTS nfip_mart.dim_event CASCADE;
CREATE TABLE nfip_mart.dim_event (
    event_key   int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_name  text NOT NULL UNIQUE,
    event_kind  text NOT NULL,
    is_named_storm boolean NOT NULL,
    first_loss_date date,
    last_loss_date  date,
    claim_count     bigint
);
COMMENT ON TABLE nfip_mart.dim_event IS
  'GRAIN: one row per distinct flood event label. is_named_storm excludes the generic labels (Flooding, Not a named storm) and the unnamed bucket.';

INSERT INTO nfip_mart.dim_event
       (event_name, event_kind, is_named_storm, first_loss_date, last_loss_date, claim_count)
SELECT COALESCE(flood_event, '(unnamed)'),
       event_kind,
       event_kind = 'named event',
       min(date_of_loss),
       max(date_of_loss),
       count(*)
  FROM nfip_stg.claims
 GROUP BY 1, 2;


CREATE INDEX ix_dim_flood_zone_letter ON nfip_mart.dim_flood_zone (zone_letter);
CREATE INDEX ix_dim_event_named       ON nfip_mart.dim_event (is_named_storm);

ANALYZE nfip_mart.dim_cause_of_damage;
ANALYZE nfip_mart.dim_occupancy;
ANALYZE nfip_mart.dim_flood_zone;
ANALYZE nfip_mart.dim_non_payment_reason;
ANALYZE nfip_mart.dim_event;

\echo ''
\echo 'Dimensions built.'
SELECT 'dim_cause_of_damage'     AS dimension, count(*) FROM nfip_mart.dim_cause_of_damage
UNION ALL SELECT 'dim_occupancy',             count(*) FROM nfip_mart.dim_occupancy
UNION ALL SELECT 'dim_flood_zone',            count(*) FROM nfip_mart.dim_flood_zone
UNION ALL SELECT 'dim_non_payment_reason',    count(*) FROM nfip_mart.dim_non_payment_reason
UNION ALL SELECT 'dim_event',                 count(*) FROM nfip_mart.dim_event
ORDER BY 1;
