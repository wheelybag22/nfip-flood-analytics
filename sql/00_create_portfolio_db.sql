-- 00_create_portfolio_db.sql
-- One database holding several datasets side by side, so you can switch
-- between builds without switching connections.
--
--   psql -d postgres -f 00_create_portfolio_db.sql
--
-- Layout: one schema trio per dataset, plus a shared ref schema.
--
--   nfip_raw / nfip_stg / nfip_mart
--   sba_raw  / sba_stg  / sba_mart
--   ref                              <- shared across datasets
--
-- Why one database rather than three: DBeaver and Power BI each connect to a
-- single database. With schemas, one connection sees everything and you move
-- between builds by changing the schema prefix. With separate databases you
-- would be reconnecting every time.

CREATE DATABASE portfolio;

\connect portfolio

-- Shared reference data: date dimension, state/FIPS lookups, anything a second
-- dataset would otherwise duplicate.
CREATE SCHEMA IF NOT EXISTS ref;
COMMENT ON SCHEMA ref IS 'Conformed dimensions shared across datasets: dates, geography, NAICS.';


-- Adds the three schemas for one dataset. Call it per dataset; re-running is
-- harmless.
CREATE OR REPLACE FUNCTION ref.add_dataset(ds text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', ds || '_raw');
  EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', ds || '_stg');
  EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', ds || '_mart');

  EXECUTE format($c$COMMENT ON SCHEMA %I IS
    'Source files loaded as-is, all columns text. Never edited.'$c$, ds || '_raw');
  EXECUTE format($c$COMMENT ON SCHEMA %I IS
    'Typed, cleaned, filtered. One table per source.'$c$, ds || '_stg');
  EXECUTE format($c$COMMENT ON SCHEMA %I IS
    'Star schema consumed by Power BI. Facts and conformed dimensions.'$c$, ds || '_mart');

  RAISE NOTICE 'Dataset % ready: %_raw, %_stg, %_mart', ds, ds, ds, ds;
END $$;

COMMENT ON FUNCTION ref.add_dataset(text) IS
  'Creates the raw/stg/mart schema trio for a dataset. SELECT ref.add_dataset(''nfip'');';


-- A shared date dimension. Every dataset you load will need one, and building
-- it once is the point of the ref schema.
CREATE TABLE IF NOT EXISTS ref.dim_date (
    date_key        int PRIMARY KEY,          -- yyyymmdd
    full_date       date NOT NULL UNIQUE,
    year            smallint NOT NULL,
    quarter         smallint NOT NULL,
    month           smallint NOT NULL,
    month_name      text NOT NULL,
    month_abbr      text NOT NULL,
    day_of_month    smallint NOT NULL,
    day_of_week     smallint NOT NULL,        -- 1 = Monday
    day_name        text NOT NULL,
    is_weekend      boolean NOT NULL,
    year_month      text NOT NULL,            -- 2026-03
    quarter_label   text NOT NULL             -- 2026-Q1
);
COMMENT ON TABLE ref.dim_date IS
  'Conformed date dimension, 1968-2035. Mark as the date table in Power BI.';

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
-- Lower bound is 1968, when the National Flood Insurance Program was created.
-- A fact row whose date falls outside this dimension resolves to a NULL key,
-- which drops it from a Power BI relationship silently - so the range is set
-- against the earliest data this database is expected to hold, not a default.
  FROM generate_series('1968-01-01'::date, '2035-12-31'::date, interval '1 day') AS d
ON CONFLICT (date_key) DO NOTHING;

ANALYZE ref.dim_date;


-- US state / FIPS lookup. Both FEMA and SBA data key on these.
CREATE TABLE IF NOT EXISTS ref.dim_state (
    state_fips  char(2) PRIMARY KEY,
    state_abbr  char(2) NOT NULL UNIQUE,
    state_name  text NOT NULL
);
COMMENT ON TABLE ref.dim_state IS 'US states and DC: FIPS code, postal abbreviation, name.';

INSERT INTO ref.dim_state (state_fips, state_abbr, state_name) VALUES
('01','AL','Alabama'),('02','AK','Alaska'),('04','AZ','Arizona'),('05','AR','Arkansas'),
('06','CA','California'),('08','CO','Colorado'),('09','CT','Connecticut'),('10','DE','Delaware'),
('11','DC','District of Columbia'),('12','FL','Florida'),('13','GA','Georgia'),('15','HI','Hawaii'),
('16','ID','Idaho'),('17','IL','Illinois'),('18','IN','Indiana'),('19','IA','Iowa'),
('20','KS','Kansas'),('21','KY','Kentucky'),('22','LA','Louisiana'),('23','ME','Maine'),
('24','MD','Maryland'),('25','MA','Massachusetts'),('26','MI','Michigan'),('27','MN','Minnesota'),
('28','MS','Mississippi'),('29','MO','Missouri'),('30','MT','Montana'),('31','NE','Nebraska'),
('32','NV','Nevada'),('33','NH','New Hampshire'),('34','NJ','New Jersey'),('35','NM','New Mexico'),
('36','NY','New York'),('37','NC','North Carolina'),('38','ND','North Dakota'),('39','OH','Ohio'),
('40','OK','Oklahoma'),('41','OR','Oregon'),('42','PA','Pennsylvania'),('44','RI','Rhode Island'),
('45','SC','South Carolina'),('46','SD','South Dakota'),('47','TN','Tennessee'),('48','TX','Texas'),
('49','UT','Utah'),('50','VT','Vermont'),('51','VA','Virginia'),('53','WA','Washington'),
('54','WV','West Virginia'),('55','WI','Wisconsin'),('56','WY','Wyoming')
ON CONFLICT (state_fips) DO NOTHING;

ANALYZE ref.dim_state;


\echo ''
\echo 'Database "portfolio" created.'
\echo '  ref.dim_date   - 24,837 days, 1968-2035'
\echo '  ref.dim_state  - 51 states + DC'
\echo ''
\echo 'Add a dataset with:  SELECT ref.add_dataset(''nfip'');'
\echo ''
