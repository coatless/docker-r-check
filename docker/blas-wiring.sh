#!/bin/sh
# blas-wiring.sh -- point Debian's BLAS/LAPACK alternatives at the flavour's
# library, and prove afterwards that they actually point there.
#
#   blas-wiring.sh apply  <flavour>
#   blas-wiring.sh verify <flavour>    # exits 1 on mismatch
#   blas-wiring.sh show
#
# WHY THIS IS NOT ONE update-alternatives CALL
#
# Measured on debian:trixie-slim amd64, 2026-08-16:
#
#   * libopenblas0-serial registers THREE groups, all at priority 90:
#       libblas.so.3-<ma>  liblapack.so.3-<ma>  libopenblas.so.0-<ma>
#   * libopenblas0-pthread registers the same three at priority 100, so merely
#     installing it flips all three -- and libsuperlu-dev, which is in the
#     rcheckserver closure, Depends on libopenblas-dev, so the pthread build is
#     present in every image whether or not anyone asked for it.
#   * `Rconf -bo` emits --with-blas=-lopenblas, which binds SONAME
#     libopenblas.so.0 -- NOT libblas.so.3.  Setting only libblas.so.3 leaves
#     libopenblas.so.0 on pthread, and the arm runs threaded OpenBLAS while
#     every label says serial.  Verified: after `--set libblas.so.3-<ma>
#     .../openblas-serial/libblas.so.3`, libopenblas.so.0 still resolved to
#     .../openblas-pthread/libopenblasp-r0.3.29.so
#
# So every group the arm could bind is set explicitly, and `verify` compares
# RESOLVED REALPATHS -- comparing the alternatives symlink is useless, it is
# identical for serial and pthread.
#
# ATLAS additionally needs BOTH libblas and liblapack pointed at atlas/:
# atlas/liblapack.so.3.10.3 has NEEDED libblas.so.3 and no RUNPATH (measured),
# so a lapack-only switch silently pairs ATLAS's LAPACK with another BLAS.

set -eu

MA="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo x86_64-linux-gnu)"
L="/usr/lib/$MA"

# flavour_spec <flavour> -> lines of "<alternatives-group>|<target>"
# An empty target means "leave this group alone".
flavour_spec() {
    case "$1" in
    reference)
        printf '%s\n' \
            "libblas.so.3-$MA|$L/blas/libblas.so.3" \
            "liblapack.so.3-$MA|$L/lapack/liblapack.so.3"
        ;;
    openblas)
        # Runtime groups (what a built R loads) AND link-time groups (what
        # configure's -lopenblas test resolves).  Both matter and they are
        # separate: libopenblas-pthread-dev is in the base via
        # libsuperlu-dev -> libopenblas-dev, and outranks serial at link time
        # exactly as the runtime package does at load time.
        printf '%s\n' \
            "libopenblas.so.0-$MA|$L/openblas-serial/libopenblas.so.0" \
            "libblas.so.3-$MA|$L/openblas-serial/libblas.so.3" \
            "liblapack.so.3-$MA|$L/openblas-serial/liblapack.so.3" \
            "libopenblas.so-$MA|$L/openblas-serial/libopenblas.so" \
            "libblas.so-$MA|$L/openblas-serial/libblas.so" \
            "liblapack.so-$MA|$L/openblas-serial/liblapack.so"
        ;;
    atlas)
        printf '%s\n' \
            "libblas.so.3-$MA|$L/atlas/libblas.so.3" \
            "liblapack.so.3-$MA|$L/atlas/liblapack.so.3" \
            "libblas.so-$MA|$L/atlas/libblas.so" \
            "liblapack.so-$MA|$L/atlas/liblapack.so"
        ;;
    mkl|clang23)
        # MKL is linked by absolute -L at configure time and never goes through
        # alternatives; clang23 inherits the reference wiring.  Both still get
        # the reference groups pinned to manual so nothing drifts under them.
        printf '%s\n' \
            "libblas.so.3-$MA|$L/blas/libblas.so.3" \
            "liblapack.so.3-$MA|$L/lapack/liblapack.so.3"
        ;;
    *)
        echo "blas-wiring.sh: unknown flavour '$1'" >&2
        exit 2
        ;;
    esac
}

