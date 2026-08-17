#!/bin/sh
# flavour-setup.sh -- install one check arm's system side, then prove it took.
#
#   flavour-setup.sh <flavour> [flavours-dir]
#
# Reads flavours/<flavour>.env (see flavours/README) and, in this order:
#   1. writes the apt preferences the arm needs, BEFORE anything is installed
#   2. installs RCC_SYSDEPS from apt
#   3. fetches RCC_SYSDEB_URLS, checks them against RCC_SYSDEB_SHA256, dpkg -i
#   4. apt-mark holds RCC_APT_HOLD
#   5. hands over to blas-wiring.sh apply, which also verifies
#
# The ordering is not incidental.  For ATLAS, installing libgfortran5 first is
# what stops `dpkg -i` leaving the package unconfigured; and the pin is what
# stops a later `apt-get -f install` or `apt upgrade` from unpacking trixie's
# transitional dummy over the real 3.10.3-13 -- which it will do silently,
# leaving you with reference BLAS under an ATLAS name.  Both were observed.

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
: "${RCC_APT_PIN:=}" "${RCC_APT_HOLD:=}" "${RCC_DESC:=}"

export DEBIAN_FRONTEND=noninteractive
HOST_ARCH="$(dpkg --print-architecture)"

echo "flavour-setup.sh: $FLAVOUR -- $RCC_DESC"
echo "  arch: $HOST_ARCH"

if [ -n "$RCC_ARCH" ] && [ "$RCC_ARCH" != "$HOST_ARCH" ]; then
    echo "flavour-setup.sh: $FLAVOUR is $RCC_ARCH-only, this is $HOST_ARCH." >&2
    echo "  Refusing to build an arm that cannot be what it claims." >&2
    exit 1
fi

# --- 1. apt preferences, before anything is installed ----------------------
if [ -n "$RCC_APT_PIN" ]; then
    echo "  writing /etc/apt/preferences.d/rcc-$FLAVOUR"
    printf '%s\n' "$RCC_APT_PIN" | tr '|' '\n' > "/etc/apt/preferences.d/rcc-$FLAVOUR"
    sed 's/^/    /' "/etc/apt/preferences.d/rcc-$FLAVOUR"
fi

# --- 2. apt packages -------------------------------------------------------
apt-get update -qq
if [ -n "$RCC_SYSDEPS" ]; then
    echo "  apt: $RCC_SYSDEPS"
    # Deliberately word-split: this is a package list.
    # shellcheck disable=SC2086
    apt-get install -y -qq $RCC_SYSDEPS
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

# --- 5. wire and verify the BLAS ------------------------------------------
echo "  wiring BLAS for $FLAVOUR"
sh "$WIRING" apply "$FLAVOUR"

# --- 6. record what this arm actually is ----------------------------------
install -d /etc/rcheck
{
    echo "flavour: $FLAVOUR"
    echo "desc: $RCC_DESC"
    echo "arch: $HOST_ARCH"
    echo "rconf_flags: ${RCC_RCONF_FLAGS:-}"
    echo "sysdeps: $RCC_SYSDEPS"
    echo "sysdeb_urls: $RCC_SYSDEB_URLS"
    echo "--- resolved libraries ---"
    sh "$WIRING" show
} > /etc/rcheck/flavour.txt
cat /etc/rcheck/flavour.txt

rm -rf /var/lib/apt/lists/*
echo "flavour-setup.sh: $FLAVOUR ready"
