#!/bin/bash

set -e
if [ ! -e /build ]; then
    echo "== /build not mounted, creating container-internal area"
    echo "   NOTE: you probably don't want to use --rm in this case"
    mkdir /build
fi

## /src will be populated in the image, but if it was mounted, check if it is complete
if [ ! -e /src/QA ]; then
    echo == /src mounted without QA, populating from SVN
    svn co https://svn.r-project.org/R-dev-web/trunk/CRAN/QA/Kurt /src/QA
else
    if [ -z "${NO_UPDATE}" ]; then
	echo == Updating QA from SVN
	( cd /src/QA && svn up )
    fi
fi

if [ ! -e /src/R ]; then
    echo == /src mounted without R sources, fetching R-devel
    svn co https://svn.r-project.org/R/trunk /src/R && ( cd /src/R && tools/rsync-recommended )
else
    if [ -z "${NO_UPDATE}" -a -e /src/R/.svn ]; then
	echo ==	Updating R from SVN
        ( cd /src/R && svn up && tools/rsync-recommended )
    fi
fi

## R script expects things in home
cd ~
ln -sfn /src .
## the build-R script logs into ~/tmp
mkdir -p /build/log
ln -sfn /build/log ~/tmp
mkdir -p ~/.R
## copy .R settings
cp -p /src/QA/.R/* ~/.R/

cd /build
export PATH=/src/QA/bin:$PATH

## build-R overrides MAKE with -j which doesn't work well with submakes,
## so force MAKE=make and rely on MAKEFLAGS instead
export MAKE=${MAKE-make}
export MAKEFLAGS=${MAKEFLAGS-"-j2"}

rc=0
build-R "$@" || rc=$?

## build-R runs the whole build as a single pipeline ending in `tee`, under
## /bin/sh, with neither `set -e` nor `pipefail`.  Its exit status is therefore
## tee's, which is 0 whatever the build did.  Verify the artefact instead:
## without this, a failed build leaves the container reporting success and
## anything driving it in CI publishes a broken image as a green one.
if [ ! -x /build/bin/R ] || ! /build/bin/R --version >/dev/null 2>&1; then
    echo '' >&2
    echo "** ERROR: R was not built.  /build/bin/R is missing or does not run." >&2
    echo "   build-R exited $rc, but that status comes from tee and does not" >&2
    echo "   reflect the build.  See /build/log for what actually happened." >&2
    echo '' >&2
    exit 1
fi

exit $rc
