#!/bin/bash

DEBIAN_TAG="$1"
FLAVOR_TAG="$2"
R_BUILD_SYSDEPS="$3"

if [ "x$1" = x-h -o -z "${FLAVOR_TAG}" ]; then
    echo ''
    echo " Usage: $0 <debian-tag> <flavor-tag> [<sysdeps>]"
    echo ''
    if [ "x$1" = x-h ]; then
	exit 0
    fi
    echo "ERROR: missing <flavor-tag>"
    echo ''
    exit 1
fi

DEBIAN_MIRROR=${DEBIAN_MIRROR-http://deb.debian.org}

## The original entry point, kept working. It predates flavors and takes a
## sysdeps string rather than a flavor name; `bin/rcheck build <flavor>` is the
## same thing driven from a checked-in definition, with digest pinning.
##
## Build context is now the repository root (the image carries flavors/ and
## tools/), so this builds with -f rather than by cd'ing into docker/.

set -e
cd "$(dirname "$0")"
docker build -f docker/Dockerfile \
  --build-arg BASE_TAG=${DEBIAN_TAG} \
  --build-arg DEBIAN_MIRROR=${DEBIAN_MIRROR} \
  --build-arg UID=$(id -u) --build-arg GID=$(id -g) \
  --build-arg R_BUILD_SYSDEPS=${R_BUILD_SYSDEPS} \
  --target build-r -t rchk-build-r:${DEBIAN_TAG}-${FLAVOR_TAG} .

docker build -f docker/Dockerfile \
  --build-arg BASE_TAG=${DEBIAN_TAG} \
  --build-arg DEBIAN_MIRROR=${DEBIAN_MIRROR} \
  --build-arg UID=$(id -u) --build-arg GID=$(id -g) \
  --build-arg R_BUILD_SYSDEPS=${R_BUILD_SYSDEPS} \
  --target pkgcheck -t rchk-pkgcheck:${DEBIAN_TAG}-${FLAVOR_TAG} .

