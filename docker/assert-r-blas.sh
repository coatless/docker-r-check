#!/bin/sh
# assert-r-blas.sh -- fail unless the R that was just built is using the BLAS
# its flavour claims.
#
#   assert-r-blas.sh <flavour> [R-binary]
#
# WHY THIS IS NOT PARANOIA
#
# Nothing upstream of here reports a wrong BLAS as an error.  build-R exits 0
# whatever happened; configure falls back to R's internal reference BLAS with a
# note rather than a failure if the external one does not link; and
# update-alternatives switches a symlink whose NAME is identical whichever
# implementation it points at.  So an arm can be built, tagged, published and
# scored while running something other than what its label says, and every step
# in between reports success.
#
# The comparison is therefore against a RESOLVED REALPATH, not against a
# library name and not against the alternatives symlink.  Debian's serial and
# pthread OpenBLAS both answer to "libopenblas.so.0" and both report themselves
# to R as OpenBLAS; only the realpath distinguishes them, and it is the serial
# one that matches Ripley.
#
# The whole point of these images is a number that can be attributed.  An
# unattributable number is worse than no number, because it will be believed.

set -eu

FLAVOUR="${1:?usage: assert-r-blas.sh <flavour> [R-binary]}"
RBIN="${2:-/build/bin/R}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WIRING="${RCC_WIRING:-$HERE/blas-wiring.sh}"

[ -x "$RBIN" ] || { echo "assert-r-blas.sh: no R at $RBIN" >&2; exit 1; }

want="$(sh "$WIRING" expect "$FLAVOUR")"

# La_library() is the LAPACK; extSoftVersion()[["BLAS"]] is the BLAS.  Ask for
# both, and resolve symlinks in R rather than in the shell so what is compared
# is what R itself opened.
report="$("$RBIN" --no-echo --vanilla -e '
  b <- tryCatch(extSoftVersion()[["BLAS"]], error = function(e) "")
  l <- tryCatch(La_library(),               error = function(e) "")
  n <- function(p) if (nzchar(p)) normalizePath(p, mustWork = FALSE) else "(internal)"
  cat("blas=",   n(b), "\n", sep = "")
  cat("lapack=", n(l), "\n", sep = "")
  cat("laver=",  tryCatch(La_version(), error = function(e) "?"), "\n", sep = "")
' 2>&1)" || { echo "assert-r-blas.sh: R failed to start" >&2; echo "$report" >&2; exit 1; }

blas="$(printf '%s\n' "$report"   | sed -n 's/^blas=//p')"
lapack="$(printf '%s\n' "$report" | sed -n 's/^lapack=//p')"
laver="$(printf '%s\n' "$report"  | sed -n 's/^laver=//p')"

echo "assert-r-blas.sh: flavour=$FLAVOUR"
echo "  BLAS   : $blas"
echo "  LAPACK : $lapack ($laver)"

if [ -z "$want" ]; then
    echo "  (no external BLAS expected for this flavour; recorded, not asserted)"
else
    case "$blas" in
    *"$want"*)
        echo "  ok: matches expected fragment '$want'"
        ;;
    *)
        echo "" >&2
        echo "** ERROR: $FLAVOUR is not using the BLAS it claims." >&2
        echo "   expected a path containing: $want" >&2
        echo "   R is actually using:        $blas" >&2
        echo "" >&2
        echo "   Most likely the alternatives were switched after the build, or" >&2
        echo "   configure could not link the external BLAS and silently fell" >&2
        echo "   back to R's internal one.  Check the BLAS section of config.log." >&2
        exit 1
        ;;
    esac
fi

install -d /etc/rcheck
{
    echo "flavour: $FLAVOUR"
    echo "r_blas: $blas"
    echo "r_lapack: $lapack"
    echo "r_lapack_version: $laver"
    echo "r_version: $("$RBIN" --version 2>/dev/null | head -n1)"
    echo "--- libR.so linkage ---"
    (readelf -d /build/lib/libR.so 2>/dev/null | grep -E 'NEEDED' || echo "(none)")
} > /etc/rcheck/r-blas.txt 2>/dev/null || true

echo "assert-r-blas.sh: ok"
