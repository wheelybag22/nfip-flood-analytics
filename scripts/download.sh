#!/usr/bin/env bash
#
# nfip_01_download.sh — fetch the NFIP redacted claims dataset.
#
# Asks OpenFEMA's metadata API where the current bulk file lives, then PROBES
# several url/user-agent combinations before committing to a download.
#
# Why probe: FEMA's API and its bulk-file path sit behind different front
# doors. The API answers a plain request fine, while the bulk file can return
# 403 to the same client. Rather than guess which combination works today,
# this tries each with a 1 KB range request and uses the first that returns
# data. If they all fail it prints the full matrix so the cause is visible.
#
# Usage:
#   bash nfip_01_download.sh --yes --dir ~/bi-portfolio/data/nfip
#   bash nfip_01_download.sh --probe-only     # just show what works
#
# Written for bash 3.2 (macOS): no heredocs inside $( ), no arrays.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DATA_DIR="$REPO_ROOT/data/nfip"
FORMAT="csv"
ASSUME_YES=0
PROBE_ONLY=0
ENTITY="NfipClaims"

UA_PLAIN="bi-portfolio-research/1.0 (personal portfolio project)"
UA_BROWSER="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)      ASSUME_YES=1; shift ;;
    --probe-only)  PROBE_ONLY=1; shift ;;
    --format)      FORMAT="$2"; shift 2 ;;
    --dir)         DATA_DIR="$2"; shift 2 ;;
    --entity)      ENTITY="$2"; shift 2 ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *)             echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

command -v curl    >/dev/null 2>&1 || { echo "curl not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$DATA_DIR"

cat > "$TMP/pick_url.py" <<'PYEOF'
import json, sys
path, want = sys.argv[1], sys.argv[2].lower()
try:
    doc = json.load(open(path, encoding='utf-8'))
except Exception:
    sys.exit(1)
sets = None
if isinstance(doc, dict):
    for k, v in doc.items():
        if isinstance(v, list) and v and isinstance(v[0], dict) and 'name' in v[0]:
            sets = v; break
if not sets:
    sys.exit(1)
ds = sets[0]
sys.stderr.write("  dataset:      %s v%s\n" % (ds.get('name',''), ds.get('version','')))
sys.stderr.write("  records:      %s\n" % ds.get('recordCount',''))
url = ''
for d in ds.get('distribution', []):
    fmt = (d.get('distributionFormat') or d.get('format') or '').lower()
    u   = d.get('accessURL') or d.get('downloadURL') or ''
    if want in fmt and u:
        url = u; break
if not url:
    for d in ds.get('distribution', []):
        u = d.get('accessURL') or d.get('downloadURL') or ''
        if u: url = u; break
if url:
    print(url)
else:
    sys.exit(1)
PYEOF

echo "Asking OpenFEMA where the current $ENTITY file lives..."
curl -sL --max-time 60 -A "$UA_PLAIN" \
  "https://www.fema.gov/api/open/v1/OpenFemaDataSets?\$filter=name%20eq%20%27${ENTITY}%27&\$format=json" \
  -o "$TMP/meta.json"

META_URL=""
if [ -s "$TMP/meta.json" ]; then
  META_URL=`python3 "$TMP/pick_url.py" "$TMP/meta.json" "$FORMAT" 2>/dev/tty`
fi

# Candidate URLs, best first.
CANDIDATES=""
[ -n "$META_URL" ] && CANDIDATES="$META_URL"
CANDIDATES="$CANDIDATES
https://www.fema.gov/api/open/v3/${ENTITY}.${FORMAT}
https://www.fema.gov/api/open/v2/Fima${ENTITY}.${FORMAT}"

echo
echo "Probing which url + client combination actually serves the file..."
echo

WORK_URL=""
WORK_UA=""
for url in $CANDIDATES; do
  [ -z "$url" ] && continue
  for uakind in browser plain none; do
    case "$uakind" in
      browser) ua="$UA_BROWSER" ;;
      plain)   ua="$UA_PLAIN" ;;
      none)    ua="" ;;
    esac
    if [ -n "$ua" ]; then
      code=`curl -sL --max-time 40 -r 0-1024 -A "$ua" -o "$TMP/probe.bin" -w '%{http_code}' "$url" 2>/dev/null`
    else
      code=`curl -sL --max-time 40 -r 0-1024 -o "$TMP/probe.bin" -w '%{http_code}' "$url" 2>/dev/null`
    fi
    bytes=`wc -c < "$TMP/probe.bin" 2>/dev/null | tr -d ' '`
    # A real CSV starts with a header line containing commas, not "<html".
    looks_csv=no
    if [ "$bytes" -gt 50 ] 2>/dev/null; then
      head -c 200 "$TMP/probe.bin" | grep -qi '^<' || looks_csv=yes
    fi
    printf '  %-7s  http %-3s  %6s bytes  csv=%-3s  %s\n' "$uakind" "$code" "$bytes" "$looks_csv" "$url"
    if [ "$code" = "200" ] || [ "$code" = "206" ]; then
      if [ "$looks_csv" = "yes" ]; then
        WORK_URL="$url"; WORK_UA="$ua"
        break 2
      fi
    fi
  done
