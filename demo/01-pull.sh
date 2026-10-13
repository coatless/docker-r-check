#!/bin/bash
# Pull published images in place of building them, and give each the name
# the other scripts use, rcc-standalone:<flavour>.
#
#   demo/01-pull.sh reference openblas
#
# RCC_REGISTRY says where the images are. The newest image of an arm is
# pulled. RCC_IMAGE_DATE picks the build of one day, for example 2026-10-14,
# and RCC_R_REV the build of one R-devel revision, for example 90668.
# RCC_SUITE=stable pulls the images built on Debian stable, where published.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ $# -ge 1 ] || die "usage: $0 <flavour>...   (flavours: $(flavours | tr '\n' ' '))"
for fl in "$@"; do have_flavour "$fl" || die "no such flavour '$fl'"; need_suite "$fl"; done

registry="${RCC_REGISTRY:-ghcr.io/coatless/docker-r-check}"
for fl in "$@"; do
    from="$registry:$fl"
    [ "$SUITE" = testing ] || from="$from-$SUITE"
    if [ -n "${RCC_IMAGE_DATE:-}" ]; then
        from="$from-$RCC_IMAGE_DATE"
    elif [ -n "${RCC_R_REV:-}" ]; then
        from="$from-r$RCC_R_REV"
    fi
    echo "== $(image "$fl")  [from $from]"
    "$ENGINE" pull --platform "$(platform_of "$fl")" "$from"
    "$ENGINE" tag "$from" "$(image "$fl")"
done
