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

## settings the arm needs while checking, written by flavour-setup.sh
if [ -r /etc/rcheck/check.env ]; then
    set -a
    . /etc/rcheck/check.env
    set +a
fi

## repos relies on local copies so check if they are mounted, otherwise replace with online versions
if [ ! -e /data/Repositories ]; then
    echo NOTE: local /data/Repositories are not mounted, switching to online versions
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

## RCC_RUNNER=dir checks through tools::check_packages_in_dir(), using the QA
## tree's newer check-CRAN-incoming, with several packages at a time. -r keeps
## the meaning it has for check_CRAN_incoming, a check without the incoming
## checks. The script's first line names /usr/bin/Rscript, so run it with ours.
if [ "${RCC_RUNNER}" = dir ]; then
    runner_args="-n -N=${RCC_NCPUS:-$(nproc)}"
    case " $* " in
	*" -r "*) export _R_CHECK_CRAN_INCOMING_=false ;;
	*) runner_args="$runner_args -c" ;;
    esac
    exec /build/bin/Rscript --default-packages=NULL ~/bin/check-CRAN-incoming \
	 --exe /build/bin/R $runner_args
fi

check_CRAN_incoming -n "$@"
