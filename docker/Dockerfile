## specify the favor of Debian to create the image from. Can be set on CLI, example:
##
##   docker build --build-arg DEBIAN_TAG=testing --target base -t rchk-base:testing .

ARG DEBIAN_TAG=unstable

## Target: base - base image with rcheckserver
FROM docker.io/debian:${DEBIAN_TAG} AS base

ARG DEBIAN_MIRROR=http://deb.debian.org
ENV DEBIAN_MIRROR=${DEBIAN_MIRROR}

## main setup; apt cannot pull from other repos without ca-certificates so have to install that one first
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked   \
    sed -i "s,http://deb[.]debian[.]org,${DEBIAN_MIRROR},g" /etc/apt/sources.list.d/debian.sources && \
    cat /etc/apt/sources.list.d/debian.sources && \
    apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get -y upgrade && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get -y install ca-certificates

## install key and WU sources
COPY aasc.sources /etc/apt/sources.list.d/aasc.sources
COPY aasc-archive.pgp /etc/apt/keyrings/aasc-archive.pgp

## install rcheckserver
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get -y install rcheckserver
## add source repos
RUN sed -i 's/^Types: deb/\0 deb-src/g' /etc/apt/sources.list.d/debian.sources && apt-get update -qq && DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get -y build-dep r-base
## setup locales
RUN DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get -y install locales && \
    echo 'C.UTF-8 UTF-8~en_US.UTF-8 UTF-8' | tr '~' '\n' > /etc/locale.gen  && locale-gen


## Target: build-r - image for building R, caches R sources and QA/Kurt
FROM base AS build-r

## list of additional system depenencies for the R build image (e.g. specific BLAS libraries)
## can be empty if default setup is sufficient
ARG R_BUILD_SYSDEPS
ENV R_BUILD_SYSDEPS="${R_BUILD_SYSDEPS}"

## those can be set during build-time, but we can also re-set those to match the mounts so not very important
ARG UID=1000
ARG GID=1000

## setup a build user + sudo
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get -y install sudo && /sbin/groupadd -g ${GID} rbuild && /sbin/useradd -m -u ${UID} -g ${GID} rbuild && echo 'rbuild ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/10rbuild

## Revisions to check out.  Empty means trunk HEAD, which is what upstream does
## and is not reproducible: two builds a week apart are different R sources
## under the same tag.  Set these for anything whose results get recorded.
ARG R_SVN_REV=
ARG QA_SVN_REV=

## prepare sources if not mounted so we can cache long pulls (mostly relevant to remote places like NZ ;))
RUN mkdir -p /src && \
    svn co ${QA_SVN_REV:+-r ${QA_SVN_REV}} https://svn.r-project.org/R-dev-web/trunk/CRAN/QA/Kurt /src/QA && \
    svn co ${R_SVN_REV:+-r ${R_SVN_REV}} https://svn.r-project.org/R/trunk /src/R && ( cd /src/R && tools/rsync-recommended ) && \
    ( cd /src/R && svn info --show-item revision > /etc/rcheck-r-svn-rev ) && \
    ( cd /src/QA && svn info --show-item revision > /etc/rcheck-qa-svn-rev ) && \
    chown -R rbuild:rbuild /src

## install additional sysdeps
RUN if [ -n "${R_BUILD_SYSDEPS}" ]; then apt-get update -qq && DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get -y install ${R_BUILD_SYSDEPS}; fi

