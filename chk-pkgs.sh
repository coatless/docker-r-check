#!/bin/bash

DEBIAN_TAG="$1"
FLAVOR_TAG="$2"
shift
shift

if [ "x$1" = x-h -o -z "${FLAVOR_TAG}" ]; then
    echo ''
    echo " Usage: $0 <debian-tag> <flavor-tag>"
    echo ''
    echo ' Packages are expected to be in build/pkg'
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

if [ -e pkg ]; then
    pkgmount=" -v $(pwd)/pkg:/pkg"
else
    if [ ! -e build/pkg ]; then
	echo "Create either build/pkg or pkg directory and put the packages to check there"
	exit 1
    fi
fi

MAKEFLAGS=${MAKEFLAGS-"-j2"}

docker run --platform linux/amd64 --rm -v $(pwd)/build:/build $pkgmount -e "MAKEFLAGS=$MAKEFLAGS" "rchk-pkgcheck:${DEBIAN_TAG}-${FLAVOR_TAG}" "$@"
