#!/bin/bash
# Build the self-contained ('standalone') check image for one or more arms.
#
#   demo/01-build.sh reference openblas atlas
#
# Each arm is tagged rcc-standalone:<flavour>.  The base layers (Debian,
# rcheckserver, R and QA sources) are shared, so the first arm is slow and
# the rest mostly cost an R build each.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ $# -ge 1 ] || die "usage: $0 <flavour>...   (flavours: $(flavours | tr '\n' ' '))"
for fl in "$@"; do have_flavour "$fl" || die "no such flavour '$fl'"; done

progress=()
[ "$ENGINE" = docker ] && progress=(--progress=plain)

# BUILD_DATE is a day and not a timestamp. A new value reruns the R build
# step, so a day keeps same-day rebuilds cached.
build_date="${RCC_BUILD_DATE:-$(date -u +%Y-%m-%d)}"

mkdir -p "$RESULTS/logs"
for fl in "$@"; do
    log="$RESULTS/logs/build-$fl.log"
    PLATFORM="$(platform_of "$fl")"
    # The base refuses to build for anything but amd64 unless told to.
    allow=""; [ "$PLATFORM" = linux/amd64 ] || allow=1
    echo "== $(image "$fl")  [$PLATFORM, R r$R_SVN_REV, QA r$QA_SVN_REV]"
    echo "   log: $log"
    start=$SECONDS
    if ! "$ENGINE" build --platform "$PLATFORM" ${progress[@]+"${progress[@]}"} \
            --build-arg DEBIAN_TAG="$(suite_of "$fl")" \
            --build-arg ALLOW_NON_AMD64="$allow" \
            --build-arg RCC_FLAVOUR="$fl" \
            --build-arg R_SVN_REV="$R_SVN_REV" \
            --build-arg QA_SVN_REV="$QA_SVN_REV" \
            --build-arg MAKEFLAGS="-j${RCC_JOBS:-4}" \
            --build-arg BUILD_DATE="$build_date" \
            --target standalone -t "$(image "$fl")" \
            "$ROOT/docker" >"$log" 2>&1; then
        tail -n 40 "$log" >&2
        die "$fl failed after $((SECONDS - start))s -- full log in $log"
    fi
    t=$((SECONDS - start))
    echo "   built in $((t / 60))m$((t % 60))s"
done
