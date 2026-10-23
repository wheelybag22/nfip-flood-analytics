#!/usr/bin/env bash
#
# nfip_06_profile.sh — profile the loaded data and write the results to a file.
#
#   bash ~/bi-portfolio/nfip_06_profile.sh
#
# Writes ~/bi-portfolio/data/profile_output.txt. Nothing to copy and paste -
# the staging layer gets written against what this reports rather than against
# what the published dictionary claims.
#
# Takes a minute or two. Uses a 2% sample for the null-rate pass and full scans
# only where the answer needs one.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HERE="$REPO_ROOT"
DB="portfolio"
OUT="$REPO_ROOT/data/profile_output.txt"

command -v psql >/dev/null 2>&1 || { echo "psql not found." >&2; exit 1; }
psql -d "$DB" -tAc "SELECT 1" >/dev/null 2>&1 || { echo "Cannot connect to \"$DB\". Is Postgres.app running?" >&2; exit 1; }

mkdir -p "$REPO_ROOT/data"

echo "Profiling nfip_raw.nfip_claims - this takes a minute or two..."

psql -d "$DB" -X -q -P pager=off -v ON_ERROR_STOP=1 > "$OUT" 2>&1 <<'SQL'
\echo '================ 1. SHAPE ================'
SELECT count(*) AS total_claims,
       pg_size_pretty(pg_total_relation_size('nfip_raw.nfip_claims')) AS size
  FROM nfip_raw.nfip_claims;

\echo ''
\echo '================ 2. COLUMN LIST ================'
SELECT ordinal_position AS pos, column_name
  FROM information_schema.columns
 WHERE table_schema='nfip_raw' AND table_name='nfip_claims'
 ORDER BY ordinal_position;

\echo ''
\echo '================ 3. BLANK RATE PER COLUMN (2% sample) ================'
WITH s AS (SELECT * FROM nfip_raw.nfip_claims TABLESAMPLE SYSTEM (2))
SELECT kv.key AS column_name,
       count(*) FILTER (WHERE kv.value IS NULL OR kv.value='') AS blank,
       count(*) AS sampled,
       round(100.0*count(*) FILTER (WHERE kv.value IS NULL OR kv.value='')
             / NULLIF(count(*),0), 1) AS pct_blank
  FROM s, LATERAL jsonb_each_text(to_jsonb(s)) kv
 GROUP BY kv.key
 ORDER BY pct_blank DESC, column_name;

\echo ''
\echo '================ 4. DATE RANGE ================'
SELECT min(date_of_loss) AS earliest, max(date_of_loss) AS latest,
       count(*) FILTER (WHERE date_of_loss !~ '^\d{4}-\d{2}-\d{2}') AS non_iso_dates
  FROM nfip_raw.nfip_claims;

\echo ''
\echo '================ 5. CLAIMS BY DECADE ================'
SELECT substr(date_of_loss,1,3) || '0s' AS decade, count(*) AS claims
  FROM nfip_raw.nfip_claims
 WHERE date_of_loss ~ '^\d{4}'
 GROUP BY 1 ORDER BY 1;

\echo ''
\echo '================ 6. CAUSE OF DAMAGE ================'
SELECT COALESCE(NULLIF(cause_of_damage,''),'(blank)') AS val, count(*) AS n
  FROM nfip_raw.nfip_claims GROUP BY 1 ORDER BY n DESC;

\echo ''
\echo '================ 7. OCCUPANCY TYPE ================'
SELECT COALESCE(NULLIF(occupancy_type,''),'(blank)') AS val, count(*) AS n
  FROM nfip_raw.nfip_claims GROUP BY 1 ORDER BY n DESC;

\echo ''
\echo '================ 8. FLOOD ZONE - leading letter ================'
SELECT CASE WHEN rated_flood_zone IS NULL OR rated_flood_zone='' THEN '(blank)'
            ELSE left(upper(rated_flood_zone),1) END AS zone_letter,
       count(*) AS n, count(DISTINCT rated_flood_zone) AS distinct_codes
  FROM nfip_raw.nfip_claims GROUP BY 1 ORDER BY n DESC;

\echo ''
\echo '================ 9. NON-PAYMENT REASON (building) ================'
SELECT COALESCE(NULLIF(non_payment_reason_building,''),'(blank)') AS val, count(*) AS n
  FROM nfip_raw.nfip_claims GROUP BY 1 ORDER BY n DESC LIMIT 30;

