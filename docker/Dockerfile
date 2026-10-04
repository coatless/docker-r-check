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

## rcheckserver installs on arm64 too, but without quarto and openbugs, which
## exist only for amd64. Stop unless a non-amd64 base was asked for.
ARG ALLOW_NON_AMD64=
RUN arch="$(dpkg --print-architecture)"; \
    if [ "$arch" != amd64 ] && [ -z "${ALLOW_NON_AMD64}" ]; then \
        echo "** ERROR: this base is $arch; build with --platform linux/amd64" >&2; \
        echo "   (or --build-arg ALLOW_NON_AMD64=1 for a base without quarto and openbugs)" >&2; \
        exit 1; \
    fi


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
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get -y install sudo && /sbin/groupadd -o -g ${GID} rbuild && /sbin/useradd -m -u ${UID} -g ${GID} rbuild && echo 'rbuild ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/10rbuild

## SVN revisions to check out. Empty means trunk HEAD, so set both for a
## build that should be repeatable.
ARG R_SVN_REV=
ARG QA_SVN_REV=

## prepare sources if not mounted so we can cache long pulls (mostly relevant to remote places like NZ ;))
## The recommended packages come over HTTPS, with rsync as the fallback,
## because CRAN's rsync server limits its connections.
COPY fetch-recommended.sh /opt/rcheck/fetch-recommended.sh
RUN mkdir -p /src && \
    svn co ${QA_SVN_REV:+-r ${QA_SVN_REV}} https://svn.r-project.org/R-dev-web/trunk/CRAN/QA/Kurt /src/QA && \
    svn co ${R_SVN_REV:+-r ${R_SVN_REV}} https://svn.r-project.org/R/trunk /src/R && ( sh /opt/rcheck/fetch-recommended.sh /src/R || ( cd /src/R && tools/rsync-recommended ) ) && \
    ( cd /src/R && svn info --show-item revision > /etc/rcheck-r-svn-rev ) && \
    ( cd /src/QA && svn info --show-item revision > /etc/rcheck-qa-svn-rev ) && \
    chown -R rbuild:rbuild /src

## install additional sysdeps
RUN if [ -n "${R_BUILD_SYSDEPS}" ]; then apt-get update -qq && DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get -y install ${R_BUILD_SYSDEPS}; fi

## The arm. Empty leaves the image as upstream builds it. The BLAS must be
## installed and selected before R is built, because R's configure links
## against whatever is selected at that point.
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


## Target: standalone - pkgcheck with R already built inside.
##
## build-r and pkgcheck expect a host directory mounted at /build and compile
## R into it. Here R is built into /build inside the image, in the same
## layout, so entry-pkgcheck.sh works unchanged and nothing needs mounting.
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

## NO_UPDATE=1 keeps the entrypoint from updating the pinned sources.
RUN set -eu; \
    . /opt/rcheck/flavours/${RCC_FLAVOUR}.env; \
    echo "building R for flavour ${RCC_FLAVOUR} with Rconf ${RCC_RCONF_FLAGS}"; \
    NO_UPDATE=1 MAKEFLAGS="${MAKEFLAGS}" \
        /bin/bash /entry-build-r.sh ${RCC_RCONF_FLAGS} ${RCC_LDFLAGS}

## Check that R runs, that the BLAS selection is still in place, and that R
## itself loads the arm's BLAS. Then record what was built.
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
      echo "arch: $(dpkg --print-architecture)"; \
      echo "glibc: $(ldd --version | head -n1)"; \
      cat /etc/rcheck/r-blas.txt 2>/dev/null || true; \
    } > /etc/rcheck/manifest.txt; \
    cat /etc/rcheck/manifest.txt

LABEL org.opencontainers.image.title="r-check-containers" \
      org.opencontainers.image.description="CRAN additional-check arm, R built in"

USER rbuild
ENTRYPOINT [ "/bin/bash", "/entry-pkgcheck.sh" ]

