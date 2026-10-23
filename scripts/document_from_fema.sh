#!/usr/bin/env bash
#
# nfip_05_document_from_fema.sh — fill in the remaining column descriptions
# using FEMA's own published field definitions.
#
#   bash ~/bi-portfolio/nfip_05_document_from_fema.sh
#
# nfip_03_document.sql covered the columns I had definitions for. This covers
# the rest by asking FEMA's DataSetFields API, so the descriptions are theirs
# rather than my guesses. Where a column has a trap worth flagging that FEMA
# does not mention, a short note is appended.
#
# Safe to re-run. Overwrites comments with the authoritative text.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HERE="$REPO_ROOT"
DB="portfolio"
OUT="$REPO_ROOT/data/nfip_field_comments.sql"

die() { printf '\n\033[0;31mSTOPPED: %s\033[0m\n' "$1" >&2; exit 1; }
ok()  { printf '\033[0;32m  OK\033[0m  %s\n' "$1"; }

command -v psql    >/dev/null 2>&1 || die "psql not found."
command -v python3 >/dev/null 2>&1 || die "python3 not found."
[ -f "$REPO_ROOT/scripts/field_docs.py" ] || die "Missing $REPO_ROOT/scripts/field_docs.py"
psql -d "$DB" -tAc "SELECT 1" >/dev/null 2>&1 || die "Cannot connect to \"$DB\". Is Postgres.app running?"

mkdir -p "$REPO_ROOT/data"

printf '\n\033[1;36m[1/2] Fetching field definitions from FEMA\033[0m\n'
python3 "$REPO_ROOT/scripts/field_docs.py" \
        --entity NfipClaims --schema nfip_raw --table nfip_claims \
        -o "$OUT" || die "Could not fetch field definitions."
ok "wrote $OUT"

printf '\n\033[1;36m[2/2] Applying them to the table\033[0m\n'
psql -d "$DB" -v ON_ERROR_STOP=1 -f "$OUT" || die "Could not apply the comments."

printf '\n\033[1;32mDone.\033[0m Refresh DBeaver (F5) and hover any column name.\n'
printf 'Anything listed above as still_undocumented has no FEMA description either.\n\n'
