#!/bin/bash
# Show what an arm is. Prints its build manifest, the BLAS and LAPACK that R
# loads, and a small numeric test whose digits differ between arms.
#
#   demo/02-inspect.sh reference openblas
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ $# -ge 1 ] || die "usage: $0 <flavour>..."

for fl in "$@"; do
    need_image "$fl"
    PLATFORM="$(platform_of "$fl")"
    echo "================ $fl ================"
    echo "--- /etc/rcheck/manifest.txt (written when the image was built)"
    "$ENGINE" run --rm --platform "$PLATFORM" --entrypoint cat "$(image "$fl")" /etc/rcheck/manifest.txt
    echo "--- what R reports at run time"
    # OPENBLAS_VERBOSE=2 makes OpenBLAS print the kernel it picked for this CPU,
    # which is how an emulated run can differ from a native one.
    "$ENGINE" run --rm --platform "$PLATFORM" -e OPENBLAS_VERBOSE=2 \
        --entrypoint /build/bin/Rscript "$(image "$fl")" --vanilla -e '
        cat("R            :", R.version.string, "\n")
        cat("svn rev      :", R.version[["svn rev"]], "\n")
        cat("BLAS         :", normalizePath(extSoftVersion()[["BLAS"]]), "\n")
        cat("LAPACK       :", normalizePath(La_library()), "(", La_version(), ")\n")
        cat("long double  :", .Machine$sizeof.longdouble, "bytes;",
            "sum(c(1, 1e-16, -1)) =", format(sum(c(1, 1e-16, -1))), "\n")
        set.seed(1); m <- crossprod(matrix(rnorm(1e4), 100))
        cat("chol ok      :", isTRUE(all.equal(crossprod(chol(m)), m)), "\n")
        cat("svd d[1]     :", format(svd(m)$d[1], digits = 17), "\n")
        cat("log det      :", format(determinant(m)$modulus[1], digits = 17), "\n")'
done
