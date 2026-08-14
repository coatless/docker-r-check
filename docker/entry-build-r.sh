#!/bin/bash

set -e
if [ ! -e /build ]; then
    echo "== /build not mounted, creating container-internal area"
    echo "   NOTE: you probably don't want to use --rm in this case"
    mkdir /build
fi

## R_SVN_REV pins the R sources to one revision. Without it a rebuild tomorrow
## builds a different R, which defeats the purpose of pinning everything else.
SVN_REV_OPT=""
if [ -n "${R_SVN_REV}" ]; then
    SVN_REV_OPT="-r ${R_SVN_REV}"
    echo "== R sources pinned to SVN revision ${R_SVN_REV}"
fi

## /src will be populated in the image, but if it was mounted, check if it is complete
if [ ! -e /src/QA ]; then
    echo == /src mounted without QA, populating from SVN
    svn co ${SVN_REV_OPT} https://svn.r-project.org/R-dev-web/trunk/CRAN/QA/Kurt /src/QA
else
    if [ -z "${NO_UPDATE}" ]; then
	echo == Updating QA from SVN
	( cd /src/QA && svn up ${SVN_REV_OPT} )
    fi
fi

if [ ! -e /src/R ]; then
    echo == /src mounted without R sources, fetching R-devel
    svn co ${SVN_REV_OPT} https://svn.r-project.org/R/trunk /src/R && ( cd /src/R && tools/rsync-recommended )
else
    if [ -z "${NO_UPDATE}" -a -e /src/R/.svn ]; then
	echo ==	Updating R from SVN
        ( cd /src/R && svn up ${SVN_REV_OPT} && tools/rsync-recommended )
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

## ---------------------------------------------------------------------------
## Flavor
## ---------------------------------------------------------------------------
## Without RCHECK_FLAVOR this script behaves exactly as it did before flavors
## existed: CRAN's build-R with no overrides. That is intentional -- the
## unflavored path is the one that is known to work upstream.

R_BUILD_METHOD=${R_BUILD_METHOD:-cran-qa}

if [ -n "${RCHECK_FLAVOR}" ]; then
    . /rcheck/lib/flavor.sh
    rcheck_flavor_load "${RCHECK_FLAVOR}"
    echo "== flavor ${FLAVOR_ID}: ${FLAVOR_TITLE}"
    echo "   from ${RCHECK_FLAVOR_FILE}"
    if [ "${STATUS}" = planned ]; then
        echo "** ERROR: flavor ${FLAVOR_ID} is STATUS=planned and is not usable." >&2
        echo "   See its NOTES in ${RCHECK_FLAVOR_FILE} for what is blocking it." >&2
        exit 1
    fi

    rcheck_flavor_write_config_site /build/config.site
    export CONFIG_SITE=/build/config.site
    rcheck_flavor_export_build_env

    echo "== generated /build/config.site"
    sed 's/^/   /' /build/config.site

    ## Provenance: what this R was actually built from. Written next to the
    ## build rather than only into the image, because the build directory is
    ## what gets reused across runs and what results have to be attributable to.
    {
        echo '{'
        echo "  \"flavor\": $(rcheck_flavor_json | sed 's/^/  /'),"
        echo "  \"r_svn_revision\": \"$(svnversion /src/R 2>/dev/null || echo unknown)\","
        echo "  \"qa_svn_revision\": \"$(svnversion /src/QA 2>/dev/null || echo unknown)\","
        echo "  \"r_build_method\": \"${R_BUILD_METHOD}\","
        if [ -f /etc/rcheck/image.json ]; then
            echo "  \"image\": $(cat /etc/rcheck/image.json),"
        fi
        echo "  \"built_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
        echo '}'
    } > /build/rcheck-build.json
fi

case "${R_BUILD_METHOD}" in
    cran-qa)
        exec build-R "$@"
        ;;
    configure)
        exec bash /rcheck/lib/build-r-configure.sh "$@"
        ;;
    *)
        echo "** ERROR: unknown R_BUILD_METHOD '${R_BUILD_METHOD}'" >&2
        exit 1
        ;;
esac
