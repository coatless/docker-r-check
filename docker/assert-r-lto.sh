#!/bin/sh
# Fail unless an arm that asks for link-time optimization got it.
#
#   assert-r-lto.sh <flavour> [R-binary]
#
# configure accepts --enable-lto even when part of the toolchain cannot do
# LTO, and the build then goes through without it. So besides reading the
# flags R recorded, this builds a shared object from two files that disagree
# about a function's type. Only an LTO link notices that. Arms that do not
# ask for LTO are left alone.

set -eu

FLAVOUR="${1:?usage: assert-r-lto.sh <flavour> [R-binary]}"
RBIN="${2:-/build/bin/R}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC1090 # the arm's settings
. "${RCC_FLAVOURS:-$HERE/flavours}/$FLAVOUR.env"
case " $RCC_RCONF_FLAGS " in
*" --enable-lto "*) ;;
*) exit 0 ;;
esac

[ -x "$RBIN" ] || { echo "assert-r-lto.sh: no R at $RBIN" >&2; exit 1; }

# With --enable-lto, etc/Makeconf carries the flag for every package.
makeconf="$("$RBIN" RHOME)/etc/Makeconf"
lto="$(sed -n 's/^LTO = *//p' "$makeconf")"
if [ -z "$lto" ]; then
    echo "** ERROR: $FLAVOUR asks for LTO, but $makeconf has no LTO flags." >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'double rcc_lto_probe(double x) { return x; }\n' > "$work/a.c"
printf 'int rcc_lto_probe(int x);\nint rcc_lto_user(int x) { return rcc_lto_probe(x); }\n' > "$work/b.c"
out="$(cd "$work" && "$RBIN" CMD SHLIB -o probe.so a.c b.c 2>&1)" || {
    echo "** ERROR: R CMD SHLIB failed while testing LTO in $FLAVOUR." >&2
    echo "$out" >&2
    exit 1
}
case "$out" in
*-Wlto-type-mismatch*) ;;
*)
    echo "** ERROR: $FLAVOUR has LTO flags ($lto), but the link did not report the type mismatch." >&2
    echo "   The compiler, the Fortran compiler or the linker is not doing LTO." >&2
    echo "$out" >&2
    exit 1
    ;;
esac

echo "assert-r-lto.sh: flavour=$FLAVOUR"
echo "  lto: $lto"
echo "  ok: an LTO link reports a type mismatch between two files"

install -d /etc/rcheck 2>/dev/null || true
echo "r_lto: $lto" > /etc/rcheck/r-lto.txt 2>/dev/null || true
