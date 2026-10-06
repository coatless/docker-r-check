#!/bin/bash
# Check source packages in one arm through the image's entrypoint, which runs
# check_CRAN_incoming -n from the QA tree. It installs the package's Depends,
# Imports, LinkingTo and Suggests, then runs R CMD check under xvfb-run with
# the QA tree's check.Renviron.
#
#   demo/03-check.sh <flavour> <package-name | path/to/pkg_x.y.tar.gz>...
#
#   demo/03-check.sh reference digest
#   RCC_MODE=incoming demo/03-check.sh openblas ~/src/mypkg_1.0.tar.gz
#
# RCC_MODE sets the kind of check.
#   regular   (default) plain R CMD check, as in CRAN's additional checks.
#             Passes -r to check_CRAN_incoming.
#   incoming  R CMD check --as-cran with the incoming checks a new submission
#             gets. A version already on CRAN gets "Insufficient package
#             version" here, so use it for new or version-bumped tarballs. It
#             needs a live CRAN mirror, because the incoming checks read
#             PACKAGES.in, which dated snapshots do not serve.
#
# Other settings.
#   CRAN_MIRROR          where dependencies come from. A dated snapshot such
#                        as https://packagemanager.posit.co/cran/2026-09-23
#                        makes two runs install the same versions.
#   OPENBLAS_CORETYPE    pins the OpenBLAS kernel.
#   BLIS_ARCH_TYPE       pins the BLIS kernel set, for example haswell.
#   MKL_*                MKL settings such as MKL_CBWR=COMPATIBLE are passed
#                        on. MKL also picks its code from the CPU.
#   RCC_RUNNER=dir       checks through tools::check_packages_in_dir(), with
#                        check-CRAN-incoming from the QA tree. It checks
#                        RCC_NCPUS packages at a time, by default one per
#                        core.
#   RCC_NETWORK=none     runs the check with the network cut off. Use it with
#                        RCC_LIBRARY_CACHE=1 after a run that installed the
#                        dependencies.
#   _R_CHECK_*           any R CMD check setting in the environment is passed
#                        on, for example _R_CHECK_ELAPSED_TIMEOUT_=3600.
#   RCC_LIBRARY_CACHE=1  keeps installed dependencies in a named volume per
#                        image and mirror, so the next run skips compiling
#                        them. List the volumes with
#                        docker volume ls -q --filter name=rcc-lib-
#
# Results go to results/<flavour>/<package>/, which holds the .Rcheck
# directory, the console output, check_CRAN_incoming's summary, and
# manifest.dcf with the settings of the run.
#
# Exit status is 0 when every package is clean (Status: OK), 1 when any is
# not (a NOTE counts, as it does at CRAN) and 2 when a check did not finish.
# check_CRAN_incoming always exits 0, so the result is read from each
# 00check.log.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ $# -ge 2 ] || die "usage: $0 <flavour> <package|tarball>..."
fl="$1"; shift
need_image "$fl"

mode="${RCC_MODE:-regular}"
case "$mode" in
regular)  entry_args=(-r) ;;
incoming) entry_args=() ;;
*)        die "RCC_MODE must be 'regular' or 'incoming', not '$mode'" ;;
esac

# The incoming checks read src/contrib/PACKAGES.in. CRAN's mirrors serve it
# and dated snapshots do not, in which case R CMD check stops part-way.
if [ "$mode" = incoming ] && [ -n "${CRAN_MIRROR:-}" ] &&
   ! curl -fsI -o /dev/null "$CRAN_MIRROR/src/contrib/PACKAGES.in"; then
    die "incoming mode needs a CRAN mirror that serves src/contrib/PACKAGES.in; $CRAN_MIRROR does not (unset CRAN_MIRROR, or use https://cloud.r-project.org)"
fi

# Resolve every argument to a tarball on the host first, so a typo fails
# before a container starts.
tarballs=()
for arg in "$@"; do
    if [ -f "$arg" ]; then
        # check_CRAN_incoming splits its file list on whitespace, and globs.
        case "$(basename "$arg")" in
        *[!A-Za-z0-9._-]*) die "$arg: expected <pkg>_<version>.tar.gz (no spaces or brackets)" ;;
        *_*.tar.gz) ;;
        *) die "$arg: expected <pkg>_<version>.tar.gz" ;;
        esac
        tarballs+=("$arg")
    else
        tarballs+=("$(fetch_cran "$arg" "$RESULTS/src")")
    fi
done

