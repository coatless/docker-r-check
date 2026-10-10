#!/bin/bash
# Pull published images in place of building them, and give each the name
# the other scripts use, rcc-standalone:<flavour>.
#
#   demo/01-pull.sh reference openblas
#
# RCC_REGISTRY says where the images are. RCC_R_REV picks the build of one
# R-devel revision, for example 90653, in place of the newest one published.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ $# -ge 1 ] || die "usage: $0 <flavour>...   (flavours: $(flavours | tr '\n' ' '))"
for fl in "$@"; do have_flavour "$fl" || die "no such flavour '$fl'"; done

registry="${RCC_REGISTRY:-ghcr.io/coatless/docker-r-check}"
for fl in "$@"; do
    from="$registry:$fl${RCC_R_REV:+-r$RCC_R_REV}"
    echo "== $(image "$fl")  [from $from]"
    "$ENGINE" pull --platform "$(platform_of "$fl")" "$from"
    "$ENGINE" tag "$from" "$(image "$fl")"
done
