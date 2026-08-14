#!/bin/bash
#
# Build R directly with configure && make, under full flavor control.
#
# The alternative -- and the default for flavors that do not need it -- is
# CRAN's own build-R script from the QA SVN tree, which is higher fidelity
# because it is literally what CRAN runs. But build-R chooses its own configure
# invocation, so a flavor that has to control the compiler driver
# (every sanitizer) or pass a configure option (noLD) cannot go through it.
#
# See docs/architecture.md ADR-0003 for why both paths exist rather than one.
#
# Expects the flavor to be already loaded and exported by entry-build-r.sh:
# CONFIG_SITE points at the generated config.site, and CC/CXX/... are exported.

set -e

RSRC=${RSRC:-/src/R}
BUILD=${BUILD:-/build}

[ -x "$RSRC/configure" ] || {
    echo "** ERROR: no R sources with a configure script at $RSRC" >&2
    exit 1
}

cd "$BUILD"

## R supports building outside the source tree, which is what keeps /src/R
## pristine and lets several flavors share one source checkout.
if [ ! -f Makefile ] || [ -n "${RCHECK_RECONFIGURE:-}" ]; then
    echo "== configuring R"
    echo "   source:      $RSRC"
    echo "   config.site: ${CONFIG_SITE:-<none>}"
    echo "   extra args:  ${R_CONFIGURE_ARGS:-<none>} $*"
    # shellcheck disable=SC2086  # R_CONFIGURE_ARGS is a deliberate word list
    "$RSRC/configure" ${R_CONFIGURE_ARGS:-} "$@"
else
    echo "== existing Makefile found, skipping configure"
    echo "   set RCHECK_RECONFIGURE=1 to force reconfiguration"
fi

echo "== building R (MAKEFLAGS=${MAKEFLAGS:-<unset>})"
"${MAKE:-make}"

## The check entrypoint looks for $BUILD/bin/R, which an in-tree build tree
## provides directly -- no `make install` step, deliberately, so that the build
## and the thing being checked are the same tree.
if [ ! -x "$BUILD/bin/R" ]; then
    echo "** ERROR: build finished but $BUILD/bin/R is missing" >&2
    exit 1
fi

"$BUILD/bin/R" --version | head -n 1
