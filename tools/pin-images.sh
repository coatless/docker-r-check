#!/bin/bash
#
# Resolve every base image used by a flavor to an immutable digest, and record
# it in pins/base-images.tsv.
#
# `debian:unstable` means something different every day. Building from the tag
# gives an image that cannot be rebuilt, and therefore a check result that
# cannot be explained six months later. Pinning the digest is the cheapest half
# of reproducibility; the other half is DEBIAN_SNAPSHOT, which pins the packages
# installed *into* the image (see docker/apt-setup.sh).
#
# Talks to the registry HTTP API rather than using `docker pull`, so it works on
# a machine with no container runtime -- including a CI job whose only purpose
# is to refresh the pins.
#
# Usage:
#   pin-images.sh              refresh pins/base-images.tsv
#   pin-images.sh --check      exit non-zero if any pin is missing or stale
#   pin-images.sh --show       print current pins

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
PINS=${RCHECK_PINS:-$repo/pins/base-images.tsv}
FLAVOR_DIR=${RCHECK_FLAVOR_DIR:-$repo/flavors}

mode=refresh
case ${1:-} in
    --check) mode=check ;;
    --show)  mode=show ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    "") ;;
    *) echo "pin-images.sh: unknown option $1" >&2; exit 2 ;;
esac

for tool in curl awk sed; do
    command -v "$tool" >/dev/null || { echo "pin-images.sh: $tool is required" >&2; exit 1; }
done

## Docker Hub needs a pull token even for public images, and official images
## live under the library/ namespace.
resolve_digest() {
    local image=$1 tag=$2 host path token digest

    case $image in
        docker.io/*) host=registry-1.docker.io; path=${image#docker.io/} ;;
        */*/*)       echo "pin-images.sh: unsupported registry in '$image'" >&2; return 1 ;;
        *)           host=registry-1.docker.io; path=$image ;;
    esac
    case $path in
        */*) ;;
        *) path=library/$path ;;
    esac

    token=$(curl -sS --max-time 60 \
        "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${path}:pull" \
        | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
    [ -n "$token" ] || { echo "pin-images.sh: could not get a pull token for $path" >&2; return 1; }

    digest=$(curl -sS --max-time 60 -I \
        -H "Authorization: Bearer $token" \
        -H 'Accept: application/vnd.oci.image.index.v1+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        "https://${host}/v2/${path}/manifests/${tag}" \
        | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *//p')

    [ -n "$digest" ] || { echo "pin-images.sh: no digest for ${image}:${tag}" >&2; return 1; }
    printf '%s\n' "$digest"
}

## Every distinct BASE_IMAGE:BASE_TAG across all flavors. Pins are shared, so
## the ten Debian-unstable flavors resolve one digest between them and cannot
## drift apart from each other.
wanted_refs() {
    awk '
        FNR == 1 { image = ""; tag = "" }
        /^BASE_IMAGE=/ { image = $0; sub(/^BASE_IMAGE=/, "", image); gsub(/"/, "", image) }
        /^BASE_TAG=/   { tag   = $0; sub(/^BASE_TAG=/,   "", tag);   gsub(/"/, "", tag) }
        FNR > 1 && image != "" && tag != "" { print image ":" tag; image = ""; tag = "" }
    ' "$FLAVOR_DIR"/*.conf | sort -u
}

if [ "$mode" = show ]; then
    [ -f "$PINS" ] || { echo "pin-images.sh: no pins file at $PINS" >&2; exit 1; }
    cat "$PINS"
    exit 0
fi

if [ "$mode" = check ]; then
    rc=0
    for ref in $(wanted_refs); do
        if ! grep -q "^${ref}	" "$PINS" 2>/dev/null; then
            echo "MISSING PIN: $ref" >&2
            rc=1
        fi
    done
    [ $rc -eq 0 ] && echo "all base images are pinned"
    exit $rc
fi

mkdir -p "$(dirname "$PINS")"
tmp=$(mktemp) || exit 1
trap 'rm -f "$tmp"' EXIT

{
    echo "## Base image digests, resolved by tools/pin-images.sh."
    echo "## Canonical machine-readable form: ref<TAB>digest<TAB>resolved_at"
    echo "##"
    echo "## Refreshing this file changes what every flavor builds from, so it is"
    echo "## a deliberate, reviewable commit -- never something CI does silently."
    printf 'ref\tdigest\tresolved_at\n'
} > "$tmp"

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
rc=0
for ref in $(wanted_refs); do
    image=${ref%:*}
    tag=${ref##*:}
    printf 'resolving %s ... ' "$ref" >&2
    if digest=$(resolve_digest "$image" "$tag"); then
        printf '%s\n' "$digest" >&2
        printf '%s\t%s\t%s\n' "$ref" "$digest" "$now" >> "$tmp"
    else
        printf 'FAILED\n' >&2
        ## Keep any digest we already had rather than dropping the pin: losing a
        ## pin because the registry was briefly unreachable would silently
        ## un-pin the build.
        if old=$(grep "^${ref}	" "$PINS" 2>/dev/null); then
            printf '%s\n' "$old" >> "$tmp"
            echo "  kept previous pin" >&2
        else
            rc=1
        fi
    fi
done

mv "$tmp" "$PINS"
trap - EXIT
echo "wrote $PINS" >&2
exit $rc
