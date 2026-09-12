#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check-publishable.sh — refuse to publish what must not be public.
#
#   tools/check-publishable.sh [COMMIT ...]   check committed trees (default HEAD)
#   tools/check-publishable.sh --dir DIR      check files on disk, e.g. built docs/
#
# Always checks, with nothing sensitive in this file:
#   * no PDF is committed      (the dealer service quotes carry a plate and VIN)
#   * no raw bilbasen scrape   (bulk database extract; see NOTICE)
#   * no link to an individual bilbasen advert
#
# Also checks an identifier blocklist, if one is available. The blocklist holds
# the actual strings (registration number, VIN, workshop details) so it is kept
# OUT of the repository: one literal string per line in
#   ${PUBLISH_BLOCKLIST_FILE:-~/.config/car-decision-tools/publish-blocklist.txt}
#
# Matches are reported by file name only, never by content, so a failure does
# not itself print the identifier it found.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

BLOCKLIST="${PUBLISH_BLOCKLIST_FILE:-$HOME/.config/car-decision-tools/publish-blocklist.txt}"
ADVERT_LINK='bilbasen\.dk/brugt/bil/[^[:space:]"'"'"'<>]+/[0-9]{6,}'

fail=0
problem() {
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "::error::$1"; else echo "BLOCKED: $1" >&2; fi
  fail=1
}

have_blocklist=0
if [ -s "$BLOCKLIST" ]; then
  have_blocklist=1
elif [ "${GITHUB_ACTIONS:-}" != "true" ]; then
  echo "note: no identifier blocklist at $BLOCKLIST — generic checks only" >&2
fi

# First few lines of a list, space-separated. sed reads all of its input, so
# unlike `head` it never kills the producer with SIGPIPE — which under
# `pipefail` would turn a real match into a reported non-match.
first() { printf '%s\n' "$1" | sed -n "1,${2:-3}p" | tr '\n' ' '; }

check_commit() {
  local c="$1" files hits
  files=$(git ls-tree -r --name-only "$c")
  if hits=$(grep -iE '\.pdf$' <<<"$files"); then
    problem "$c: a PDF is committed ($(first "$hits"))"
  fi
  if grep -qE '(^|/)bilbasen_data\.csv$' <<<"$files"; then
    problem "$c: the raw bilbasen scrape is committed"
  fi
  if hits=$(git grep -lIE "$ADVERT_LINK" "$c" -- 2>/dev/null); then
    problem "links to individual bilbasen adverts in: $(first "$hits")"
  fi
  if [ "$have_blocklist" = 1 ] && hits=$(git grep -lIiF -f "$BLOCKLIST" "$c" -- 2>/dev/null); then
    problem "blocklisted identifier in: $(first "$hits" 5)"
  fi
}

check_dir() {
  local d="$1" hits
  [ -d "$d" ] || { problem "no such directory: $d"; return; }
  hits=$(find "$d" -type f -iname '*.pdf')
  if [ -n "$hits" ]; then
    problem "PDF in $d: $(first "$hits")"
  fi
  if hits=$(grep -rlIE "$ADVERT_LINK" "$d" 2>/dev/null); then
    problem "links to individual bilbasen adverts in: $(first "$hits")"
  fi
  if [ "$have_blocklist" = 1 ] && hits=$(grep -rlIiF -f "$BLOCKLIST" "$d" 2>/dev/null); then
    problem "blocklisted identifier in: $(first "$hits" 5)"
  fi
}

if [ "${1:-}" = "--dir" ]; then
  check_dir "${2:?--dir needs a directory}"
else
  [ $# -gt 0 ] || set -- HEAD
  for c in "$@"; do check_commit "$c"; done
fi

if [ "$fail" = 0 ]; then echo "publishable: ok"; fi
exit "$fail"
