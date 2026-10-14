#!/bin/sh
# Build GDAL with clang and libc++ in /usr/local/clang, for the clang arms.
#
# Debian's GDAL is built with libstdc++. A package compiled with libc++ that
# calls GDAL's C++ API then needs symbols GDAL does not have, so sf and terra
# do not load on testing, and terra not on stable. CRAN's clang machine has GDAL 3.12.4 built with libc++ in
# /usr/local/clang and uses the system's PROJ and GEOS, whose C APIs GDAL
# calls. This does the same. GDAL's other external libraries are limited to
# ones with a C API, so no C++ library built with libstdc++ is linked in.
#
# The arm's check environment puts /usr/local/clang/bin first in PATH, so
# packages find this gdal-config.
set -eu

version=3.12.4
url="https://github.com/OSGeo/gdal/releases/download/v$version/gdal-$version.tar.gz"
sha256="68844ae29557b7efae4292c3b4cb3a3b8a79d14b765b89c5a7b17cbae7fa715a"
prefix=/usr/local/clang
llvm="${RCC_LLVM_VERSION:-23}"
# GDAL 3.12.4 relies on headers that libc++ 23 no longer brings in through
# other headers. port/cpl_vsil_curl.cpp and port/cpl_vsil_cache.cpp call
# std::strtoull without <cstdlib>, and apps/gdalalg_raster_tile.h uses
# std::atomic without <atomic>. On 2026-10-14 GDAL's 3.12 branch still had all
# three, and master two of them.
cxxflags="-stdlib=libc++ -include cstdlib -include atomic"

tmp="$(mktemp -d)"
curl -fsSL -o "$tmp/gdal.tar.gz" "$url"
echo "$sha256  $tmp/gdal.tar.gz" | sha256sum -c -
tar -xzf "$tmp/gdal.tar.gz" -C "$tmp"

cmake -S "$tmp/gdal-$version" -B "$tmp/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_COMPILER="clang-$llvm" \
    -DCMAKE_CXX_COMPILER="clang++-$llvm" \
    -DCMAKE_CXX_FLAGS="$cxxflags" \
    -DCMAKE_EXE_LINKER_FLAGS="-stdlib=libc++" \
    -DCMAKE_SHARED_LINKER_FLAGS="-stdlib=libc++" \
    -DBUILD_TESTING=OFF \
    -DBUILD_PYTHON_BINDINGS=OFF \
    -DBUILD_JAVA_BINDINGS=OFF \
    -DBUILD_CSHARP_BINDINGS=OFF \
    -DGDAL_USE_EXTERNAL_LIBS=OFF \
    -DGDAL_USE_GEOS=ON \
    -DGDAL_USE_SQLITE3=ON \
    -DGDAL_USE_CURL=ON \
    -DGDAL_USE_EXPAT=ON \
    -DGDAL_USE_ZSTD=ON \
    -DGDAL_USE_LIBLZMA=ON \
    -DGDAL_USE_DEFLATE=ON \
    -DGDAL_USE_WEBP=ON \
    -DGDAL_USE_OPENJPEG=ON \
    -DGDAL_USE_NETCDF=ON \
    -DGDAL_USE_PCRE2=ON \
    -DGDAL_USE_ICONV=ON
cmake --build "$tmp/build" -j "$(nproc)"
cmake --install "$tmp/build"
echo "$prefix/lib" > /etc/ld.so.conf.d/rcc-clang-gdal.conf
ldconfig

# A program built with libc++ that passes a std::string to GDAL links only
# against a GDAL built with libc++, because libc++ names its types
# differently. It must also run without a search path of its own.
cat > "$tmp/t.cpp" <<'EOF'
#include <string>
#include "cpl_json.h"
int main() {
    CPLJSONDocument doc;
    if (!doc.LoadMemory(std::string("{\"a\": 1}"))) return 1;
    return doc.GetRoot().GetInteger(std::string("a")) == 1 ? 0 : 1;
}
EOF
# shellcheck disable=SC2046
"clang++-$llvm" -stdlib=libc++ -std=gnu++20 $("$prefix/bin/gdal-config" --cflags) \
    "$tmp/t.cpp" $("$prefix/bin/gdal-config" --libs) -o "$tmp/t"
"$tmp/t" || { echo "clang-gdal.sh: the GDAL built with libc++ does not work" >&2; exit 1; }
ldd "$tmp/t" | grep -q "$prefix/lib/libgdal" \
    || { echo "clang-gdal.sh: the test program did not load $prefix/lib/libgdal" >&2; exit 1; }
echo "clang-gdal.sh: GDAL $("$prefix/bin/gdal-config" --version) built with libc++ in $prefix"
rm -rf "$tmp"
