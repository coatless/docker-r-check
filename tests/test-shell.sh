#!/bin/bash
# Static checks over every shell script and over the Dockerfile.
#
# Cheap, but it is the only automated check that covers the container-side
# scripts: entry-build-r.sh and entry-pkgcheck.sh cannot be executed outside a
# built image, so a syntax error in them would otherwise only surface after a
# long image build on someone else's machine.

set -u
here=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$here/.." && pwd)
. "$here/lib.sh"

scripts=$(cd "$REPO" && ls \
    bin/rcheck \
    build-images.sh build-R.sh chk-pkgs.sh \
    docker/apt-setup.sh docker/entry-build-r.sh docker/entry-pkgcheck.sh \
    docker/lib/flavor.sh docker/lib/build-r-configure.sh \
    tools/summarise-check.sh tools/cran-compare.sh tools/pin-images.sh \
    tests/lib.sh tests/*.sh 2>/dev/null)

for s in $scripts; do
    t_begin "bash -n $s"
    if err=$(bash -n "$REPO/$s" 2>&1); then t_pass; else t_fail "$err"; fi
done

t_begin "awk script parses"
if err=$(awk -f "$REPO/tools/summarise-check.awk" </dev/null 2>&1); then t_pass; else t_fail "$err"; fi

t_begin "executables are executable"
notexec=""
for s in bin/rcheck tools/summarise-check.sh tools/cran-compare.sh tools/pin-images.sh \
         build-images.sh build-R.sh chk-pkgs.sh; do
    [ -x "$REPO/$s" ] || notexec="$notexec $s"
done
assert_eq "" "$notexec"

t_begin "no script hardcodes a path under /home"
## A path baked in from a developer's machine is the classic way a container
## helper stops working for everyone else.
hits=$(cd "$REPO" && grep -rn '/home/[a-z]' --include='*.sh' --include='Dockerfile' \
        bin tools docker build-images.sh build-R.sh chk-pkgs.sh 2>/dev/null \
        | grep -v '/home/rbuild' | grep -v '^\s*#' || true)
assert_eq "" "$hits"

t_begin "shellcheck (if installed)"
if command -v shellcheck >/dev/null 2>&1; then
    # shellcheck disable=SC2086  # deliberate word splitting over the file list
    if err=$(cd "$REPO" && shellcheck -S warning -e SC1091 $scripts 2>&1); then
        t_pass
    else
        t_fail "$err"
    fi
else
    printf 'skip  shellcheck not installed\n'
    TESTS_RUN=$((TESTS_RUN - 1))
fi

## --- Dockerfile -----------------------------------------------------------

DF=$REPO/docker/Dockerfile

t_begin "Dockerfile takes a digest suffix for the base image"
assert_contains "$(cat "$DF")" 'FROM ${BASE_IMAGE}:${BASE_TAG}${BASE_DIGEST_SUFFIX}'

t_begin "Dockerfile still exposes the original three targets"
out=$(cat "$DF")
missing=""
for target in base build-r pkgcheck; do
    case $out in *"AS $target"*) ;; *) missing="$missing $target" ;; esac
done
assert_eq "" "$missing"

t_begin "apt is repointed before the first apt-get update"
## Otherwise DEBIAN_MIRROR and DEBIAN_SNAPSHOT would not govern the packages
## installed by the very first layer.
setup_line=$(grep -n 'apt-setup.sh' "$DF" | tail -n 1 | cut -d: -f1)
update_line=$(grep -n 'apt-get update' "$DF" | head -n 1 | cut -d: -f1)
if [ "$setup_line" -lt "$update_line" ]; then t_pass
else t_fail "apt-setup.sh (line $setup_line) runs after the first apt-get update (line $update_line)"; fi

t_begin "the image carries the flavor definitions"
assert_contains "$out" "COPY flavors/ /rcheck/flavors/"

t_begin "the image carries the result summariser"
assert_contains "$out" "tools/summarise-check.sh"

t_begin "COPY paths are relative to the repository root"
## The build context moved from docker/ to the repository root when the image
## started carrying flavors/ and tools/; a stale docker/-relative COPY would
## fail only at build time.
bad=$(grep -E '^COPY ' "$DF" | grep -vE 'COPY (docker|flavors|tools)/' || true)
assert_eq "" "$bad"

t_summary
