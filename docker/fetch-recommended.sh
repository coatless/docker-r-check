#!/bin/sh
# Fetch R's recommended packages into a source tree over HTTPS and create the
# links R's build expects. tools/rsync-recommended does the same over rsync,
# but CRAN's rsync server limits its connections and often refuses them.
#
#   fetch-recommended.sh <R source directory>
#
# CRAN_HTTPS sets the mirror. The default is CRAN's content delivery network.
set -eu

src="${1:?usage: fetch-recommended.sh <R source directory>}"
mirror="${CRAN_HTTPS:-https://cloud.r-project.org}"

cd "$src"
version="$(cut -f1 -d' ' VERSION)"
if [ "$(cut -f2 -d' ' VERSION)" = Patched ]; then
    version="$(echo "$version" | sed 's/\.[0-9]*$//')-patched"
fi
pkgs="$(grep '^R_PKGS_RECOMMENDED *=' share/make/vars.mk | sed 's/.*=//')"
url="$mirror/src/contrib/$version/Recommended"

cd src/library/Recommended
files="$(curl -fsSL "$url/" | grep -oE 'href="[A-Za-z0-9.]+_[0-9.-]+\.tar\.gz"' | sed 's/href="//; s/"//')"
[ -n "$files" ] || { echo "fetch-recommended.sh: no tarballs listed at $url" >&2; exit 1; }

rm -f ./*.tar.gz ./*.tgz
for f in $files; do
    curl -fsSL -o "$f" "$url/$f"
done
for p in $pkgs; do
    set -- "$p"_*.tar.gz
    [ -e "$1" ] || { echo "fetch-recommended.sh: $p is not at $url" >&2; exit 1; }
    ln -s "$1" "$p.tgz"
done
echo "fetch-recommended.sh: $(echo "$files" | wc -w | tr -d ' ') packages from $url"
