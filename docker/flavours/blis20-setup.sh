#!/bin/sh
# Build BLIS 2.0 the way Fedora's blis-2.0-5 package does and install it in
# /opt/blis. CRAN's BLIS checks use that Fedora package.
#
# Fedora builds the x86_64 configuration family, which picks its kernels for
# the CPU at run time, with CBLAS, with -O3 -funsafe-math-optimizations, and
# with one upstream patch for the Haswell kernels, kept here as
# blis-2.0-gcc16.patch.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
url="https://github.com/flame/blis/archive/2.0/blis-2.0.tar.gz"
sha256="08bbebd77914a6d1a43874ae5ec2f54fe6a77cba745f2532df28361b0f1ad1b3"

apt-get install -y -qq python3 patch
tmp="$(mktemp -d)"
curl -fsSL -o "$tmp/blis.tar.gz" "$url"
echo "$sha256  $tmp/blis.tar.gz" | sha256sum -c -
tar -xzf "$tmp/blis.tar.gz" -C "$tmp"
cd "$tmp/blis-2.0"
patch -p1 < "$here/blis-2.0-gcc16.patch"
CFLAGS="-O2 -g -O3 -funsafe-math-optimizations" ./configure --prefix=/opt/blis \
    --enable-debug=opt --disable-static --enable-shared --enable-cblas x86_64
if ! make -j"$(nproc)" > "$tmp/make.log" 2>&1; then
    tail -n 40 "$tmp/make.log" >&2
    exit 1
fi
make install > /dev/null
cd /
rm -rf "$tmp"

sh "$here/blis-register.sh"
