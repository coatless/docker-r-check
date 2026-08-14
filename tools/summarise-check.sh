#!/bin/bash
#
# Turn one or more <pkg>.Rcheck directories into machine-readable results.
#
# Why this is more than a wrapper around the Status: line:
#
# A sanitizer finding does not change R CMD check's exit status. UBSAN prints
# "runtime error:" to stderr and carries on; ASAN usually aborts the child
# process but the check can still be reported as OK overall. So for the
# sanitizer flavors -- the ones with the highest value -- reading Status: alone
# would report perfect agreement with CRAN while detecting nothing at all.
# This script therefore scans the whole .Rcheck tree for the instrumentation's
# own output, and derives a verdict from both signals.
#
# Similarly for valgrind: if --use-valgrind never reached R CMD check, the
# check runs fine and reports OK, which is indistinguishable from "valgrind ran
# and found nothing" unless you look for valgrind's output. That case is
# reported as INCONCLUSIVE rather than OK, deliberately.
#
# Usage:
#   summarise-check.sh [--flavor ID] [--issue-kind KIND] [--outdir DIR] DIR...

set -u

here=$(cd "$(dirname "$0")" && pwd)
AWK_SCRIPT=${RCHECK_AWK:-$here/summarise-check.awk}

flavor=unflavored
issue_kind=""
outdir=""
dirs=()

while [ $# -gt 0 ]; do
    case $1 in
        --flavor)     flavor=$2; shift 2 ;;
        --issue-kind) issue_kind=$2; shift 2 ;;
        --outdir)     outdir=$2; shift 2 ;;
        --awk)        AWK_SCRIPT=$2; shift 2 ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        --)           shift; break ;;
        -*)           echo "summarise-check.sh: unknown option $1" >&2; exit 2 ;;
        *)            dirs+=("$1"); shift ;;
    esac
