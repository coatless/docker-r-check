#!/bin/bash

DEBIAN_TAG="$1"
FLAVOR_TAG="$2"
shift
shift

if [ "x$1" = x-h -o -z "${FLAVOR_TAG}" ]; then
    echo ''
    echo " Usage: $0 <debian-tag> <flavor-tag> [<build-R args> ...]"
    echo ''
    if [ "x$1" = x-h ]; then
	exit 0
    fi
    echo "ERROR: missing <flavor-tag>"
    echo ''
    exit 1
fi

if [ ! -e build ]; then
    mkdir -p build
fi

docker run --platform linux/amd64 --rm -v $(pwd)/build:/build "rchk-build-r:${DEBIAN_TAG}-${FLAVOR_TAG}" "$@"
