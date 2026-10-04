#!/bin/sh
# Install the libblis.so.4 from Fedora 44's blis-2.0-5 package in /opt/blis.
# This is the binary that CRAN's BLIS checks load.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
url="https://kojipkgs.fedoraproject.org/packages/blis/2.0/5.fc44/x86_64/blis-2.0-5.fc44.x86_64.rpm"
sha256="ffc438297ef0147fced260a50710c266a5c4da963c8da4ee7bbb4f08d8d54946"

apt-get install -y -qq libarchive-tools
tmp="$(mktemp -d)"
curl -fsSL -o "$tmp/blis.rpm" "$url"
echo "$sha256  $tmp/blis.rpm" | sha256sum -c -
bsdtar -xf "$tmp/blis.rpm" -C "$tmp"
install -d /opt/blis/lib /opt/blis/share
install -m 0755 "$tmp/usr/lib64/libblis.so.4.0.0" /opt/blis/lib/
ln -s libblis.so.4.0.0 /opt/blis/lib/libblis.so.4
cp -r "$tmp/usr/share/licenses/blis" /opt/blis/share/licenses 2>/dev/null || true
rm -rf "$tmp"

sh "$here/blis-register.sh"
