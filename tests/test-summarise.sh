#!/bin/bash
# The result summariser, against fixture check logs.
#
# The cases that matter are the ones where the R CMD check Status: line and the
# real verdict disagree. Those are exactly the cases a naive implementation
# gets wrong, and getting them wrong would mean reporting agreement with CRAN
# while detecting nothing.

set -u
here=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$here/.." && pwd)
. "$here/lib.sh"

FIX=$here/fixtures
SUM=$REPO/tools/summarise-check.sh
AWKS=$REPO/tools/summarise-check.awk

field() {  ## field <fixture> <flavor> <column-name>
    local dir=$1 flavor=$2 col=$3 out
    out=$("$SUM" --flavor "$flavor" --issue-kind x --outdir "$TMP" "$dir" >/dev/null 2>&1; cat "$TMP/rcheck-results.tsv")
    printf '%s' "$out" | awk -F'\t' -v c="$col" 'NR==1 { for (i=1;i<=NF;i++) if ($i==c) k=i; next } NR==2 { print $k }'
}

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

t_begin "parses package name and version"
out=$(awk -f "$AWKS" "$FIX/note-error.Rcheck/00check.log")
assert_contains "$out" "$(printf 'package\tbrokenpkg')"

t_begin "parses directional-quoted version"
assert_contains "$out" "$(printf 'version\t1.2.3')"

t_begin "counts errors, warnings and notes from the Status line"
assert_contains "$out" "$(printf 'count\terror\t1')"

t_begin "records each non-OK check"
assert_contains "$out" "$(printf 'check\tNOTE\tinstalled package size')"

t_begin "captures a result reported on a later line (failing tests)"
assert_contains "$out" "$(printf 'check\tERROR\ttests')"

t_begin "does not record checks that passed"
assert_not_contains "$out" "can be installed"

t_begin "clean log yields status OK"
assert_eq OK "$(awk -f "$AWKS" "$FIX/ok.Rcheck/00check.log" | awk -F'\t' '$1=="status"{print $2}')"

t_begin "truncated log is INCOMPLETE, not OK"
assert_eq INCOMPLETE "$(awk -f "$AWKS" "$FIX/incomplete.Rcheck/00check.log" | awk -F'\t' '$1=="status"{print $2}')"

## --- verdicts -------------------------------------------------------------

t_begin "clean check gives verdict OK"
assert_eq OK "$(field "$FIX/ok.Rcheck" nold verdict)"

t_begin "failing check gives verdict ISSUE"
assert_eq ISSUE "$(field "$FIX/note-error.Rcheck" nold verdict)"

t_begin "UBSAN finding gives ISSUE even though Status: is OK"
assert_eq ISSUE "$(field "$FIX/ubsan.Rcheck" gcc-ubsan verdict)"

t_begin "  ... and the underlying check status is still reported as OK"
assert_eq OK "$(field "$FIX/ubsan.Rcheck" gcc-ubsan status)"

t_begin "  ... and the sanitizer finding is counted"
assert_eq 1 "$(field "$FIX/ubsan.Rcheck" gcc-ubsan sanitizer_findings)"

t_begin "valgrind errors give ISSUE even though Status: is OK"
assert_eq ISSUE "$(field "$FIX/valgrind-errors.Rcheck" valgrind verdict)"

t_begin "valgrind error count is extracted from the ERROR SUMMARY line"
assert_eq 3 "$(field "$FIX/valgrind-errors.Rcheck" valgrind valgrind_errors)"

t_begin "valgrind flavor with no valgrind output is INCONCLUSIVE, not OK"
## The trap this guards: if --use-valgrind never reaches R CMD check, the run
## looks perfect. Reporting OK there would be reporting a clean bill of health
## from a test that did not run.
assert_eq INCONCLUSIVE "$(field "$FIX/valgrind-notrun.Rcheck" valgrind verdict)"

t_begin "the same clean run under a non-valgrind flavor is OK"
assert_eq OK "$(field "$FIX/valgrind-notrun.Rcheck" nold verdict)"

t_begin "truncated run is INCONCLUSIVE"
assert_eq INCONCLUSIVE "$(field "$FIX/incomplete.Rcheck" nold verdict)"

## --- outputs --------------------------------------------------------------

t_begin "writes per-package JSON next to the check"
rm -f "$FIX/ok.Rcheck/rcheck-result.json"
"$SUM" --flavor nold --issue-kind noLD "$FIX/ok.Rcheck" >/dev/null 2>&1
if [ -f "$FIX/ok.Rcheck/rcheck-result.json" ]; then t_pass; else t_fail "no rcheck-result.json written"; fi

t_begin "the JSON is valid"
if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$FIX/ok.Rcheck/rcheck-result.json" 2>/dev/null; then
        t_pass
    else
        t_fail "invalid JSON"
    fi
else
    assert_contains "$(cat "$FIX/ok.Rcheck/rcheck-result.json")" '"verdict"'
fi

t_begin "re-running does not count its own output as a finding"
## rcheck-result.json contains the sanitizer sample text, so a naive rescan
## would find "runtime error:" in it and inflate the count on every rerun.
"$SUM" --flavor gcc-ubsan --issue-kind gcc-UBSAN --outdir "$TMP" "$FIX/ubsan.Rcheck" >/dev/null 2>&1
first=$(field "$FIX/ubsan.Rcheck" gcc-ubsan sanitizer_findings)
"$SUM" --flavor gcc-ubsan --issue-kind gcc-UBSAN --outdir "$TMP" "$FIX/ubsan.Rcheck" >/dev/null 2>&1
second=$(field "$FIX/ubsan.Rcheck" gcc-ubsan sanitizer_findings)
assert_eq "$first" "$second"

t_begin "aggregate TSV has one row per package plus a header"
"$SUM" --flavor nold --issue-kind noLD --outdir "$TMP" "$FIX/ok.Rcheck" "$FIX/note-error.Rcheck" >/dev/null 2>&1
assert_eq 3 "$(wc -l < "$TMP/rcheck-results.tsv" | tr -d ' ')"

t_begin "missing 00check.log is reported, not silently skipped"
mkdir -p "$TMP/empty.Rcheck"
assert_fails "$SUM" --flavor nold "$TMP/empty.Rcheck"

## Leave the fixture tree as we found it.
rm -f "$FIX"/*.Rcheck/rcheck-result.json

t_summary
