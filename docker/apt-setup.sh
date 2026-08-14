#!/bin/bash
#
# Point apt at the archive this image is pinned to, before anything is
# installed. Run inside the base image build.
#
# Three independent knobs, in decreasing order of importance for
# reproducibility:
#
#   DEBIAN_SNAPSHOT   snapshot.debian.org timestamp (e.g. 20260801T000000Z).
#                     When set, this is what makes a rebuild months later
#                     install the same package versions rather than whatever
#                     unstable holds that day. Overrides DEBIAN_MIRROR.
#   DEBIAN_MIRROR     ordinary mirror, for build speed. No effect on which
#                     versions are installed, only on where they come from.
#   APT_COMPONENTS    archive components (main / main contrib non-free).
#
# Handles both the deb822 sources.list.d layout used by current Debian images
# and the older one-line sources.list, because the base image tag is a build
# argument and old tags are a legitimate thing to pin to.
#
# Snapshot URLs are http, not https, so that this can run as the very first
# step of the build -- before ca-certificates exists. Nothing is lost in
# integrity terms: apt verifies the archive signature against the Debian
# keyring either way. Doing it in this order is what keeps DEBIAN_MIRROR
# effective for the initial apt-get update rather than only for later ones.

set -eu

SRC=/etc/apt/sources.list.d/debian.sources
LEGACY=/etc/apt/sources.list

DEBIAN_SNAPSHOT=${DEBIAN_SNAPSHOT:-}
DEBIAN_MIRROR=${DEBIAN_MIRROR:-http://deb.debian.org}
APT_COMPONENTS=${APT_COMPONENTS:-main}

## Never let a transient mirror error fail a long image build silently.
cat > /etc/apt/apt.conf.d/10rcheck <<'EOF'
Acquire::Retries "5";
EOF

if [ -n "$DEBIAN_SNAPSHOT" ]; then
    ## Snapshots are frozen in the past, so their Release files are always
    ## "expired" as far as apt is concerned. That check has to go, and only
    ## then -- it is the one apt guarantee we are knowingly trading away, in
    ## exchange for byte-identical package versions on every rebuild.
    cat >> /etc/apt/apt.conf.d/10rcheck <<'EOF'
Acquire::Check-Valid-Until "false";
EOF
    echo "== pinning apt to snapshot.debian.org/${DEBIAN_SNAPSHOT}"
fi

rewrite_deb822() {
    local f=$1
    if [ -n "$DEBIAN_SNAPSHOT" ]; then
        sed -i -E \
            -e "s,^(URIs:[[:space:]]*).*/debian-security/?[[:space:]]*$,\\1http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}/," \
            -e "s,^(URIs:[[:space:]]*).*/debian/?[[:space:]]*$,\\1http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/," \
            "$f"
    else
        sed -i "s,http://deb[.]debian[.]org,${DEBIAN_MIRROR},g" "$f"
    fi
    sed -i -E "s,^(Components:[[:space:]]*).*,\\1${APT_COMPONENTS}," "$f"
}

rewrite_legacy() {
    local f=$1
    if [ -n "$DEBIAN_SNAPSHOT" ]; then
        sed -i -E \
            -e "s,https?://[^ ]*/debian-security,http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}," \
            -e "s,https?://[^ ]*/debian(/)?( ),http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/\\2," \
            "$f"
    else
        sed -i "s,http://deb[.]debian[.]org,${DEBIAN_MIRROR},g" "$f"
    fi
}

if [ -f "$SRC" ]; then
    rewrite_deb822 "$SRC"
    cat "$SRC"
elif [ -f "$LEGACY" ]; then
    rewrite_legacy "$LEGACY"
    cat "$LEGACY"
else
    echo "** ERROR: no apt sources found at $SRC or $LEGACY" >&2
    exit 1
fi
