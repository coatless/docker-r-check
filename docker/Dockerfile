## Images for reproducing CRAN's checks.
##
## Build context is the repository root, not this directory, because the image
## carries the flavor definitions and the result tooling:
##
##   docker build -f docker/Dockerfile --target build-r -t rchk-build-r:nold .
##
## bin/rcheck builds these for you and fills in the pinned digest; the manual
## invocation is documented in README.md for the case where you want to drive
## docker yourself.
##
## Three build arguments do the reproducibility work:
##
##   BASE_DIGEST_SUFFIX  "@sha256:..." from pins/base-images.tsv, so the base
##                       image is immutable rather than whatever :unstable
##                       happens to be today
##   DEBIAN_SNAPSHOT     snapshot.debian.org timestamp, so apt installs the
##                       same package versions on every rebuild
##   R_SVN_REV           (runtime, not build) the R sources revision
##
## Leave them empty and the image still builds -- it just is not reproducible,
## and rcheck says so rather than letting you assume otherwise.

ARG BASE_IMAGE=docker.io/debian
ARG BASE_TAG=unstable
ARG BASE_DIGEST_SUFFIX=

## Target: base - base image with rcheckserver
FROM ${BASE_IMAGE}:${BASE_TAG}${BASE_DIGEST_SUFFIX} AS base

ARG DEBIAN_MIRROR=http://deb.debian.org
ENV DEBIAN_MIRROR=${DEBIAN_MIRROR}
ARG DEBIAN_SNAPSHOT=
ENV DEBIAN_SNAPSHOT=${DEBIAN_SNAPSHOT}
ARG APT_COMPONENTS=main
ARG RCHECK_FLAVOR=

## Record what this image is, so that a container found running six months from
## now can still say what it was built from.
LABEL org.opencontainers.image.source="https://github.com/s-u/docker-r-check" \
      org.opencontainers.image.description="Reproducible containers for CRAN's additional checks"
RUN mkdir -p /etc/rcheck
RUN printf '{"base_image": "%s", "base_tag": "%s", "base_digest_suffix": "%s", "debian_snapshot": "%s", "apt_components": "%s", "flavor": "%s"}\n' \
    "${BASE_IMAGE}" "${BASE_TAG}" "${BASE_DIGEST_SUFFIX}" "${DEBIAN_SNAPSHOT}" "${APT_COMPONENTS}" "${RCHECK_FLAVOR}" \
    > /etc/rcheck/image.json

## Point apt at the pinned archive first, so that DEBIAN_MIRROR applies to the
## very first update and DEBIAN_SNAPSHOT governs every package this image ever
## installs -- including the ca-certificates below.
COPY docker/apt-setup.sh /rcheck/bin/apt-setup.sh
RUN APT_COMPONENTS="${APT_COMPONENTS}" bash /rcheck/bin/apt-setup.sh

## main setup; apt cannot pull from other repos without ca-certificates so have to install that one first
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked   \
    apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get -y upgrade && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get -y install ca-certificates

## install key and WU sources
COPY docker/aasc.sources /etc/apt/sources.list.d/aasc.sources
COPY docker/aasc-archive.pgp /etc/apt/keyrings/aasc-archive.pgp

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

## The flavor this image was built for. The entrypoints load the matching
## definition; bin/rcheck also passes it at run time, so an image can be reused
## across flavors that share a base and sysdeps.
ARG RCHECK_FLAVOR=
ENV RCHECK_FLAVOR="${RCHECK_FLAVOR}"

## those can be set during build-time, but we can also re-set those to match the mounts so not very important
ARG UID=1000
ARG GID=1000

## setup a build user + sudo
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get -y install sudo && /sbin/groupadd -g ${GID} rbuild && /sbin/useradd -m -u ${UID} -g ${GID} rbuild && echo 'rbuild ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/10rbuild

## prepare sources if not mounted so we can cache long pulls (mostly relevant to remote places like NZ ;))
RUN mkdir -p /src && \
    svn co https://svn.r-project.org/R-dev-web/trunk/CRAN/QA/Kurt /src/QA && \
    svn co https://svn.r-project.org/R/trunk /src/R && ( cd /src/R && tools/rsync-recommended ) && \
    chown -R rbuild:rbuild /src

## install additional sysdeps
RUN if [ -n "${R_BUILD_SYSDEPS}" ]; then apt-get update -qq && DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get -y install ${R_BUILD_SYSDEPS}; fi

## Flavor definitions and the result tooling travel with the image, so that a
## container pulled from a registry is self-contained. bin/rcheck additionally
## bind-mounts a working copy over /rcheck/flavors.local, which takes priority,
## so a flavor can be edited without rebuilding.
COPY docker/lib/ /rcheck/lib/
COPY flavors/ /rcheck/flavors/
COPY tools/summarise-check.sh tools/summarise-check.awk /rcheck/tools/
RUN chmod +x /rcheck/tools/summarise-check.sh

## copy the entrypoint which will update SVN (unless NO_UPDATE is set) and run the build
COPY docker/entry-build-r.sh /entry-build-r.sh

USER rbuild

ENTRYPOINT [ "/bin/bash", "/entry-build-r.sh" ]


FROM build-r AS pkgcheck

COPY docker/entry-pkgcheck.sh /entry-pkgcheck.sh
ENTRYPOINT [ "/bin/bash", "/entry-pkgcheck.sh" ]
