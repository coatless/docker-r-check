#!/bin/bash
#
# Score container check results against CRAN's published additional issues.
#
# This is the measurement behind milestone criterion (d): for each package we
# checked, did this container reach the same verdict CRAN publishes?
#
# Usage:
#   cran-compare.sh --results results.tsv --issues cran-issues.csv [--kind KIND]
#                   [--min-agreement PERCENT]
#
#   results.tsv       written by tools/summarise-check.sh --outdir
#   cran-issues.csv   written by tools/fetch-cran-issues.R
#
# Classification of each package:
#
#   AGREE_ISSUE   we found an issue, CRAN lists one          } counted in the
#   AGREE_CLEAR   we found none, CRAN lists none             } agreement rate
#   EXTRA         we found one, CRAN lists none
#   MISSED        we found none, CRAN lists one
#   EXCLUDED      our run was INCONCLUSIVE -- the flavor did not actually
#                 apply, so the package says nothing either way and is left
#                 out of the denominator rather than scored as agreement
#
# EXTRA and MISSED are not symmetric and should not be read as if they were.
# MISSED means the container failed to reproduce something CRAN sees, which is
# a defect in this project. EXTRA can mean a false positive, but it can equally
# mean the issue was fixed after our pinned snapshot, or that CRAN chose not to
# publish it. Investigate every EXTRA before calling it a false positive.

set -u

results=""
issues=""
kind=""
min_agreement=""

while [ $# -gt 0 ]; do
    case $1 in
        --results)       results=$2; shift 2 ;;
        --issues)        issues=$2; shift 2 ;;
        --kind)          kind=$2; shift 2 ;;
        --min-agreement) min_agreement=$2; shift 2 ;;
        -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
        *)               echo "cran-compare.sh: unexpected argument $1" >&2; exit 2 ;;
    esac
done

[ -n "$results" ] || { echo "cran-compare.sh: --results is required" >&2; exit 2; }
[ -n "$issues" ]  || { echo "cran-compare.sh: --issues is required" >&2; exit 2; }
[ -f "$results" ] || { echo "cran-compare.sh: no such file: $results" >&2; exit 2; }
[ -f "$issues" ]  || { echo "cran-compare.sh: no such file: $issues" >&2; exit 2; }

awk -v want_kind="$kind" -v min_agreement="${min_agreement:-}" '
function classify(ours, cran) {
    if (ours == "INCONCLUSIVE") return "EXCLUDED"
    if (ours == "ISSUE" && cran)  return "AGREE_ISSUE"
    if (ours == "OK"    && !cran) return "AGREE_CLEAR"
    if (ours == "ISSUE" && !cran) return "EXTRA"
    return "MISSED"
}

## First file: CRAN issues CSV as written by R (all fields quoted, and neither
## package names nor issue kinds nor versions can contain a comma, so a plain
## split is sufficient and no CSV library is needed).
FNR == NR {
    if (FNR == 1) next
    line = $0
    gsub(/"/, "", line)
    n = split(line, f, ",")
    if (n < 3) next
    cran_issue[f[1] SUBSEP f[3]] = 1
    cran_kinds[f[3]] = 1
    next
}

## Second file: our results TSV.
FNR == 1 { next }
{
    n = split($0, r, "\t")
    if (n < 5) next
    pkg = r[1]; rkind = r[4]; verdict = r[5]
    if (want_kind != "" && rkind != want_kind) next
    if (rkind == "") {
        skipped_no_kind++
        next
    }
    kinds_seen[rkind] = 1

    cran = (pkg SUBSEP rkind) in cran_issue
    cls = classify(verdict, cran)
    count[cls]++
    total++
    printf "%-24s %-14s %-13s %-13s %s\n", pkg, rkind, verdict, (cran ? "ISSUE" : "clear"), cls
}

END {
    print ""
    print "-- summary ------------------------------------------------------"
    scored = total - count["EXCLUDED"]
    agree  = count["AGREE_ISSUE"] + count["AGREE_CLEAR"]

    printf "packages compared      %d\n", total
    printf "  AGREE_ISSUE          %d\n", count["AGREE_ISSUE"] + 0
    printf "  AGREE_CLEAR          %d\n", count["AGREE_CLEAR"] + 0
    printf "  EXTRA                %d   (we flagged, CRAN does not list)\n", count["EXTRA"] + 0
    printf "  MISSED               %d   (CRAN lists, we did not flag)\n", count["MISSED"] + 0
    printf "  EXCLUDED             %d   (inconclusive, not scored)\n", count["EXCLUDED"] + 0

    if (skipped_no_kind)
        printf "\nNOTE: %d result row(s) had no cran_issue_kind and were skipped;\n      a control flavor cannot be scored against the issues table.\n", skipped_no_kind

    if (scored <= 0) {
        print "\nagreement rate         n/a (no scorable packages)"
        exit 0
    }

    rate = 100.0 * agree / scored
    printf "\nagreement rate         %.1f%% (%d/%d scored)\n", rate, agree, scored

    ## A rate computed over a handful of packages, or over packages CRAN lists
    ## no issue for at all, is not evidence of much. Say so rather than letting
    ## a headline number stand unqualified.
    if (scored < 20)
        printf "\nWARNING: only %d scored package(s). Too few to support a published\n         agreement rate -- see docs/evaluation-protocol.md for the\n         sampling this number is meant to be computed over.\n", scored
    if (count["AGREE_ISSUE"] + count["MISSED"] == 0)
        print "\nWARNING: no package in this sample has a published CRAN issue of this\n         kind, so the rate only measures that we do not raise false alarms.\n         Include known-positive packages before quoting it."

    if (min_agreement != "" && rate + 0.0 < min_agreement + 0.0) {
        printf "\nFAIL: agreement %.1f%% is below the required %.1f%%\n", rate, min_agreement + 0.0
        exit 1
    }
}
' "$issues" "$results"
