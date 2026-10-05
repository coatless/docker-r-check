#!/bin/sh
# Select an arm's BLAS and LAPACK through Debian's alternatives, then check
# that the selection took.
#
#   blas-wiring.sh apply  <flavour>
#   blas-wiring.sh verify <flavour>    # exits 1 on mismatch
#   blas-wiring.sh show
#
# Every alternatives group an arm can use is set explicitly. For OpenBLAS
# that is three runtime groups and three link-time groups. The pthread build
# is always installed, because libsuperlu-dev depends on libopenblas-dev, and
# it has the higher priority. Rconf -bo links -lopenblas, so setting only
# libblas.so.3 would leave R on pthread OpenBLAS.
#
# verify compares resolved paths. The alternatives symlink itself has the
# same name for the serial and pthread builds.
#
# ATLAS needs both libblas and liblapack selected, because its liblapack
# loads libblas.so.3 through the same alternatives.

set -eu

MA="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo x86_64-linux-gnu)"
L="/usr/lib/$MA"

# Print one "<alternatives-group>|<target>" line per group the arm sets.
flavour_spec() {
    case "$1" in
    reference|forky|nold)
        printf '%s\n' \
            "libblas.so.3-$MA|$L/blas/libblas.so.3" \
            "liblapack.so.3-$MA|$L/lapack/liblapack.so.3"
        ;;
    openblas)
        # Runtime groups, which R loads, and link-time groups, which
        # configure's -lopenblas test uses. The pthread packages outrank the
        # serial ones in both.
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
    blis)
        # BLIS supplies the BLAS. Debian's reference LAPACK runs on top of it,
        # as the system LAPACK does in CRAN's BLIS checks.
        printf '%s\n' \
            "libblas.so.3-$MA|$L/blis-serial/libblas.so.3" \
            "liblapack.so.3-$MA|$L/lapack/liblapack.so.3" \
            "libblas.so-$MA|$L/blis-serial/libblas.so" \
            "liblapack.so-$MA|$L/lapack/liblapack.so"
        ;;
    blisfedora)
        # A BLIS in /opt/blis, registered by flavours/blis-register.sh.
        printf '%s\n' \
            "libblis.so.4-$MA|/opt/blis/lib/libblis.so.4" \
            "libblas.so.3-$MA|/opt/blis/lib/libblis.so.4" \
            "liblapack.so.3-$MA|$L/lapack/liblapack.so.3" \
            "libblas.so-$MA|/opt/blis/lib/libblis.so" \
            "liblapack.so-$MA|$L/lapack/liblapack.so"
        ;;
    mkl|clang23)
        # MKL is linked by path and does not use alternatives. clang23 uses
        # R's own BLAS. Both keep the reference selection.
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

# A fragment of the path R must report for its BLAS. Used by
# assert-r-blas.sh.
expected_fragment() {
    case "$1" in
    # -bi builds R with its own BLAS at $R_HOME/lib/libRblas.so, so that is
    # what R reports, whatever the Debian alternatives say.
    reference|forky|nold) echo "libRblas.so" ;;
    openblas)  echo "/openblas-serial/" ;;
    atlas)     echo "/atlas/" ;;
    blis)      echo "/blis-serial/" ;;
    blisfedora) echo "/opt/blis/" ;;
    mkl)       echo "/opt/intel/oneapi/mkl/" ;;
    clang23)   echo "libRblas.so" ;;
    *)         echo "" ;;
    esac
}

resolve() { readlink -f "$1" 2>/dev/null || echo "<missing>"; }

# Both loops read from a here-document. A pipe would run the loop in a
# subshell, and a failure inside it would not stop the script.

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
