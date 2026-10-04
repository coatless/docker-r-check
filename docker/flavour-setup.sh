#!/bin/sh
# Install one arm's system packages, then select and check its BLAS.
#
#   flavour-setup.sh <flavour> [flavours-dir]
#
# Reads flavours/<flavour>.env (see flavours/README) and, in this order:
#   1. writes the apt source, signing key and preferences the arm needs
#   2. installs RCC_SYSDEPS from apt, and removes RCC_APT_REMOVE if installed
#   3. fetches RCC_SYSDEB_URLS, checks them against RCC_SYSDEB_SHA256, dpkg -i
#   4. apt-mark holds RCC_APT_HOLD
#   5. runs blas-wiring.sh apply, which also verifies
#   6. writes RCC_CHECK_ENV to /etc/rcheck/check.env for entry-pkgcheck.sh
#
# The order matters for ATLAS. libgfortran5 has to be installed before
# dpkg -i, and the pin keeps a later apt run from replacing ATLAS 3.10.3-13
# with trixie's transitional package, which contains no BLAS.

set -eu

FLAVOUR="${1:?usage: flavour-setup.sh <flavour> [flavours-dir]}"
FLAVOURS_DIR="${2:-/opt/rcheck/flavours}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WIRING="${RCC_WIRING:-$HERE/blas-wiring.sh}"

ENVFILE="$FLAVOURS_DIR/$FLAVOUR.env"
[ -r "$ENVFILE" ] || { echo "flavour-setup.sh: no such flavour: $ENVFILE" >&2; exit 2; }

# shellcheck disable=SC1090
. "$ENVFILE"

: "${RCC_ARCH:=}" "${RCC_SYSDEPS:=}" "${RCC_SYSDEB_URLS:=}" "${RCC_SYSDEB_SHA256:=}"
: "${RCC_APT_PIN:=}" "${RCC_APT_HOLD:=}" "${RCC_APT_REMOVE:=}" "${RCC_DESC:=}"
: "${RCC_APT_SOURCE:=}" "${RCC_APT_KEY:=}" "${RCC_CHECK_ENV:=}"

export DEBIAN_FRONTEND=noninteractive
HOST_ARCH="$(dpkg --print-architecture)"

echo "flavour-setup.sh: $FLAVOUR -- $RCC_DESC"
echo "  arch: $HOST_ARCH"

if [ -n "$RCC_ARCH" ] && [ "$RCC_ARCH" != "$HOST_ARCH" ]; then
    echo "flavour-setup.sh: $FLAVOUR is $RCC_ARCH-only, this is $HOST_ARCH." >&2
    echo "  Refusing to build an arm that cannot be what it claims." >&2
    exit 1
fi

# --- 1. apt source, key and preferences, before anything is installed -----
if [ -n "$RCC_APT_KEY" ]; then
    echo "  key: /etc/apt/keyrings/$RCC_APT_KEY"
    install -d /etc/apt/keyrings
    install -m 0644 "$FLAVOURS_DIR/$RCC_APT_KEY" "/etc/apt/keyrings/$RCC_APT_KEY"
fi
if [ -n "$RCC_APT_SOURCE" ]; then
    echo "  writing /etc/apt/sources.list.d/rcc-$FLAVOUR.sources"
    printf '%s\n' "$RCC_APT_SOURCE" | tr '|' '\n' > "/etc/apt/sources.list.d/rcc-$FLAVOUR.sources"
    sed 's/^/    /' "/etc/apt/sources.list.d/rcc-$FLAVOUR.sources"
fi
if [ -n "$RCC_APT_PIN" ]; then
    echo "  writing /etc/apt/preferences.d/rcc-$FLAVOUR"
    printf '%s\n' "$RCC_APT_PIN" | tr '|' '\n' > "/etc/apt/preferences.d/rcc-$FLAVOUR"
    sed 's/^/    /' "/etc/apt/preferences.d/rcc-$FLAVOUR"
fi

