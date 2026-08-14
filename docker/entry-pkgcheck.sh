#!/bin/bash

if [ ! -e /build/bin/R ] || ! /build/bin/R --version | head -n1; then
    echo "** ERROR: /build not mounted with working R build!"
    echo ''
    echo 'Please make sure you start the container with -v $(pwd)/build:/build or similar.'
    echo ''
    exit 1
fi

set -e
if [ ! -e /pkg ]; then
    if [ -e /build/pkg ]; then
	echo " == found /build/pkg - using it for checks"
	sudo ln -sfn /build/pkg /pkg
    else
	echo "** ERROR: /pkg not mounted!"
	echo ''
	echo 'Please make sure you start the container with -v $(pwd)/pkg:/pkg or similar.'
	echo 'Alternatively, you can put the packages in /build/pkg, i.e., in the pkg'
	echo 'subdirectory of your R build'
	echo ''
	exit 1
    fi
fi

## the check scripts rely on the structure where QA is the home
ln -sfn /src/QA/bin ~/bin
ln -sfn /src/QA/lib ~/lib
## the work space is ~/tmp/CRAN
if [ ! -e /build/CRAN ]; then
    mkdir /build/CRAN
fi
if [ ! -e ~/tmp ]; then
    mkdir ~/tmp
fi
ln -sfn /build/CRAN ~/tmp/CRAN

## handle .R
mkdir -p ~/.R
cp /src/QA/.R/* ~/.R/

## ---------------------------------------------------------------------------
## Flavor
## ---------------------------------------------------------------------------
## Applied after the QA .R settings are copied, so that flavor settings win over
## the defaults but everything CRAN sets and the flavor does not touch survives.

if [ -n "${RCHECK_FLAVOR}" ]; then
    . /rcheck/lib/flavor.sh
    rcheck_flavor_load "${RCHECK_FLAVOR}"
    echo "== flavor ${FLAVOR_ID}: ${FLAVOR_TITLE}"
    if [ "${STATUS}" = planned ]; then
        echo "** ERROR: flavor ${FLAVOR_ID} is STATUS=planned and is not usable." >&2
        exit 1
    fi

    ## R CMD check reads this file itself, which is why it is the preferred
    ## channel for flavor settings: it works no matter how check_CRAN_incoming
    ## chooses to invoke the check.
    rcheck_flavor_write_check_renviron ~/.R/check.Renviron
    ## Only point R at the file if it exists -- a flavor with no check-time
    ## settings creates none, and R_CHECK_ENVIRON naming a missing file is
    ## worse than leaving it at the default. Written as an if rather than
    ## `[ -f ... ] && export ...` because under `set -e` the latter would end
    ## the script for every flavor that sets no check-time variables.
    if [ -f ~/.R/check.Renviron ]; then
        export R_CHECK_ENVIRON=~/.R/check.Renviron
    fi

    ## Sanitizer and BLAS runtime settings, which are not R settings and so
    ## cannot travel through check.Renviron.
    rcheck_flavor_export_runtime_env

    if [ -s ~/.R/check.Renviron ]; then
        echo "== ~/.R/check.Renviron"
        sed 's/^/   /' ~/.R/check.Renviron
    fi
fi

## repos relies on local copies so check if they are mounted, otherwise replace with online versions
if [ ! -e /data/Repositories ]; then
    echo NOTE: local /data/Repositories are not mounted, switching to online versions
    ## P3M_SNAPSHOT pins the *package graph* to a date, which is the second of
    ## the two moving targets (the first being the OS, pinned by
    ## DEBIAN_SNAPSHOT at image build time). Without it, a check that passes
    ## today can fail tomorrow because a dependency changed, and the result is
    ## not attributable to anything.
    if [ -z "${CRAN_MIRROR}" -a -n "${P3M_SNAPSHOT}" ]; then
        CRAN_MIRROR="https://packagemanager.posit.co/cran/${P3M_SNAPSHOT}"
        echo "== CRAN packages pinned to P3M snapshot ${P3M_SNAPSHOT}"
    fi
    if [ -z "${CRAN_MIRROR}" ]; then CRAN_MIRROR=https://cloud.r-project.org; fi
    ## there is a lot of stuff in the regular Rprofile that is local, so we replace it
    ## with a smaller version - FIXME: it would be nice to decouple the local and global parts
    echo "local({ utils::setRepositories(FALSE,1:4); r=getOption('repos'); r[1]='${CRAN_MIRROR}'; options(repos=r) })" > ~/.R/Rprofile
    ## we also need a site version of this
    if [ ! -e /build/etc/Rprofile.site ]; then
	echo "local({ utils::setRepositories(FALSE,1:4); r=getOption('repos'); r[1]='${CRAN_MIRROR}'; options(repos=r) })" > /build/etc/Rprofile.site
    fi
    ## the last part of Rprofile in QA
    cat << 'EOF' >> ~/.R/Rprofile
options(showErrorCalls = TRUE,
        showWarnCalls = TRUE,
        warn = 1)

## When moving towards avoiding partial matching && friends:
options(warnPartialMatchArgs = TRUE,
        warnPartialMatchAttr = TRUE,
        warnPartialMatchDollar = TRUE)

## Ensure CRAN versions where available.
options(available_packages_filters =
            c("R_version", "OS_type", "subarch", "CRAN", "duplicates"))
EOF
fi

## R is in ~/tmp/R
ln -sfn /build ~/tmp/R

## copy packages (like getIncoming)
cp -p /pkg/*.tar.gz ~/tmp/CRAN/
ls -l ~/tmp/CRAN/

export PATH=$HOME/bin:$PATH

cd ~/tmp/CRAN
mkdir -p Library

## FIXME: tools suggest xml2, curl and others which are required for the checks,
## but they are not auto-installed. So until that is fixed, we have to manually
## install those
R_LIBS=$HOME/tmp/CRAN/Library MAKEFLAGS=-j6 /build/bin/Rscript -e 'p=c("curl","xml2"); i=p[!p %in% rownames(installed.packages())]; if(length(i)) install.packages(i)'

## CHECK_EXTRA_ARGS is the low-confidence channel -- see docs/open-questions.md
## Q4 -- so say out loud when a flavor is relying on it.
if [ -n "${CHECK_EXTRA_ARGS}" ]; then
    echo "== passing flavor check arguments to check_CRAN_incoming: ${CHECK_EXTRA_ARGS}"
    echo "   (if these end up ignored the check still runs, but WITHOUT this"
    echo "    flavor's instrumentation -- rcheck summarise will flag that)"
fi

set +e
# shellcheck disable=SC2086  # CHECK_EXTRA_ARGS is a deliberate word list
check_CRAN_incoming -n ${CHECK_EXTRA_ARGS} "$@"
check_status=$?
set -e

## ---------------------------------------------------------------------------
## Machine-readable results
## ---------------------------------------------------------------------------
## Summarising here rather than on the host means the results land in the bind
## mount alongside the logs, and that an Apptainer or remote run produces the
## same artefacts as a local docker run.

if [ -x /rcheck/tools/summarise-check.sh ]; then
    /rcheck/tools/summarise-check.sh \
        --flavor "${RCHECK_FLAVOR:-unflavored}" \
        --issue-kind "${CRAN_ISSUE_KIND}" \
        --outdir /build/CRAN \
        /build/CRAN/*.Rcheck || echo "** WARNING: result summarisation failed" >&2
fi

exit $check_status
