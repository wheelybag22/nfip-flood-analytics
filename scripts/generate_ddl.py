#!/usr/bin/env python3
"""
02_generate_ddl.py — inspect downloaded CSVs and write a loader script.

Reads the header of each CSV in a directory and emits a .sql file containing
CREATE TABLE statements (every column text, by design) plus \\copy commands
with absolute paths.

Keeping raw as all-text is deliberate: the raw layer mirrors the source exactly
so a reload is reproducible and nothing is lost to a bad cast. Casting and
cleaning happen in staging.

Usage:
    python3 02_generate_ddl.py ~/bi-portfolio/data/nfip --schema nfip_raw
    python3 02_generate_ddl.py <dir> --schema <schema> [--db portfolio] [-o out.sql]
    python3 02_generate_ddl.py <dir> --schema nfip_raw --table nfip_claims

Standard library only. Nothing to install.
"""

import argparse
import csv
import os
import re
import sys

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


def clean_name(name, used):
    """Turn a CSV header cell into a safe, unique snake_case identifier.

    OpenFEMA ships camelCase headers (amountPaidOnBuildingClaim), so split on
    case boundaries before lowercasing - otherwise every column becomes one
    unreadable run of letters.
    """
    n = name.strip().strip('"').strip("'")
    n = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", n)   # camelCase -> camel_Case
    n = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", "_", n)  # HTTPServer -> HTTP_Server
    n = n.lower()
    n = re.sub(r"[^a-z0-9]+", "_", n)
    n = re.sub(r"_+", "_", n).strip("_")
    if not n:
        n = "col"
    if n[0].isdigit():
        n = "c_" + n
    if n in RESERVED:
        n = n + "_"
    base, i = n, 2
    while n in used:
        n = "%s_%d" % (base, i)
        i += 1
    used.add(n)
    return n


def sniff_delimiter(path):
    with open(path, "r", encoding="utf-8-sig", errors="replace") as f:
        sample = f.read(64 * 1024)
    try:
        return csv.Sniffer().sniff(sample, delimiters=",;\t|").delimiter
    except csv.Error:
        return ","


def read_header(path, delimiter):
    with open(path, "r", encoding="utf-8-sig", errors="replace", newline="") as f:
        reader = csv.reader(f, delimiter=delimiter)
        for row in reader:
            if row and any(c.strip() for c in row):
                return row
    return []


def count_rows(path, cap=20_000_000):
    """Line count for the report. Caps so a huge file does not stall the run."""
    n = 0
    with open(path, "rb") as f:
        for n, _ in enumerate(f, 0):
            if n >= cap:
                return n, True
    return max(n, 0), False


def sql_literal(s):
    return "'" + s.replace("'", "''") + "'"


def table_name_for(fname):
    stem = os.path.splitext(os.path.basename(fname))[0]
    return clean_name(stem, set())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("data_dir", help="directory holding the downloaded CSVs")
    ap.add_argument("--schema", default="raw",
                    help="target schema, e.g. nfip_raw (default: raw)")
    ap.add_argument("--db", default="portfolio",
                    help="database name, used only in the printed next-step hint")
    ap.add_argument("--table", default=None,
                    help="force a table name (only valid with a single CSV)")
    ap.add_argument("-o", "--out", default=None, help="output .sql path")
    args = ap.parse_args()

    data_dir = os.path.abspath(os.path.expanduser(args.data_dir))
    if not os.path.isdir(data_dir):
        sys.exit("Not a directory: %s" % data_dir)

    all_files = sorted(
        f for f in os.listdir(data_dir)
        if os.path.isfile(os.path.join(data_dir, f))
    )
    csv_files = [f for f in all_files if f.lower().endswith((".csv", ".txt", ".tsv"))]

    if not csv_files:
        other = [f for f in all_files if f.lower().endswith((".parquet", ".zip", ".gz"))]
        msg = "No CSV files found in %s" % data_dir
        if other:
            msg += ("\nFound instead: %s\nParquet and archives need converting or "
                    "unzipping first; re-run the download with --format csv."
                    % ", ".join(other))
        sys.exit(msg)

    if args.table and len(csv_files) > 1:
        sys.exit("--table given but %d CSVs found; drop --table." % len(csv_files))

    out_path = os.path.abspath(
        args.out or os.path.join(os.path.dirname(data_dir) or ".",
                                 "%s_load.sql" % args.schema)
    )

    parts = [
        "-- %s" % os.path.basename(out_path),
        "-- Generated by 02_generate_ddl.py. Safe to re-run: tables are dropped first.",
        "--",
        "--   psql -d %s -v ON_ERROR_STOP=1 -f %s" % (args.db, out_path),
        "--",
        "-- \\copy runs client-side, so paths resolve on this machine, not the server.",
        "-- Every column is text on purpose. Cast in the staging layer.",
        "",
        "CREATE SCHEMA IF NOT EXISTS %s;" % args.schema,
        "",
    ]

    report = []
    for fname in csv_files:
        path = os.path.join(data_dir, fname)
        delim = sniff_delimiter(path)
        header = read_header(path, delim)
        if not header:
            report.append((fname, "SKIPPED - no header found", 0))
            continue

        table = args.table or table_name_for(fname)
        used = set()
        cols = [clean_name(h, used) for h in header]
        rows, capped = count_rows(path)

        col_defs = ",\n".join("    %s text" % c for c in cols)
        parts.append("-- %s  (%d columns, ~%s data rows%s)"
                     % (fname, len(cols), format(rows, ","), "+" if capped else ""))
        parts.append("DROP TABLE IF EXISTS %s.%s;" % (args.schema, table))
        parts.append("CREATE TABLE %s.%s (\n%s\n);" % (args.schema, table, col_defs))
        parts.append(
            "\\copy %s.%s FROM %s WITH (FORMAT csv, HEADER true, DELIMITER %s, QUOTE '\"', NULL '')"
            % (args.schema, table, sql_literal(path), sql_literal(delim))
        )
        parts.append("ANALYZE %s.%s;" % (args.schema, table))
        parts.append("")

        report.append((fname, "%s.%s (%d cols)" % (args.schema, table, len(cols)), rows))

    parts.append("\\echo 'Load complete.'")
    parts.append(
        "SELECT table_name,\n"
        "       (xpath('/row/c/text()',\n"
        "              query_to_xml(format('SELECT count(*) AS c FROM %I.%I',\n"
        "                                  table_schema, table_name),\n"
        "                           false, true, '')))[1]::text::bigint AS row_count\n"
        "  FROM information_schema.tables\n"
        " WHERE table_schema = " + sql_literal(args.schema) + "\n"
        " ORDER BY table_name;"
    )
    parts.append("")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(parts))

    print("Wrote %s\n" % out_path)
    width = max(len(r[0]) for r in report)
    for fname, target, rows in report:
        print("  %s  ->  %s  (%s rows)" % (fname.ljust(width), target, format(rows, ",")))
    print("\nNext:\n  psql -d %s -v ON_ERROR_STOP=1 -f %s" % (args.db, out_path))


if __name__ == "__main__":
    main()
