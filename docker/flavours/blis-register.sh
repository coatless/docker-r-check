#!/bin/sh
# Register the BLIS in /opt/blis with Debian's alternatives, so that
# blas-wiring.sh can select it as libblis.so.4, libblas.so.3 and libblas.so.
set -eu

ma="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
lib=/opt/blis/lib

[ -e "$lib/libblis.so.4" ] || { echo "blis-register.sh: no $lib/libblis.so.4" >&2; exit 1; }
[ -e "$lib/libblis.so" ] || ln -s libblis.so.4 "$lib/libblis.so"
if ldd "$lib/libblis.so.4" 2>&1 | grep 'not found'; then
    echo "blis-register.sh: $lib/libblis.so.4 does not load on this system" >&2
    exit 1
fi

update-alternatives --install "/usr/lib/$ma/libblis.so.4" "libblis.so.4-$ma" "$lib/libblis.so.4" 10
update-alternatives --install "/usr/lib/$ma/libblas.so.3" "libblas.so.3-$ma" "$lib/libblis.so.4" 10
update-alternatives --install "/usr/lib/$ma/libblas.so" "libblas.so-$ma" "$lib/libblis.so" 10