done
while [ $# -gt 0 ]; do dirs+=("$1"); shift; done

if [ ${#dirs[@]} -eq 0 ]; then
    echo "summarise-check.sh: no .Rcheck directories given" >&2
    exit 2
fi

json_escape() {
    printf '%s' "$1" | awk 'BEGIN { ORS="" }
        { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "\\r")
          if (NR > 1) printf "\\n"
          printf "%s", $0 }'
}

## Count lines in the check tree matching an extended regexp.
##
## Only POSIX-portable grep options here (-r -E -h -I): this runs both inside
## the Debian image and on the user's host via `rcheck summarise`, and macOS
## ships BSD grep, which has neither --binary-files=without-match nor GNU's \s.
## For the same reason there is no xargs -r, which BSD xargs does not accept.
##
## Idempotency across reruns is handled by deleting the previous result file
## before scanning rather than by excluding it from the scan -- the result file
## quotes the sanitizer output, so a rescan would otherwise count our own
## previous findings as new ones and inflate the number on every run.
scan_count() {
    local dir=$1 re=$2
    grep -rEhI -- "$re" "$dir" 2>/dev/null | wc -l | tr -d '[:space:]'
}

## First few matching lines, for a human reading the summary.
scan_sample() {
    local dir=$1 re=$2 limit=${3:-5}
    grep -rEhI -- "$re" "$dir" 2>/dev/null \
        | grep -v '^[[:space:]]*$' | head -n "$limit"
}

## Sanitizer runtimes announce themselves in a small number of well-known ways.
SAN_RE='runtime error:|AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer|ThreadSanitizer|MemorySanitizer'
## valgrind prefixes every line with its pid in ==NNN== and ends with a summary.
VG_RUN_RE='^==[0-9]+== |ERROR SUMMARY: [0-9]+ errors'
VG_ERR_RE='ERROR SUMMARY: [0-9]+ errors'

results=()
rows=()

for dir in "${dirs[@]}"; do
    [ -d "$dir" ] || { echo "summarise-check.sh: not a directory: $dir" >&2; continue; }
    log=$dir/00check.log
    if [ ! -f "$log" ]; then
        echo "summarise-check.sh: no 00check.log in $dir, skipping" >&2
        continue
    fi

    ## Written at the end of this loop; removed first so that a rerun does not
    ## rescan our own recorded findings. See scan_count().
    rm -f "$dir/rcheck-result.json"

    pkg=""; version=""; status="UNKNOWN"
    n_error=0; n_warning=0; n_note=0
    checks_json=""

    while IFS=$'\t' read -r kind a b; do
        case $kind in
            package) pkg=$a ;;
            version) version=$a ;;
            status)  status=$a ;;
            count)   case $a in error) n_error=$b ;; warning) n_warning=$b ;; note) n_note=$b ;; esac ;;
            check)
                [ -z "$checks_json" ] || checks_json="$checks_json,"
                checks_json="$checks_json
      {\"result\": \"$(json_escape "$a")\", \"title\": \"$(json_escape "$b")\"}"
                ;;
        esac
    done < <(awk -f "$AWK_SCRIPT" "$log")

    [ -n "$pkg" ] || { pkg=$(basename "$dir"); pkg=${pkg%.Rcheck}; }

    san_findings=$(scan_count "$dir" "$SAN_RE")
    vg_lines=$(scan_count "$dir" "$VG_RUN_RE")
    vg_errors=0
    if [ "$vg_lines" -gt 0 ]; then
        vg_errors=$(scan_sample "$dir" "$VG_ERR_RE" 1 | sed -E 's/.*ERROR SUMMARY: ([0-9]+) errors.*/\1/' | head -n 1)
        [ -n "$vg_errors" ] || vg_errors=0
    fi

    ## The verdict is the unit of comparison against CRAN's published results:
    ## CRAN lists a package under an issue kind, or it does not.
    ##
    ##   ISSUE         this flavor found something CRAN would list
    ##   OK            it did not
    ##   INCONCLUSIVE  the flavor did not actually apply, so we know nothing --
    ##                 never silently folded into OK, because that would inflate
    ##                 the agreement rate with runs that tested nothing
    verdict=OK
    if [ "$status" = INCOMPLETE ]; then
        verdict=INCONCLUSIVE
    elif [ "$flavor" = valgrind ] && [ "$vg_lines" -eq 0 ]; then
        verdict=INCONCLUSIVE
    elif [ "$san_findings" -gt 0 ] || [ "$vg_errors" -gt 0 ]; then
        verdict=ISSUE
    elif [ "$status" = ERROR ] || [ "$status" = WARNING ]; then
        verdict=ISSUE
    fi

    sample=$(scan_sample "$dir" "$SAN_RE|$VG_ERR_RE" 5)
    sample_json=""
    if [ -n "$sample" ]; then
        while IFS= read -r line; do
            [ -z "$sample_json" ] || sample_json="$sample_json,"
            sample_json="$sample_json
      \"$(json_escape "$line")\""
        done <<< "$sample"
    fi

    result="{
    \"package\": \"$(json_escape "$pkg")\",
    \"version\": \"$(json_escape "$version")\",
    \"flavor\": \"$(json_escape "$flavor")\",
    \"cran_issue_kind\": \"$(json_escape "$issue_kind")\",
    \"verdict\": \"$verdict\",
    \"status\": \"$status\",
    \"counts\": {\"error\": $n_error, \"warning\": $n_warning, \"note\": $n_note},
    \"instrumentation\": {
      \"sanitizer_findings\": $san_findings,
      \"valgrind_ran\": $([ "$vg_lines" -gt 0 ] && echo true || echo false),
      \"valgrind_errors\": $vg_errors
    },
    \"failed_checks\": [$checks_json],
    \"instrumentation_sample\": [$sample_json]
  }"

    printf '%s\n' "$result" > "$dir/rcheck-result.json"
    results+=("$result")
    ## TSV sidecar with the same facts. Downstream tools (rcheck compare, the
    ## evaluation harness) consume this rather than the JSON so that they need
    ## no JSON parser -- jq is not present in the base image and cannot be
    ## assumed on a user's host either.
    rows+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$pkg" "$version" "$flavor" "$issue_kind" "$verdict" "$status" \
        "$n_error" "$n_warning" "$san_findings" "$vg_errors")")
    echo "== $pkg ${version:+$version }[$flavor] -> $verdict (status $status, ${san_findings} sanitizer finding(s))"
done

if [ -n "$outdir" ] && [ ${#results[@]} -gt 0 ]; then
    mkdir -p "$outdir"
    {
        printf 'package\tversion\tflavor\tcran_issue_kind\tverdict\tstatus\tn_error\tn_warning\tsanitizer_findings\tvalgrind_errors\n'
        for r in "${rows[@]}"; do printf '%s\n' "$r"; done
    } > "$outdir/rcheck-results.tsv"
    {
        printf '[\n  '
        first=1
        for r in "${results[@]}"; do
            [ $first -eq 1 ] || printf ',\n  '
            first=0
            printf '%s' "$r"
        done
        printf '\n]\n'
    } > "$outdir/rcheck-results.json"
    echo "== wrote $outdir/rcheck-results.json and .tsv (${#results[@]} package(s))"
fi

[ ${#results[@]} -gt 0 ] || exit 1
exit 0