# What R must end up actually using, as a resolved realpath substring.
# Checked by `verify` against what R reports, in entry-build-r.sh.
expected_fragment() {
    case "$1" in
    # -bi is --with-blas=no --with-lapack=no, so R uses its OWN reference BLAS
    # at $R_HOME/lib/libRblas.so and its own LAPACK -- NOT Debian's
    # /usr/lib/<ma>/blas/libblas.so.3.  The alternatives this flavour pins are
    # hygiene for anything else in the image that probes them; R never looks.
    reference) echo "libRblas.so" ;;
    openblas)  echo "/openblas-serial/" ;;
    atlas)     echo "/atlas/" ;;
    mkl)       echo "/opt/intel/oneapi/mkl/" ;;
    clang23)   echo "" ;;   # internal reference BLAS; nothing external to match
    *)         echo "" ;;
    esac
}

resolve() { readlink -f "$1" 2>/dev/null || echo "<missing>"; }

# NOTE: both loops are fed by a here-document, NOT by a pipe.  `cmd | while`
# runs the loop body in a subshell, so an `exit 1` there aborts only the
# subshell and the caller sees success -- which is the same class of bug as
# build-R's, and not one to reintroduce in the script that exists to catch it.

do_apply() {
    fl="$1"
    while IFS='|' read -r group target; do
        [ -n "$target" ] || continue
        if [ ! -e "$target" ]; then
            echo "blas-wiring.sh: $fl wants $target, which does not exist." >&2
            echo "  The flavour's packages are missing, or the path moved." >&2
            return 1
        fi
        if ! update-alternatives --query "$group" >/dev/null 2>&1; then
            echo "blas-wiring.sh: alternatives group $group is not registered." >&2
            echo "  Nothing provides it; the flavour's packages are missing." >&2
            return 1
        fi
        update-alternatives --set "$group" "$target" >/dev/null
        printf '  set %-34s -> %s\n' "$group" "$target"
    done <<EOF
$(flavour_spec "$fl")
EOF
}

do_verify() {
    fl="$1"
    bad=0
    echo "blas-wiring.sh: verifying flavour '$fl'"
    while IFS='|' read -r group target; do
        [ -n "$target" ] || continue
        # The master link is the group name with the -<ma> suffix stripped.
        master="$L/$(echo "$group" | sed "s/-$MA\$//")"
        got="$(resolve "$master")"
        want="$(resolve "$target")"
        if [ "$got" = "$want" ]; then
            printf '  ok   %-22s -> %s\n' "$(basename "$master")" "$got"
        else
            printf '  FAIL %-22s -> %s\n       expected %s\n' \
                "$(basename "$master")" "$got" "$want" >&2
            bad=1
        fi
    done <<EOF
$(flavour_spec "$fl")
EOF
    [ "$bad" -eq 0 ] || return 1
    return 0
}

do_show() {
    echo "multiarch: $MA"
    for g in "libblas.so.3-$MA" "liblapack.so.3-$MA" "libopenblas.so.0-$MA"; do
        v="$(update-alternatives --query "$g" 2>/dev/null | awk '/^Value:/{print $2}')"
        printf '  %-34s %s\n' "$g" "${v:-<not registered>}"
        [ -n "${v:-}" ] && printf '  %-34s   -> %s\n' "" "$(resolve "$v")"
    done
}

cmd="${1:-show}"
case "$cmd" in
apply)  [ $# -ge 2 ] || { echo "usage: $0 apply <flavour>" >&2; exit 2; }
        do_apply "$2"; do_verify "$2" ;;
verify) [ $# -ge 2 ] || { echo "usage: $0 verify <flavour>" >&2; exit 2; }
        do_verify "$2" ;;
show)   do_show ;;
expect) [ $# -ge 2 ] || { echo "usage: $0 expect <flavour>" >&2; exit 2; }
        expected_fragment "$2" ;;
*)      echo "usage: $0 {apply|verify|show|expect} [flavour]" >&2; exit 2 ;;
esac