\echo ''
\echo '================ 10. BUILDING PAYMENT: null vs zero vs negative ================'
SELECT CASE WHEN amount_paid_on_building_claim IS NULL
              OR amount_paid_on_building_claim=''            THEN '1 null/blank'
            WHEN amount_paid_on_building_claim !~ '^-?\d+(\.\d+)?$' THEN '2 non-numeric'
            WHEN amount_paid_on_building_claim::numeric = 0   THEN '3 zero'
            WHEN amount_paid_on_building_claim::numeric < 0   THEN '4 negative'
            ELSE                                                   '5 positive' END AS bucket,
       count(*) AS n
  FROM nfip_raw.nfip_claims GROUP BY 1 ORDER BY 1;

\echo ''
\echo '================ 11. SEVERITY PERCENTILES (paid > 0) ================'
SELECT count(*) AS paid_claims,
       round(percentile_cont(0.25) WITHIN GROUP (ORDER BY p)::numeric) AS p25,
       round(percentile_cont(0.50) WITHIN GROUP (ORDER BY p)::numeric) AS median,
       round(avg(p))                                                   AS mean,
       round(percentile_cont(0.90) WITHIN GROUP (ORDER BY p)::numeric) AS p90,
       round(percentile_cont(0.99) WITHIN GROUP (ORDER BY p)::numeric) AS p99,
       round(max(p))                                                   AS max
  FROM (SELECT amount_paid_on_building_claim::numeric AS p
          FROM nfip_raw.nfip_claims
         WHERE amount_paid_on_building_claim ~ '^\d+(\.\d+)?$'
           AND amount_paid_on_building_claim::numeric > 0) x;

\echo ''
\echo '================ 12. CAST SAFETY: would these break ::numeric / ::date ? ================'
SELECT 'amount_paid_on_building_claim' AS col,
       count(*) FILTER (WHERE amount_paid_on_building_claim <> ''
                          AND amount_paid_on_building_claim !~ '^-?\d+(\.\d+)?$') AS bad
  FROM nfip_raw.nfip_claims
UNION ALL SELECT 'total_building_insurance_coverage',
       count(*) FILTER (WHERE total_building_insurance_coverage <> ''
                          AND total_building_insurance_coverage !~ '^-?\d+(\.\d+)?$')
  FROM nfip_raw.nfip_claims
UNION ALL SELECT 'date_of_loss',
       count(*) FILTER (WHERE date_of_loss <> ''
                          AND date_of_loss !~ '^\d{4}-\d{2}-\d{2}')
  FROM nfip_raw.nfip_claims
UNION ALL SELECT 'latitude',
       count(*) FILTER (WHERE latitude <> '' AND latitude !~ '^-?\d+(\.\d+)?$')
  FROM nfip_raw.nfip_claims
UNION ALL SELECT 'water_depth',
       count(*) FILTER (WHERE water_depth <> '' AND water_depth !~ '^-?\d+(\.\d+)?$')
  FROM nfip_raw.nfip_claims;

\echo ''
\echo '================ 13. KEY CANDIDATES - is id unique? ================'
SELECT count(*) AS rows, count(DISTINCT id) AS distinct_ids
  FROM nfip_raw.nfip_claims;

\echo ''
\echo '================ 14. GEOGRAPHY COVERAGE ================'
SELECT count(DISTINCT state) AS distinct_states,
       count(DISTINCT county_code) AS distinct_counties,
       count(*) FILTER (WHERE state IS NULL OR state='') AS blank_state
  FROM nfip_raw.nfip_claims;

\echo ''
\echo '================ 15. TOP 15 STATES ================'
SELECT state, count(*) AS claims
  FROM nfip_raw.nfip_claims GROUP BY 1 ORDER BY claims DESC LIMIT 15;

\echo ''
\echo '================ 16. NAMED EVENTS - top 20 ================'
SELECT COALESCE(NULLIF(flood_event,''),'(none)') AS event, count(*) AS n
  FROM nfip_raw.nfip_claims GROUP BY 1 ORDER BY n DESC LIMIT 20;
SQL

rc=$?
if [ "$rc" != "0" ]; then
  echo "Profiling hit an error. See $OUT" >&2
  tail -20 "$OUT" >&2
  exit 1
fi

echo "Done. Wrote $OUT  ($(wc -l < "$OUT" | tr -d ' ') lines)"
