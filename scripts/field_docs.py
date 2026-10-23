#!/usr/bin/env python3
"""
nfip_05_field_docs.py — pull FEMA's own field descriptions and turn them into
COMMENT ON COLUMN statements.

FEMA publishes a description for every field in the dataset through the
OpenFEMA DataSetFields API. Rather than transcribe 84 of them by hand (and get
some wrong), this fetches them and writes the SQL.

Where a column has a gotcha worth flagging that FEMA's description does not
mention - null-is-not-zero on the payment columns, the privacy rounding on
lat/long - a short note is appended after FEMA's text.

Usage:
    python3 nfip_05_field_docs.py                    # writes nfip_field_comments.sql
    python3 nfip_05_field_docs.py -o /path/out.sql
    python3 nfip_05_field_docs.py --entity NfipClaims --schema nfip_raw --table nfip_claims

Standard library only.
"""

import argparse
import json
import os
import re
import sys
import urllib.request

API = ("https://www.fema.gov/api/open/v1/DataSetFields"
       "?$filter=openFemaDataSet%20eq%20%27{entity}%27&$top=2000&$format=json")

# Analytical notes FEMA's dictionary does not carry. Appended after their text.
CAVEATS = {
    "amount_paid_on_building_claim":
        "NOTE: null is NOT zero - it means closed without a building payment. "
        "Check non_payment_reason_building for why. Treat null and zero separately.",
    "amount_paid_on_contents_claim":
        "NOTE: null is NOT zero - see non_payment_reason_contents.",
    "amount_paid_on_increased_cost_of_compliance_claim":
        "NOTE: usually zero or null; large when present.",
    "latitude":
        "NOTE: rounded to one decimal place for privacy, roughly 11 km. "
        "Fine for a heat map, useless for locating a property.",
    "longitude":
        "NOTE: rounded to one decimal place for privacy. Same caveat as latitude.",
    "date_of_loss":
        "NOTE: the primary date for time analysis - join to ref.dim_date on this.",
    "state":
        "NOTE: join to ref.dim_state on state_abbr.",
    "cause_of_damage":
        "NOTE: values outside the published code list appear in the data, "
        "and many rows are null. Profile it before trusting it.",
    "rated_flood_zone":
        "NOTE: the leading letter carries the signal. A/AE/AO/AH = 100-year "
        "floodplain, V/VE = coastal high hazard, X/B/C = outside the 100-year zone.",
    "id":
        "NOTE: a row id, not a claim number. Policyholder identifiers were "
        "removed in 2019, so claims cannot be traced to a property or deduplicated.",
    "open_date":
        "NOTE: with most_recent_payment_date this gives claim cycle time.",
    "most_recent_payment_date":
        "NOTE: with open_date this gives claim cycle time.",
}

RESERVED = {
    "all", "analyse", "analyze", "and", "any", "array", "as", "asc", "both",
    "case", "cast", "check", "column", "constraint", "create", "current_date",
    "default", "desc", "distinct", "do", "else", "end", "except", "false",
    "for", "foreign", "from", "grant", "group", "having", "in", "initially",
    "intersect", "into", "leading", "limit", "localtime", "not", "null",
    "offset", "on", "only", "or", "order", "placing", "primary", "references",
    "returning", "select", "session_user", "some", "symmetric", "table",
    "then", "to", "trailing", "true", "union", "unique", "user", "using",
    "when", "where", "with",
}


def clean_name(name):
    """Same transform 02_generate_ddl.py applies to CSV headers."""
    n = name.strip().strip('"').strip("'")
    n = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", n)
    n = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", "_", n)
    n = n.lower()
    n = re.sub(r"[^a-z0-9]+", "_", n)
    n = re.sub(r"_+", "_", n).strip("_")
    if not n:
        n = "col"
    if n[0].isdigit():
        n = "c_" + n
    if n in RESERVED:
        n = n + "_"
    return n


def fetch(url):
    # No User-Agent: FEMA's edge rejects requests that set one on some paths,
    # and accepts the absence of the header everywhere. Verified by probing.
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=90) as r:
        return json.loads(r.read().decode("utf-8"))


