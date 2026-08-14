#!/bin/bash
# Scoring container results against CRAN's published issues.
#
# The arithmetic here is what any published agreement rate rests on, so the
# denominator matters as much as the numerator: an INCONCLUSIVE run must not be
# quietly counted as agreement.

set -u
here=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$here/.." && pwd)
. "$here/lib.sh"

CMP=$REPO/tools/cran-compare.sh
ISSUES=$here/fixtures/cran-issues.csv

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

mk_results() {
    printf 'package\tversion\tflavor\tcran_issue_kind\tverdict\tstatus\tn_error\tn_warning\tsanitizer_findings\tvalgrind_errors\n' > "$TMP/r.tsv"
    while [ $# -gt 0 ]; do
        printf '%s\t1.0\tgcc-ubsan\tgcc-UBSAN\t%s\tOK\t0\t0\t0\t0\n' "${1%%:*}" "${1##*:}" >> "$TMP/r.tsv"
        shift
    done
}

run_cmp() { "$CMP" --results "$TMP/r.tsv" --issues "$ISSUES" "$@" 2>&1; }

## Fixture ground truth: brokenpkg, ubpkg and missedpkg have a gcc-UBSAN issue;
## othpkg has a noLD issue; anything else is clear.

t_begin "we flag it and CRAN lists it -> AGREE_ISSUE"
mk_results "brokenpkg:ISSUE"
assert_contains "$(run_cmp)" "AGREE_ISSUE"

t_begin "we clear it and CRAN lists nothing -> AGREE_CLEAR"
mk_results "cleanpkg:OK"
assert_contains "$(run_cmp)" "AGREE_CLEAR"

t_begin "we flag it and CRAN does not list it -> EXTRA"
mk_results "cleanpkg:ISSUE"
assert_contains "$(run_cmp)" "EXTRA"

t_begin "CRAN lists it and we do not -> MISSED"
mk_results "missedpkg:OK"
assert_contains "$(run_cmp)" "MISSED"

t_begin "an issue of a different kind does not count as a match"
## othpkg has a noLD issue, not a gcc-UBSAN one. Joining on package alone
## instead of on (package, kind) would score this as agreement.
mk_results "othpkg:OK"
assert_contains "$(run_cmp)" "AGREE_CLEAR"

t_begin "inconclusive runs are excluded from the denominator"
mk_results "brokenpkg:ISSUE" "cleanpkg:OK" "deadpkg:INCONCLUSIVE"
assert_contains "$(run_cmp)" "(2/2 scored)"

t_begin "  ... and are reported rather than hidden"
assert_contains "$(run_cmp)" "EXCLUDED             1"

t_begin "agreement rate is computed over scored packages only"
mk_results "brokenpkg:ISSUE" "cleanpkg:OK" "missedpkg:OK" "othpkg:OK"
assert_contains "$(run_cmp)" "75.0%"

t_begin "a small sample is called out as too small to publish"
assert_contains "$(run_cmp)" "Too few to support a published"

t_begin "a sample with no known positives is called out"
mk_results "cleanpkg:OK" "othpkg:OK"
assert_contains "$(run_cmp)" "no package in this sample has a published CRAN issue"

t_begin "--kind filters to one issue kind"
mk_results "brokenpkg:ISSUE"
assert_contains "$(run_cmp --kind noLD)" "no scorable packages"

t_begin "--min-agreement passes when the rate is high enough"
mk_results "brokenpkg:ISSUE" "cleanpkg:OK"
assert_ok "$CMP" --results "$TMP/r.tsv" --issues "$ISSUES" --min-agreement 100

t_begin "--min-agreement fails when it is not"
mk_results "brokenpkg:OK" "cleanpkg:OK"
assert_fails "$CMP" --results "$TMP/r.tsv" --issues "$ISSUES" --min-agreement 90

t_begin "a control flavor with no issue kind is skipped, with a note"
printf 'package\tversion\tflavor\tcran_issue_kind\tverdict\tstatus\tn_error\tn_warning\tsanitizer_findings\tvalgrind_errors\n' > "$TMP/r.tsv"
printf 'cleanpkg\t1.0\tdebian-gcc\t\tOK\tOK\t0\t0\t0\t0\n' >> "$TMP/r.tsv"
assert_contains "$(run_cmp)" "control flavor cannot be scored"

t_begin "missing input files are an error, not an empty report"
assert_fails "$CMP" --results "$TMP/nope.tsv" --issues "$ISSUES"

t_summary
