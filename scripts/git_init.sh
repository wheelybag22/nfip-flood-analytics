#!/usr/bin/env bash
#
# git_init.sh — initialise the repo and make the first commit.
#
#   bash scripts/git_init.sh
#
# Does the local half only. Creating the GitHub repo and pushing are printed
# at the end for you to run, because they need your account.
#
# Written for bash 3.2 (macOS).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

die() { printf '\n\033[0;31mSTOPPED: %s\033[0m\n' "$1" >&2; exit 1; }
ok()  { printf '\033[0;32m  OK\033[0m  %s\n' "$1"; }

command -v git >/dev/null 2>&1 || die "git not found."

if [ -d .git ]; then
  echo "Already a git repository. Nothing to initialise."
else
  git init -b main >/dev/null || die "git init failed."
  ok "initialised on branch main"
fi

# Make sure the 1.1 GB source file can never be committed by accident.
if [ ! -f .gitignore ]; then
  die ".gitignore is missing - refusing to continue, data/ would be committed."
fi
grep -q '^data/' .gitignore || die ".gitignore does not exclude data/ - refusing to continue."
ok ".gitignore excludes data/"

git add -A
STAGED=`git diff --cached --name-only | wc -l | tr -d ' '`
BIG=`git diff --cached --name-only -z | xargs -0 -I{} sh -c 'test -f "{}" && wc -c < "{}" | tr -d " " | awk -v f="{}" "\\$1 > 5000000 {print f}"' 2>/dev/null`
if [ -n "$BIG" ]; then
  echo
  echo "Refusing to commit - these files are over 5 MB:" >&2
  echo "$BIG" >&2
  git reset >/dev/null
  die "Check .gitignore."
fi
ok "$STAGED files staged, none oversized"

echo
echo "About to commit:"
git diff --cached --name-only | sed 's/^/    /'
echo

if git rev-parse HEAD >/dev/null 2>&1; then
  echo "Repository already has commits. Commit the staged changes yourself with:"
  echo "    git commit -m \"your message\""
  exit 0
fi

git commit -q -F - <<'MSG'
NFIP flood claims analytics pipeline

A dimensional model over FEMA's National Flood Insurance Program claims
data: 2.7M claims from 1978 to 2026, modelled raw -> staging -> mart in
PostgreSQL with data quality tests.

- Raw layer kept untyped so reloads are reproducible
- Staging separates null payments (closed without payment) from zero
  payments (adjudicated to nothing) - 26% of claims never paid
- Code lookups transcribed from FEMA's published field definitions
- Star schema with five dimensions, no NULL foreign keys
- Twelve data quality assertions that raise rather than report quietly
- Column documentation pulled from the OpenFEMA field API
MSG

ok "committed"

echo
echo "Next, on github.com:"
echo "  1. New repository, named  nfip-flood-analytics"
echo "  2. Public, and do NOT add a README, .gitignore or licence"
echo "     (this repo already has them and the push would conflict)"
echo
echo "Then back here, replacing YOURNAME:"
echo
echo "    git remote add origin https://github.com/YOURNAME/nfip-flood-analytics.git"
echo "    git push -u origin main"
echo