# The entrypoint copies /pkg/*.tar.gz, so give it a directory holding exactly
# the tarballs asked for.
stage="$(mktemp -d "${TMPDIR:-/tmp}/rcc-pkg.XXXXXX")"
name="rcc-check-$fl-$$"
cleanup() { "$ENGINE" rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$stage"; }
trap cleanup EXIT
cp "${tarballs[@]}" "$stage/"
chmod 0755 "$stage"; chmod 0644 "$stage"/*.tar.gz

env_args=()
runner="${RCC_RUNNER:-}"
case "$runner" in
"")  runner_desc="check_CRAN_incoming, one package at a time" ;;
dir) runner_desc="tools::check_packages_in_dir(), ${RCC_NCPUS:-one per core} at a time"
     env_args+=(-e RCC_RUNNER=dir)
     [ -n "${RCC_NCPUS:-}" ] && env_args+=(-e "RCC_NCPUS=$RCC_NCPUS") ;;
*)   die "RCC_RUNNER must be 'dir' or unset, not '$runner'" ;;
esac

[ -n "${CRAN_MIRROR:-}" ] && env_args+=(-e "CRAN_MIRROR=$CRAN_MIRROR")
[ -n "${OPENBLAS_CORETYPE:-}" ] && env_args+=(-e "OPENBLAS_CORETYPE=$OPENBLAS_CORETYPE")
[ -n "${BLIS_ARCH_TYPE:-}" ] && env_args+=(-e "BLIS_ARCH_TYPE=$BLIS_ARCH_TYPE")
[ -n "${MAKEFLAGS:-}" ] && env_args+=(-e "MAKEFLAGS=$MAKEFLAGS")
# R CMD check settings such as _R_CHECK_ELAPSED_TIMEOUT_ pass straight through,
# and so do MKL's own settings.
for v in $(env | sed -n 's/^\(_R_CHECK_[A-Z0-9_]*\)=.*/\1/p; s/^\(MKL_[A-Z0-9_]*\)=.*/\1/p'); do
    env_args+=(-e "$v")
done

net_args=()
[ -n "${RCC_NETWORK:-}" ] && net_args=(--network "$RCC_NETWORK")

# Rootless Podman on an SELinux host cannot read an unlabeled bind mount.
pkg_mount="$stage:/pkg:ro"
case "$(basename "$ENGINE")" in podman*) pkg_mount="$pkg_mount,z" ;; esac

# A hash of the image's layers. With Docker's containerd store, a rebuild
# that changes nothing still gets a new image ID.
content="$("$ENGINE" image inspect --format '{{json .RootFS.Layers}}' "$(image "$fl")" |
    { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16)"

# Dependencies are compiled against one image's R and BLAS, so a cached
# library is keyed by the image's content and the mirror, and never shared.
lib_args=()
library="fresh (discarded with the container)"
if [ "${RCC_LIBRARY_CACHE:-0}" != 0 ]; then
    key="$(printf '%s %s' "${CRAN_MIRROR:-live}" "$content" |
        { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-12)"
    vol="rcc-lib-$fl-$key"
    # The cleanup below would delete a running check's files.
    [ -z "$("$ENGINE" ps -q --filter "volume=$vol")" ] ||
        die "$vol is in use by another check of $fl; wait for it to finish"
    if "$ENGINE" volume inspect "$vol" >/dev/null 2>&1; then
        library="cached in volume $vol (reused)"
    else
        "$ENGINE" volume create "$vol" >/dev/null
        library="cached in volume $vol (new)"
    fi
    # The volume holds the whole check directory. A new volume is owned by
    # root, so fix that first. Then clear everything from the previous run
    # except Library/. A stale PACKAGES index would hide a new package's
    # dependencies.
    "$ENGINE" run --rm --platform "$PLATFORM" --user 0 --entrypoint sh \
        -v "$vol:/build/CRAN" "$(image "$fl")" -c \
        'chown rbuild:rbuild /build/CRAN && find /build/CRAN -mindepth 1 -maxdepth 1 ! -name Library -exec rm -rf {} +'
    lib_args=(-v "$vol:/build/CRAN")
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="$RESULTS/$fl"
mkdir -p "$out"
console="$out/console-$stamp.log"
echo "== $mode check in $(image "$fl"): $(cd "$stage" && ls -- *.tar.gz | tr '\n' ' ')"
echo "   console: $console"

# No --rm, because the results are copied out of the stopped container
# afterwards. That works the same under Docker and Podman. The container
# needs the network to install dependencies. It runs as the image's
# unprivileged user, and no-new-privileges also disables the image's sudo.
start=$SECONDS
rc=0
"$ENGINE" run --platform "$PLATFORM" --name "$name" \
    --security-opt no-new-privileges --cap-drop ALL --pids-limit 4096 \
    ${env_args[@]+"${env_args[@]}"} ${lib_args[@]+"${lib_args[@]}"} \
    ${net_args[@]+"${net_args[@]}"} \
    -v "$pkg_mount" "$(image "$fl")" ${entry_args[@]+"${entry_args[@]}"} >"$console" 2>&1 || rc=$?
