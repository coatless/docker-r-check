#!/bin/bash

set -e
if [ ! -e /build ]; then
    echo "== /build not mounted, creating container-internal area"
    echo "   NOTE: you probably don't want to use --rm in this case"
    mkdir /build
fi

## R's recommended packages, over HTTPS with rsync as the fallback
recommended() {
    sh /opt/rcheck/fetch-recommended.sh /src/R || ( cd /src/R && tools/rsync-recommended )
}

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
    svn co https://svn.r-project.org/R/trunk /src/R && recommended
else
    if [ -z "${NO_UPDATE}" -a -e /src/R/.svn ]; then
	echo ==	Updating R from SVN
        ( cd /src/R && svn up ) && recommended
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

## Two files in the QA tree's .R/ are specific to one machine.
##
## .R/config sets -mtune=native in CFLAGS, CXXFLAGS and FFLAGS, and R's
## configure reads ${HOME}/.R/config. Remove the flag, or R is compiled for
## the CPU of whichever machine builds the image.
if [ -e ~/.R/config ]; then
    sed -i 's/[[:space:]]*-mtune=native//g' ~/.R/config
    if grep -q -- '-mtune=native' ~/.R/config; then
        echo "** ERROR: failed to strip -mtune=native from ~/.R/config" >&2
        exit 1
    fi
fi

## .R/Rprofile refers to a local CRAN mirror and to programs that are not in
## the image. entry-pkgcheck.sh writes a usable one.
rm -f ~/.R/Rprofile

cd /build
export PATH=/src/QA/bin:$PATH

## build-R overrides MAKE with -j which doesn't work well with submakes,
## so force MAKE=make and rely on MAKEFLAGS instead
export MAKE=${MAKE-make}
export MAKEFLAGS=${MAKEFLAGS-"-j2"}

## build-R ends in a pipeline through tee, so its exit status is always 0.
## Running it under bash -o pipefail makes a failed build or make check fail
## here. Checking for /build/bin/R is not enough, because a mounted /build
## can still hold the R from an earlier build.
rc=0
bash -o pipefail "$(command -v build-R)" "$@" || rc=$?
if [ "$rc" -ne 0 ]; then
    echo '' >&2
    echo "** ERROR: the R build failed (exit $rc).  See /build/log." >&2
    echo '' >&2
    exit "$rc"
fi

if ! /build/bin/R --version >/dev/null 2>&1; then
    echo '' >&2
    echo "** ERROR: the build reported success but /build/bin/R does not run." >&2
    echo '' >&2
    exit 1
fi
