#!/bin/bash
# The rcheck CLI, exercised through --dry-run.
#
# --dry-run prints the exact container commands instead of running them, which
# is what lets this suite verify the wiring -- pinned digests, bind mounts,
# per-flavor build directories, flavor propagation -- on a machine with no
# container runtime at all.

set -u
here=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$here/.." && pwd)
. "$here/lib.sh"

RCHECK=$REPO/bin/rcheck
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

dry() { "$RCHECK" --dry-run --build-dir "$TMP/build" "$@" 2>&1; }

## --- discovery ------------------------------------------------------------

t_begin "flavors lists every definition with its tier and status"
out=$("$RCHECK" flavors)
assert_contains "$out" "nold"

t_begin "  ... including the CRAN issue kind it reproduces"
assert_contains "$out" "noLD"

t_begin "describe shows the resolved base digest"
assert_contains "$("$RCHECK" describe nold)" "sha256:"

t_begin "describe --json is machine-readable"
out=$("$RCHECK" describe gcc-asan --json)
if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["FLAVOR_ID"]=="gcc-asan"' 2>/dev/null; then
        t_pass
    else
        t_fail "describe --json is not valid JSON with the expected FLAVOR_ID"
    fi
else
    assert_contains "$out" '"FLAVOR_ID": "gcc-asan"'
fi

t_begin "an unknown flavor is a clear error, not a stack trace"
out=$("$RCHECK" describe no-such-flavor 2>&1 || true)
assert_contains "$out" "unknown flavor"

t_begin "a flavor name cannot escape the flavors directory"
out=$("$RCHECK" describe ../../etc/passwd 2>&1 || true)
assert_contains "$out" "unknown flavor"

## --- build ----------------------------------------------------------------

t_begin "build pins the base image by digest"
out=$(dry build nold)
assert_contains "$out" "BASE_DIGEST_SUFFIX=@sha256:"

t_begin "build passes the flavor's sysdeps"
assert_contains "$(dry build clang-asan)" "R_BUILD_SYSDEPS=clang libc++-dev libc++abi-dev libomp-dev"

t_begin "build passes the flavor's apt components"
assert_contains "$(dry build nold)" "APT_COMPONENTS=main"

t_begin "build builds both the build-r and pkgcheck targets"
out=$(dry build nold)
assert_contains "$out" "--target pkgcheck"

t_begin "build uses the repository root as context with -f"
assert_contains "$(dry build nold)" "-f $REPO/docker/Dockerfile"

t_begin "an unpinned base image produces a warning"
out=$("$RCHECK" --dry-run --build-dir "$TMP/build" --pins /dev/null build nold 2>&1)
assert_contains "$out" "not pinned"

## --- build-r --------------------------------------------------------------

t_begin "build-r gives each flavor its own build directory"
assert_contains "$(dry build-r nold)" "$TMP/build/nold:/build"

t_begin "  ... so two flavors cannot share one R build"
assert_contains "$(dry build-r gcc-asan)" "$TMP/build/gcc-asan:/build"

t_begin "build-r passes the flavor into the container"
assert_contains "$(dry build-r nold)" "RCHECK_FLAVOR=nold"

t_begin "build-r bind-mounts the working copy of the flavors"
assert_contains "$(dry build-r nold)" "$REPO/flavors:/rcheck/flavors.local:ro"

t_begin "--r-svn-rev is forwarded"
assert_contains "$(dry --r-svn-rev 90210 build-r nold)" "R_SVN_REV=90210"

t_begin "--jobs sets MAKEFLAGS"
assert_contains "$(dry --jobs 16 build-r nold)" "MAKEFLAGS=-j16"

## --- check ----------------------------------------------------------------

t_begin "check mounts the flavor's package directory"
assert_contains "$(dry check nold pkg_1.0.tar.gz)" "$TMP/build/nold/pkg:/pkg"

t_begin "check does not pass the tarball as a check argument"
## The tarball is an input to be staged, not an option for the check driver.
out=$(dry check nold pkg_1.0.tar.gz)
assert_not_contains "$out" "rchk-pkgcheck:nold pkg_1.0.tar.gz"

t_begin "--p3m is forwarded so the package graph is pinned"
assert_contains "$(dry --p3m 2026-08-01 check nold pkg_1.0.tar.gz)" "P3M_SNAPSHOT=2026-08-01"

t_begin "check with nothing to check is an error"
out=$(dry check nold 2>&1 || true)
assert_contains "$out" "no packages to check"

## --- pinning warnings -----------------------------------------------------

t_begin "an unpinned run warns that it is not reproducible"
assert_contains "$(dry build-r nold)" "not fully pinned"

t_begin "a fully pinned run does not"
out=$(dry --snapshot 20260801T000000Z --p3m 2026-08-01 --r-svn-rev 90210 build-r nold)
assert_not_contains "$out" "not fully pinned"

## --- status honesty -------------------------------------------------------

t_begin "an experimental flavor says so before running"
assert_contains "$(dry build-r gcc-asan)" "is experimental"

t_begin "a planned flavor refuses to run"
out=$(dry build-r mkl 2>&1 || true)
assert_contains "$out" "STATUS=planned"

t_begin "  ... and says what is blocking it"
assert_contains "$out" "not usable"

## --- runtimes -------------------------------------------------------------

t_begin "podman is a drop-in for docker"
assert_contains "$(dry --runtime podman build-r nold)" "+ podman run"

t_begin "apptainer needs an explicit image reference"
out=$(dry --runtime apptainer build-r nold 2>&1 || true)
assert_contains "$out" "needs --image"

t_begin "apptainer runs the entrypoint script explicitly"
out=$(dry --runtime apptainer --image docker://example/img:1 build-r nold 2>&1)
assert_contains "$out" "/entry-build-r.sh"

t_begin "apptainer redirects HOME away from the user's real home"
## The entrypoints create symlinks in \$HOME that only make sense inside the
## container; apptainer mounts the host home by default, so without this the
## container would litter (and break on) the user's own home directory.
assert_contains "$out" "--home $TMP/build/nold/home:/home/rbuild"

t_begin "apptainer cannot be asked to build images"
out=$(dry --runtime apptainer --image x build nold 2>&1 || true)
assert_contains "$out" "cannot build these images"

t_begin "an unknown runtime is rejected"
out=$("$RCHECK" --runtime containerd flavors 2>&1 || true)
assert_contains "$out" "unknown runtime"

## --- misc -----------------------------------------------------------------

t_begin "an unknown command is rejected with usage"
out=$("$RCHECK" frobnicate 2>&1 || true)
assert_contains "$out" "unknown command"

t_begin "compare refuses a flavor with no CRAN issue kind"
out=$("$RCHECK" compare debian-gcc 2>&1 || true)
assert_contains "$out" "nothing to compare"

t_summary
