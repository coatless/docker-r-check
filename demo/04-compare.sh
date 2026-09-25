#!/bin/bash
# Check the same packages in several arms and compare the results.
#
#   demo/04-compare.sh "reference openblas" digest
#   demo/04-compare.sh "reference openblas atlas" path/to/pkg_1.0.tar.gz
#
# The first arm is the baseline. Every other arm's 00check.log is diffed
# against it after timings are removed. Uses demo/03-check.sh, so the per-arm
# output stays in results/<flavour>/<package>/.
#
# Every arm installs its dependencies from the same dated CRAN snapshot
# (yesterday's, unless CRAN_MIRROR is set). Otherwise a dependency released
# between two runs could look like a BLAS difference. In RCC_MODE=incoming
# the arms install from live CRAN, because the incoming checks need
# PACKAGES.in.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

[ $# -ge 2 ] || die "usage: $0 \"<flavour> <flavour>...\" <package|tarball>..."
read -r -a arms <<<"$1"; shift
[ "${#arms[@]}" -ge 2 ] || die "name at least two arms, e.g. \"reference openblas\""
for fl in "${arms[@]}"; do need_image "$fl"; done

worst=0
if [ "${RCC_COMPARE_ONLY:-0}" != 0 ]; then
    # Compare the results of earlier demo/03-check.sh runs without rerunning
    # them. Each arm's manifest.dcf records which mirror it used.
    echo "comparing existing results only (RCC_COMPARE_ONLY is set)"
else
    if [ "${RCC_MODE:-regular}" = incoming ]; then
        export CRAN_MIRROR="${CRAN_MIRROR:-https://cloud.r-project.org}"
    else
        export CRAN_MIRROR="${CRAN_MIRROR:-https://packagemanager.posit.co/cran/$(snapshot_date 1)}"
    fi
    echo "dependencies from: $CRAN_MIRROR"
    for fl in "${arms[@]}"; do
        # An arm that fails before checking must not leave an older run's
        # results in place to be compared.
        for arg in "$@"; do
            p="$(basename "$arg")"; p="${p%%_*}"
            case "$p" in [A-Za-z]*) rm -rf "${RESULTS:?}/$fl/$p" ;; esac
        done
        "$(dirname "$0")/03-check.sh" "$fl" "$@"
        rc=$?
        [ "$rc" -le "$worst" ] || worst=$rc
    done
fi

# field <manifest.dcf> <Field> prints one field of a run's manifest.
field() { sed -n "s/^$2: //p" "$1" 2>/dev/null | head -n 1; }

# Timings, the clock and the header naming paths and platform are the only
# things expected to differ between two clean runs.  Past 600 s R prints
# minutes, and --timings adds tables of example times.
normalise() {
    sed -E -e '/^\* (using |current time: )/d' \
        -e '/^Examples with CPU/,/^\* /{/^\* /!d;}' \
        -e 's/ ?\[[0-9]+[sm](\/[0-9]+[sm])?\]//g; s/[0-9.]+ ?s(ec)? elapsed//g' "$1"
}

echo
echo "================ comparison (baseline: ${arms[0]}) ================"
for arg in "$@"; do
    pkg="$(basename "$arg")"; pkg="${pkg%%_*}"
    printf '%s\n' "$pkg"
    mirrors=""
    for fl in "${arms[@]}"; do
        m="$RESULTS/$fl/$pkg/manifest.dcf"
        s="$(check_status "$RESULTS/$fl/$pkg/$pkg.Rcheck/00check.log")"
        core="$(field "$m" OpenBLAS-Core)"
        printf '  %-12s %-28s mode=%s%s\n' "$fl" "${s:-did not complete}" \
            "$(field "$m" Mode)" "${core:+  openblas-core=$core}"
        mirrors="$mirrors$(field "$m" CRAN-Mirror)"$'\n'
        v="$(field "$m" Verdict)"
        [ "${v:-2}" -le "$worst" ] || worst=${v:-2}
    done
    if [ "$(printf '%s' "$mirrors" | sort -u | grep -c .)" -gt 1 ]; then
        echo "  WARNING: the arms installed dependencies from different mirrors:"
        printf '%s' "$mirrors" | sort -u | sed 's/^/    /'
    fi
    base="$RESULTS/${arms[0]}/$pkg/$pkg.Rcheck/00check.log"
    for fl in "${arms[@]:1}"; do
        other="$RESULTS/$fl/$pkg/$pkg.Rcheck/00check.log"
        [ -f "$base" ] && [ -f "$other" ] || continue
        # The header names the platform and paths, not the BLAS.
        d="$(diff <(normalise "$base") <(normalise "$other"))"
        if [ -z "$d" ]; then
            printf '  %s vs %s: 00check.log identical apart from timings\n' "${arms[0]}" "$fl"
        else
            printf '  %s vs %s: 00check.log differs\n' "${arms[0]}" "$fl"
            printf '%s\n' "$d" | sed 's/^/    /'
        fi
    done
done
exit "$worst"
