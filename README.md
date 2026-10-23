# NFIP Flood Claims Analytics

A dimensional model over FEMA's National Flood Insurance Program claims data —
**2.7 million claims from 1978 to 2026** — built in PostgreSQL as
raw → staging → mart, with data quality tests.

Built to answer questions like: does floodplain construction standards show up
in loss severity? Why do claims close without payment? Where does the program's
exposure actually concentrate?

---

## Why this exists

Most public-data portfolio projects load a clean CSV and chart it. This one is
about the part that takes the time: a source with 84 columns, two generations
of occupancy codes, payment fields where NULL and zero mean different things,
and a depth measurement recorded in inches *except where it isn't*.

The modeling decisions are written down in
[`docs/modeling_decisions.md`](docs/modeling_decisions.md). That file is the
point of the repo as much as the SQL is.

---

## Architecture

```
nfip_raw      Source CSV loaded as-is, every column text.
              Never edited. Reloads are reproducible.
     │
nfip_stg      Typed and cleaned. One row per claim.
              Code lookups transcribed from FEMA's published definitions.
     │
nfip_mart     Star schema. fact_claim plus five dimensions,
              conformed to shared ref.dim_date and ref.dim_state.
```

`ref` holds dimensions shared across datasets, so a second source plugs into the
same date and geography.

### The model

| Table | Grain | Rows |
|---|---|---|
| `nfip_mart.fact_claim` | one claim | 2,725,989 |
| `nfip_mart.dim_flood_zone` | one rated zone code | ~70 |
| `nfip_mart.dim_occupancy` | one occupancy code | 15 |
| `nfip_mart.dim_cause_of_damage` | one cause code | 18 |
| `nfip_mart.dim_non_payment_reason` | one reason code | 24 |
| `nfip_mart.dim_event` | one flood event | ~hundreds |
| `ref.dim_date` | one day, 1968–2035 | 24,837 |
| `ref.dim_state` | one state or territory | 60 |

`nfip_mart.vw_claim_detail` flattens the fact against its dimensions for BI
tools, so the semantic model stays thin and the logic stays in SQL.

---

## Running it

Requires PostgreSQL 14+ and Python 3. No other dependencies.

```bash
# 1. Database and shared dimensions
psql -d postgres -f sql/00_create_portfolio_db.sql
psql -d portfolio -f sql/05_extend_ref_dims.sql

# 2. Download the source (~1.1 GB) and load it
bash scripts/download.sh
python3 scripts/generate_ddl.py data/nfip --schema nfip_raw --db portfolio
psql -d portfolio -v ON_ERROR_STOP=1 -f data/nfip_raw_load.sql

# 3. Document every column from FEMA's own field API
bash scripts/document_from_fema.sh

# 4. Build
psql -d portfolio -v ON_ERROR_STOP=1 -f sql/25_lookups.sql
psql -d portfolio -v ON_ERROR_STOP=1 -f sql/20_staging.sql
psql -d portfolio -v ON_ERROR_STOP=1 -f sql/30_dimensions.sql
psql -d portfolio -v ON_ERROR_STOP=1 -f sql/40_facts.sql

# 5. Verify
psql -d portfolio -v ON_ERROR_STOP=1 -f tests/data_quality.sql
```

Every script is idempotent. `tests/data_quality.sql` exits non-zero on failure,
so it drops straight into CI.

---

## Tests

`tests/data_quality.sql` asserts twelve things and **raises an exception** on
failure rather than reporting quietly:

- Grain is unique at every layer
- Row counts reconcile raw → staging → fact
- No orphaned dimension keys (a NULL key drops rows from a BI join silently)
- `payment_status` agrees with the underlying amounts
- `total_paid` equals the sum of its components
- Loss dates fall inside the program's lifetime
- Payments don't precede claim opening; losses don't predate construction
- Geography resolves, within a stated tolerance

Checks that are *expected* to find something in public data — the water depth
unit ambiguity, payments exceeding coverage because ICC sits outside the
building limit — report as notes with a baseline, so drift is visible without
crying wolf.

---

## Column documentation

Descriptions for all 84 columns are attached to the table in Postgres, pulled
from FEMA's OpenFEMA DataSetFields API rather than transcribed by hand. Hover a
column in any SQL client and the definition is there. Where a column has a trap
FEMA doesn't mention — null-is-not-zero on payments, the privacy rounding on
coordinates — a short note is appended.

```sql
SELECT c.column_name, d.description
  FROM information_schema.columns c
  JOIN pg_class t ON t.relname = c.table_name
  JOIN pg_namespace n ON n.oid = t.relnamespace AND n.nspname = c.table_schema
  LEFT JOIN pg_description d ON d.objoid = t.oid AND d.objsubid = c.ordinal_position
 WHERE c.table_schema = 'nfip_raw' AND c.table_name = 'nfip_claims'
 ORDER BY c.ordinal_position;
```

---

## Repository layout

```
sql/
  00_create_portfolio_db.sql   database, schemas, shared ref dimensions
  05_extend_ref_dims.sql       extend dim_date to 1968, add territories
  25_lookups.sql               code lists from FEMA's definitions
  20_staging.sql               typed and cleaned claims
  30_dimensions.sql            star schema dimensions
  40_facts.sql                 fact_claim and the BI view
  50_analysis.sql              analytical queries
tests/
  data_quality.sql             assertions that fail loudly
scripts/
  download.sh                  fetch the source from OpenFEMA
  generate_ddl.py              build the load script from the CSV header
  document_from_fema.sh        apply FEMA's field definitions as comments
  profile.sh                   profile the loaded data
docs/
  modeling_decisions.md        what was decided and why
```

---

## Notes on the source

The OpenFEMA bulk endpoint rejects requests that set a `User-Agent` header and
accepts ones that don't — the opposite of the usual pattern.
`scripts/download.sh` probes url and client combinations rather than assuming,
and reports the matrix when none work.

The dataset entity was renamed between versions (`FimaNfipClaims` → `NfipClaims`)
and v2 was retired in October 2026. The download script asks OpenFEMA's metadata
API where the current file lives instead of hardcoding a URL.

---

## On how this was built

Built with AI assistance (Claude). I chose the dataset, set the approach, and
reviewed the modeling decisions — the reasoning behind each is in
[docs/modeling_decisions.md](docs/modeling_decisions.md), which is the file
worth reading if you want to know how I think about this kind of data.

---

## Attribution

Source: U.S. Federal Emergency Management Agency, OpenFEMA Dataset
*NFIP Redacted Claims – v3*.

This product uses the FEMA OpenFEMA API but is not endorsed by FEMA. FEMA's
[terms and conditions](https://www.fema.gov/about/openfema/terms-conditions)
apply to the source data.