## The check arm.  Empty leaves the image exactly as upstream builds it, so
## R_BUILD_SYSDEPS keeps working for anyone using it that way.
##
## This has to happen BEFORE R is built, not after: `Rconf -bo` emits
## --with-blas=-lopenblas, so the library has to be installed and the
## alternatives already pointing at the right one when configure runs its link
## test.  Wiring it afterwards would give an R configured against whatever was
## there at the time and a set of symlinks that merely look right.
ARG RCC_FLAVOUR=
COPY blas-wiring.sh flavour-setup.sh assert-r-blas.sh /opt/rcheck/
COPY flavours /opt/rcheck/flavours
RUN chmod 0755 /opt/rcheck/*.sh && \
    if [ -n "${RCC_FLAVOUR}" ]; then \
        sh /opt/rcheck/flavour-setup.sh "${RCC_FLAVOUR}" /opt/rcheck/flavours; \
    fi

## copy the entrypoint which will update SVN (unless NO_UPDATE is set) and run the build
COPY entry-build-r.sh /entry-build-r.sh

USER rbuild

ENTRYPOINT [ "/bin/bash", "/entry-build-r.sh" ]


FROM build-r AS pkgcheck

COPY entry-pkgcheck.sh /entry-pkgcheck.sh
ENTRYPOINT [ "/bin/bash", "/entry-pkgcheck.sh" ]


## Target: standalone - pkgcheck with R already built inside, so the image can
## be published and pulled.
##
## build-r and pkgcheck both require the caller to bind-mount a host directory
## at /build and compile R into it; entry-pkgcheck.sh hard-fails without it.
## That is the right shape for iterating -- build R once, check many packages --
## and it means the image is not a self-contained artefact.  A maintainer
## reproducing a CRAN result should not have to compile R first.
##
## R is built into /build with the same out-of-tree layout the mounted flow
## produces, rather than being `make install`ed to a prefix, so entry-pkgcheck.sh
## and everything downstream work unchanged.  build-R has no install step anyway.
##
##   docker build --target standalone \
##     --build-arg RCC_FLAVOUR=openblas --build-arg R_SVN_REV=90393 .
FROM pkgcheck AS standalone

ARG RCC_FLAVOUR=reference
ARG MAKEFLAGS=-j4
ARG BUILD_DATE=

USER root
RUN install -d -o rbuild -g rbuild /build
USER rbuild

## NO_UPDATE=1: the sources were pinned in build-r; letting the entrypoint svn
## up here would silently undo that at image-build time.
RUN set -eu; \
    . /opt/rcheck/flavours/${RCC_FLAVOUR}.env; \
    echo "building R for flavour ${RCC_FLAVOUR} with Rconf ${RCC_RCONF_FLAGS}"; \
    NO_UPDATE=1 MAKEFLAGS="${MAKEFLAGS}" \
        /bin/bash /entry-build-r.sh ${RCC_RCONF_FLAGS} ${RCC_LDFLAGS}

## Three separate assertions, because each catches something the others do not:
## the build produced an R; the alternatives still point where the flavour says;
## and R itself opened the library we meant.  build-R's exit status catches none
## of them.
USER root
RUN set -eu; \
    /build/bin/R --version; \
    sh /opt/rcheck/blas-wiring.sh verify "${RCC_FLAVOUR}"; \
    sh /opt/rcheck/assert-r-blas.sh "${RCC_FLAVOUR}" /build/bin/R; \
    { \
      echo "flavour: ${RCC_FLAVOUR}"; \
      echo "built: ${BUILD_DATE:-unrecorded}"; \
      echo "r_svn_rev: $(cat /etc/rcheck-r-svn-rev 2>/dev/null || echo unknown)"; \
      echo "qa_svn_rev: $(cat /etc/rcheck-qa-svn-rev 2>/dev/null || echo unknown)"; \
      echo "debian: $(. /etc/os-release; echo "$VERSION_CODENAME")"; \
      echo "glibc: $(ldd --version | head -n1)"; \
      cat /etc/rcheck/r-blas.txt 2>/dev/null || true; \
    } > /etc/rcheck/manifest.txt; \
    cat /etc/rcheck/manifest.txt

LABEL org.opencontainers.image.title="r-check-containers" \
      org.opencontainers.image.description="CRAN additional-check arm, R built in"

USER rbuild
ENTRYPOINT [ "/bin/bash", "/entry-pkgcheck.sh" ]

