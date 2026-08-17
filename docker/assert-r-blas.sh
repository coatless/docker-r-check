#!/bin/sh
# Fail unless the R that was just built uses the BLAS its arm names.
#
#   assert-r-blas.sh <flavour> [R-binary]
#
# No earlier step reports a wrong BLAS as an error. configure falls back to
# R's own BLAS when the external one does not link, and the alternatives
# symlink has the same name whichever library it points at. So this compares
# the resolved path of the library R loaded. Debian's serial and pthread
# OpenBLAS both load as libopenblas.so.0, and only the path tells them apart.

set -eu

FLAVOUR="${1:?usage: assert-r-blas.sh <flavour> [R-binary]}"
RBIN="${2:-/build/bin/R}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WIRING="${RCC_WIRING:-$HERE/blas-wiring.sh}"

[ -x "$RBIN" ] || { echo "assert-r-blas.sh: no R at $RBIN" >&2; exit 1; }

want="$(sh "$WIRING" expect "$FLAVOUR")"

# La_library() gives the LAPACK and extSoftVersion()[["BLAS"]] the BLAS.
# Symlinks are resolved in R, so the comparison uses what R opened.
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