# --- 2. apt packages -------------------------------------------------------
apt-get update -qq
if [ -n "$RCC_SYSDEPS" ]; then
    echo "  apt: $RCC_SYSDEPS"
    # Word splitting is intended. This is a package list.
    # shellcheck disable=SC2086
    apt-get install -y -qq $RCC_SYSDEPS
fi
# Remove only what is installed. apt-get remove fails on a package it does
# not know, and a bare base lacks some of these.
removed=""
if [ -n "$RCC_APT_REMOVE" ]; then
    # shellcheck disable=SC2086
    removed="$(dpkg-query -W -f='${Package} ${Status}\n' $RCC_APT_REMOVE 2>/dev/null |
        awk '$NF == "installed" {print $1}' | tr '\n' ' ')"
    if [ -n "$removed" ]; then
        echo "  apt remove: $removed"
        # shellcheck disable=SC2086
        apt-get remove -y -qq $removed
    fi
fi

# --- 3. .debs fetched by URL ----------------------------------------------
if [ -n "$RCC_SYSDEB_URLS" ]; then
    tmp="$(mktemp -d)"
    i=0
    for url in $RCC_SYSDEB_URLS; do
        i=$((i + 1))
        f="$tmp/$(basename "$url")"
        echo "  fetch: $url"
        curl -fsS --proto '=https,http' -o "$f" "$url" \
            || { echo "flavour-setup.sh: fetch failed: $url" >&2; exit 1; }

        want="$(printf '%s\n' $RCC_SYSDEB_SHA256 | sed -n "${i}p")"
        if [ -n "$want" ]; then
            got="$(sha256sum "$f" | cut -d' ' -f1)"
            if [ "$got" != "$want" ]; then
                echo "flavour-setup.sh: checksum mismatch for $(basename "$url")" >&2
                echo "    got  $got" >&2
                echo "    want $want" >&2
                echo "  A substituted .deb here is a silently different BLAS." >&2
                exit 1
            fi
            echo "    sha256 ok"
        else
            echo "    WARNING: no sha256 recorded for this URL" >&2
        fi
    done
    echo "  dpkg -i $(ls "$tmp" | tr '\n' ' ')"
    dpkg -i "$tmp"/*.deb
    rm -rf "$tmp"
fi

# --- 4. hold ---------------------------------------------------------------
if [ -n "$RCC_APT_HOLD" ]; then
    # shellcheck disable=SC2086
    apt-mark hold $RCC_APT_HOLD
fi

# --- 5. select and verify the BLAS ----------------------------------------
echo "  wiring BLAS for $FLAVOUR"
sh "$WIRING" apply "$FLAVOUR"

# --- 6. record what was installed -----------------------------------------
install -d /etc/rcheck
if [ -n "$RCC_CHECK_ENV" ]; then
    printf '%s\n' "$RCC_CHECK_ENV" | tr '|' '\n' > /etc/rcheck/check.env
    echo "  check environment:"
    sed 's/^/    /' /etc/rcheck/check.env
fi
{
    echo "flavour: $FLAVOUR"
    echo "desc: $RCC_DESC"
    echo "arch: $HOST_ARCH"
    echo "rconf_flags: ${RCC_RCONF_FLAGS:-}"
    echo "apt_source: $(printf '%s' "$RCC_APT_SOURCE" | sed -n 's/.*URIs: \([^|]*\).*/\1/p')"
    echo "sysdeps: $RCC_SYSDEPS"
    # shellcheck disable=SC2046,SC2086
    echo "sysdep_versions: $(dpkg-query -W -f='${Package}=${Version} ' $(printf '%s\n' $RCC_SYSDEPS | sed 's/=.*//') 2>/dev/null)"
    echo "removed: $removed"
    echo "sysdeb_urls: $RCC_SYSDEB_URLS"
    echo "--- resolved libraries ---"
    sh "$WIRING" show
} > /etc/rcheck/flavour.txt
cat /etc/rcheck/flavour.txt

rm -rf /var/lib/apt/lists/*
echo "flavour-setup.sh: $FLAVOUR ready"
