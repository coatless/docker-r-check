#!/bin/sh
# Install the BLIS and the LAPACK that CRAN's BLIS checks load: libblis.so.4
# from Fedora 44's blis-2.0-5 package in /opt/blis, and liblapack.so.3 from
# its lapack-3.12.0-11 package in /opt/lapack. Then register both with
# Debian's alternatives.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
blis_url="https://kojipkgs.fedoraproject.org/packages/blis/2.0/5.fc44/x86_64/blis-2.0-5.fc44.x86_64.rpm"
blis_sha256="ffc438297ef0147fced260a50710c266a5c4da963c8da4ee7bbb4f08d8d54946"
lapack_url="https://kojipkgs.fedoraproject.org/packages/lapack/3.12.0/11.fc44/x86_64/lapack-3.12.0-11.fc44.x86_64.rpm"
lapack_sha256="02052e478015d914267bcf6f6872e60bf337df8fcbf740c4d0eb1261a2e961ba"

apt-get install -y -qq libarchive-tools
tmp="$(mktemp -d)"
curl -fsSL -o "$tmp/blis.rpm" "$blis_url"
curl -fsSL -o "$tmp/lapack.rpm" "$lapack_url"
printf '%s  %s\n' "$blis_sha256" "$tmp/blis.rpm" "$lapack_sha256" "$tmp/lapack.rpm" | sha256sum -c -
mkdir "$tmp/blis" "$tmp/lapack"
bsdtar -xf "$tmp/blis.rpm" -C "$tmp/blis"
bsdtar -xf "$tmp/lapack.rpm" -C "$tmp/lapack"

install -d /opt/blis/lib /opt/blis/share
install -m 0755 "$tmp/blis/usr/lib64/libblis.so.4.0.0" /opt/blis/lib/
ln -s libblis.so.4.0.0 /opt/blis/lib/libblis.so.4
cp -r "$tmp/blis/usr/share/licenses/blis" /opt/blis/share/licenses 2>/dev/null || true

# Fedora's liblapack.so.3 calls the BLAS through libblas.so.3, which the
# alternatives point at the BLIS above.
install -d /opt/lapack/lib /opt/lapack/share
install -m 0755 "$tmp/lapack/usr/lib64/liblapack.so.3.12.0" /opt/lapack/lib/
ln -s liblapack.so.3.12.0 /opt/lapack/lib/liblapack.so.3
ln -s liblapack.so.3 /opt/lapack/lib/liblapack.so
install -m 0644 "$tmp/lapack/usr/share/doc/lapack/LICENSE" /opt/lapack/share/LICENSE
rm -rf "$tmp"

sh "$here/blis-register.sh"

ma="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
if ldd /opt/lapack/lib/liblapack.so.3 2>&1 | grep 'not found'; then
    echo "blisfedora-setup.sh: /opt/lapack/lib/liblapack.so.3 does not load on this system" >&2
    exit 1
fi
update-alternatives --install "/usr/lib/$ma/liblapack.so.3" "liblapack.so.3-$ma" /opt/lapack/lib/liblapack.so.3 10
update-alternatives --install "/usr/lib/$ma/liblapack.so" "liblapack.so-$ma" /opt/lapack/lib/liblapack.so 10