def sql_literal(s):
    return "'" + s.replace("'", "''") + "'"


def tidy(text):
    """Collapse whitespace and strip the HTML that creeps into some entries."""
    t = re.sub(r"<[^>]+>", " ", text or "")
    t = t.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
    t = t.replace("&nbsp;", " ").replace("&#39;", "'").replace("&quot;", '"')
    t = re.sub(r"\s+", " ", t).strip()
    return t


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--entity", default="NfipClaims")
    ap.add_argument("--schema", default="nfip_raw")
    ap.add_argument("--table",  default="nfip_claims")
    ap.add_argument("-o", "--out", default="nfip_field_comments.sql")
    args = ap.parse_args()

    url = API.format(entity=args.entity)
    sys.stderr.write("Fetching field definitions for %s...\n" % args.entity)
    try:
        doc = fetch(url)
    except Exception as e:
        sys.exit("Could not reach the OpenFEMA field API: %s" % e)

    records = None
    if isinstance(doc, dict):
        for k, v in doc.items():
            if isinstance(v, list) and v and isinstance(v[0], dict):
                records = v
                break
    if not records:
        sys.exit("No field records returned. Check the entity name.")

    rows = []
    for rec in records:
        raw = rec.get("name") or rec.get("field") or ""
        if not raw:
            continue
        desc = tidy(rec.get("description") or rec.get("title") or "")
        typ = (rec.get("type") or "").strip()
        col = clean_name(raw)
        if not desc:
            desc = "(no description published by FEMA)"
        if typ:
            desc = "%s [source type: %s]" % (desc, typ)
        if col in CAVEATS:
            desc = "%s  %s" % (desc, CAVEATS[col])
        rows.append((col, raw, desc))

    if not rows:
        sys.exit("Field records returned but none had usable names.")

    rows.sort(key=lambda r: r[0])
    out = os.path.abspath(os.path.expanduser(args.out))

    parts = [
        "-- nfip_field_comments.sql",
        "-- Generated by nfip_05_field_docs.py from FEMA's OpenFEMA DataSetFields API.",
        "-- %d field definitions, applied only to columns that exist." % len(rows),
        "",
        "DO $do$",
        "DECLARE applied int := 0;",
        "BEGIN",
    ]
    for col, raw, desc in rows:
        parts.append(
            "  IF EXISTS (SELECT 1 FROM information_schema.columns"
            " WHERE table_schema=%s AND table_name=%s AND column_name=%s) THEN"
            % (sql_literal(args.schema), sql_literal(args.table), sql_literal(col))
        )
        parts.append(
            "    EXECUTE format('COMMENT ON COLUMN %s.%s.%%I IS %%L', %s, %s);"
            % (args.schema, args.table, sql_literal(col), sql_literal(desc))
        )
        parts.append("    applied := applied + 1;")
        parts.append("  END IF;")
    parts.append("  RAISE NOTICE 'Applied % column comments from FEMA.', applied;")
    parts.append("END $do$;")
    parts.append("")
    parts.append(
        "SELECT c.column_name AS still_undocumented\n"
        "  FROM information_schema.columns c\n"
        "  JOIN pg_class t ON t.relname = c.table_name\n"
        "  JOIN pg_namespace n ON n.oid = t.relnamespace AND n.nspname = c.table_schema\n"
        "  LEFT JOIN pg_description d ON d.objoid = t.oid AND d.objsubid = c.ordinal_position\n"
        " WHERE c.table_schema = %s AND c.table_name = %s\n"
        "   AND (d.description IS NULL OR d.description = '')\n"
        " ORDER BY c.ordinal_position;"
        % (sql_literal(args.schema), sql_literal(args.table))
    )
    parts.append("")

    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(parts))

    print("Wrote %s" % out)
    print("%d field definitions from FEMA." % len(rows))
    print("%d of them carry an extra analytical note." %
          sum(1 for c, _, _ in rows if c in CAVEATS))


if __name__ == "__main__":
    main()