t=$((SECONDS - start))
echo "   container exited $rc after $((t / 60))m$((t % 60))s"

# The image that ran. The tag may have moved during a long check.
image_id="$("$ENGINE" inspect --format '{{.Image}}' "$name" 2>/dev/null)" ||
    image_id="$("$ENGINE" image inspect --format '{{.Id}}' "$(image "$fl")")"

# OpenBLAS, BLIS and MKL pick their code at startup from the CPU, so record
# what they picked for this run.
probe="$("$ENGINE" run --rm --platform "$PLATFORM" -e OPENBLAS_VERBOSE=2 -e BLIS_ARCH_DEBUG=1 \
    -e MKL_VERBOSE=1 \
    ${env_args[@]+"${env_args[@]}"} --entrypoint sh "$image_id" -c '
    echo "cpu: $(sed -n "s/^model name[[:space:]]*: //p" /proc/cpuinfo | head -n 1)"
    /build/bin/Rscript --vanilla -e "invisible(crossprod(matrix(1, 2, 2)))" 2>&1 |
        sed -n "s/^Core: /openblas_core: /p; s/^libblis: selecting sub-configuration /blis_arch: /p; s/^MKL_VERBOSE .* architecture \\(.*\\), Lnx.*/mkl_code: \\1/p"' 2>/dev/null || true)"

worst=0
for tb in "${tarballs[@]}"; do
    base="$(basename "$tb")"; pkg="${base%%_*}"
    dest="$out/$pkg"
    rm -rf "$dest"; mkdir -p "$dest"
    "$ENGINE" cp "$name:/build/CRAN/$pkg.Rcheck" "$dest/" >/dev/null 2>&1 || true
    cp "$console" "$dest/console.log"
    status="$(check_status "$dest/$pkg.Rcheck/00check.log")"
    if [ -z "$status" ]; then verdict=2; elif [ "$status" = OK ]; then verdict=0; else verdict=1; fi
    {
        echo "Package: $pkg"
        echo "Tarball: $base"
        echo "Tarball-SHA256: $(sha256 "$tb")"
        echo "Flavour: $fl"
        echo "Image: $(image "$fl")"
        echo "Image-ID: $image_id"
        echo "Image-Content: $content"
        echo "Platform: $PLATFORM"
        echo "Host: $(uname -s) $(uname -m)"
        printf '%s\n' "$probe" | sed -n 's/^cpu: /CPU: /p; s/^openblas_core: /OpenBLAS-Core: /p; s/^blis_arch: /BLIS-Arch: /p; s/^mkl_code: /MKL-Code: /p'
        echo "OpenBLAS-Coretype-Pinned: ${OPENBLAS_CORETYPE:-no}"
        echo "BLIS-Arch-Type-Pinned: ${BLIS_ARCH_TYPE:-no}"
        echo "Mode: $mode"
        echo "Runner: $runner_desc"
        echo "Engine: $ENGINE"
        echo "Network: ${RCC_NETWORK:-on}"
        echo "CRAN-Mirror: ${CRAN_MIRROR:-https://cloud.r-project.org (live, unpinned)}"
        echo "Library: $library"
        echo "Started: $stamp"
        echo "Elapsed-Seconds: $t"
        echo "Status: ${status:-did not complete}"
        echo "Verdict: $verdict"
        { "$ENGINE" run --rm --platform "$PLATFORM" --entrypoint cat "$image_id" \
            /etc/rcheck/manifest.txt 2>/dev/null || true; } |
            awk -F': ' 'NF >= 2 && $1 ~ /^[a-z_]+$/ && !seen[$1]++ {k = $1; sub(/^[^:]*: /, ""); printf "Image-%s: %s\n", k, $0}'
    } >"$dest/manifest.dcf"
    printf '   %-20s %s\n' "$pkg" "${status:+Status: }${status:-did not complete -- see $dest/console.log}"
    [ "$verdict" -le "$worst" ] || worst=$verdict
done

# check_CRAN_incoming's run-level summary (depends, results, timings) goes to
# ~/tmp, which in the standalone image is /build/log alongside R's build logs.
mkdir -p "$out/log"
"$ENGINE" cp "$name:/build/log/." "$out/log/.tmp" >/dev/null 2>&1 || true
find "$out/log/.tmp" -maxdepth 1 -name 'CRAN_*.log' -exec mv {} "$out/log/" \; 2>/dev/null || true
rm -rf "$out/log/.tmp"
# check_packages_in_dir() keeps each dependency's install log and each check's
# output in Outputs/.
[ "$runner" != dir ] || "$ENGINE" cp "$name:/build/CRAN/Outputs" "$out/log/" >/dev/null 2>&1 || true

echo "   results: $out/<package>/  (manifest.dcf, console.log, <package>.Rcheck/)"
exit "$worst"
