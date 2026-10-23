-- 05_extend_ref_dims.sql
-- Extends the shared reference dimensions to cover what NFIP claims actually
-- contain.
--
--   psql -d portfolio -v ON_ERROR_STOP=1 -f sql/05_extend_ref_dims.sql
--
-- 00_create_portfolio_db.sql builds the shared dimensions. This adds what NFIP
-- claims specifically need from the geography dimension:
--
--  1. US territories. The claims data holds 57 distinct state values because
--     the NFIP writes in Puerto Rico, Guam and the US Virgin Islands.
--
--  2. Unknown members, so claims with no usable location still resolve to a
--     dimension row instead of a NULL key.
--
-- The date range is set in 00_create_portfolio_db.sql; the backfill below is
-- kept so a database created before that range was widened picks it up.
--
-- Idempotent: every insert skips rows that already exist.

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- 1. Extend the date dimension back to the start of the program
-- ---------------------------------------------------------------------------
INSERT INTO ref.dim_date
SELECT to_char(d, 'YYYYMMDD')::int,
       d::date,
       extract(year    FROM d)::smallint,
       extract(quarter FROM d)::smallint,
       extract(month   FROM d)::smallint,
       trim(to_char(d, 'Month')),
       to_char(d, 'Mon'),
       extract(day FROM d)::smallint,
       extract(isodow FROM d)::smallint,
       trim(to_char(d, 'Day')),
       extract(isodow FROM d) >= 6,
       to_char(d, 'YYYY-MM'),
       to_char(d, 'YYYY') || '-Q' || extract(quarter FROM d)
  FROM generate_series(DATE '1968-01-01', DATE '1989-12-31', interval '1 day') AS d
ON CONFLICT (date_key) DO NOTHING;

ANALYZE ref.dim_date;


-- ---------------------------------------------------------------------------
-- 2. Add US territories and outlying areas
-- ---------------------------------------------------------------------------
-- FIPS codes follow the standard territory assignments. Marked so a dashboard
-- can separate "states" from "states and territories" deliberately rather than
-- by accident.
ALTER TABLE ref.dim_state ADD COLUMN IF NOT EXISTS is_territory boolean NOT NULL DEFAULT false;

INSERT INTO ref.dim_state (state_fips, state_abbr, state_name, is_territory) VALUES
 ('60','AS','American Samoa',                          true),
 ('66','GU','Guam',                                    true),
 ('69','MP','Northern Mariana Islands',                true),
 ('72','PR','Puerto Rico',                             true),
 ('78','VI','U.S. Virgin Islands',                     true),
 ('74','UM','U.S. Minor Outlying Islands',             true),
 ('64','FM','Federated States of Micronesia',          true),
 ('68','MH','Marshall Islands',                        true),
 ('70','PW','Palau',                                   true)
ON CONFLICT (state_fips) DO NOTHING;


-- ---------------------------------------------------------------------------
-- 3. Unknown members
-- ---------------------------------------------------------------------------
-- 16,441 claims carry the state code 'UN'. They have no county either - zero
-- distinct county codes across all of them - and the code stops appearing
-- after June 2011, so it reads as a legacy FEMA placeholder for "location not
-- recorded" that was retired rather than a real place.
--
-- One further claim (July 2024) has an empty state.
--
-- Both get an explicit dimension member rather than being left to resolve to
-- NULL. A NULL foreign key disappears from an inner join silently; an unknown
-- member stays visible and countable, which is the whole point of modelling it.
ALTER TABLE ref.dim_state ADD COLUMN IF NOT EXISTS is_unknown_member boolean NOT NULL DEFAULT false;

INSERT INTO ref.dim_state (state_fips, state_abbr, state_name, is_territory, is_unknown_member) VALUES
 ('99','UN','Unknown - legacy FEMA placeholder (retired 2011)', false, true),
 ('98','--','Not recorded',                                     false, true)
ON CONFLICT (state_fips) DO NOTHING;

COMMENT ON COLUMN ref.dim_state.is_unknown_member IS
  'True for placeholder members that stand in for missing geography. Exclude them from any map or per-state ranking; count them when reporting coverage.';

COMMENT ON COLUMN ref.dim_state.is_territory IS
  'True for US territories and outlying areas. The NFIP covers these, so claims data includes them alongside the 50 states and DC.';

ANALYZE ref.dim_state;


\echo ''
\echo 'Reference dimensions extended.'
SELECT min(full_date) AS date_from, max(full_date) AS date_to, count(*) AS days
  FROM ref.dim_date;
SELECT count(*) FILTER (WHERE NOT is_territory) AS states_and_dc,
       count(*) FILTER (WHERE is_territory)     AS territories,
       count(*)                                 AS total
  FROM ref.dim_state;