done

if [ -z "$WORK_URL" ]; then
  echo
  echo "No combination served the file." >&2
  echo "Every candidate is listed above with what it returned." >&2
  echo >&2
  echo "Next thing to try: open this in a browser and see if it downloads:" >&2
  echo "  ${META_URL:-https://www.fema.gov/api/open/v3/${ENTITY}.${FORMAT}}" >&2
  echo "If the browser gets it, the file is fine and only the request is being" >&2
  echo "refused - save it to $DATA_DIR/nfip_claims.csv and re-run setup_nfip.sh." >&2
  exit 1
fi

echo
echo "  working url:  $WORK_URL"

if [ -n "$WORK_UA" ]; then
  SIZE=`curl -sIL --max-time 45 -A "$WORK_UA" "$WORK_URL" | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {v=$2} END{gsub(/\r/,"",v); print v}'`
else
  SIZE=`curl -sIL --max-time 45 "$WORK_URL" | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {v=$2} END{gsub(/\r/,"",v); print v}'`
fi
if [ -n "$SIZE" ] && [ "$SIZE" -gt 100000 ] 2>/dev/null; then
  HUMAN=`python3 -c "s=$SIZE; u=['B','KB','MB','GB']; i=0
while s>=1024 and i<3: s/=1024.0; i+=1
print('%.1f %s' % (s,u[i]))"`
  echo "  size:         $HUMAN"
else
  echo "  size:         not reported (the server streams it) - expect 1-2 GB"
fi

OUT="$DATA_DIR/nfip_claims.$FORMAT"
echo "  destination:  $OUT"

if [ "$PROBE_ONLY" = "1" ]; then
  echo
  echo "Probe only - nothing downloaded."
  exit 0
fi

echo
if [ "$ASSUME_YES" != "1" ]; then
  printf 'Download now? [y/N] '
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

echo "Downloading (large file - this takes a while)..."
if [ -n "$WORK_UA" ]; then
  curl -fL --retry 3 --retry-delay 2 --progress-bar -A "$WORK_UA" -o "$OUT" "$WORK_URL"
else
  curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$OUT" "$WORK_URL"
fi
rc=$?

if [ "$rc" != "0" ]; then
  echo "Download failed (curl exit $rc)." >&2
  rm -f "$OUT"
  exit 1
fi

# Guard against a saved error page.
if [ ! -s "$OUT" ]; then
  echo "Downloaded file is empty." >&2; rm -f "$OUT"; exit 1
fi
if head -c 200 "$OUT" | grep -qi '^<'; then
  echo "Downloaded an HTML error page rather than CSV. Removed it." >&2
  rm -f "$OUT"; exit 1
fi

echo
ls -lh "$OUT"
