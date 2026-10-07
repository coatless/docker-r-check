#!/bin/bash
# Run packages from one of CRAN's lists in the image that the check's own
# maintainer publishes, and keep the output where report.py looks for it.
# Nothing is built here. It measures how far an existing image reproduces
# CRAN's result.
#
#   eval/published.sh <musl|rchk> <results-dir> <pkg_version.tar.gz>...
#
#   musl  ghcr.io/bastistician/rcheck-musl, Alpine Linux with the R release.
#         CRAN's musl checks only install, so this installs the package's
#         hard dependencies and then the package.
#   rchk  ghcr.io/r-hub/containers/rchk, R-devel with the rchk analyzer. Its
#         r-check script analyzes every tarball in /check.
#
# RCC_ENGINE picks docker (default) or podman. RCC_PUBLISHED_IMAGE overrides
# the image. A package gets 60 minutes.
set -euo pipefail

[ $# -ge 3 ] || { echo "usage: $0 <musl|rchk> <results-dir> <tarball>..." >&2; exit 2; }
kind="$1"; out="$2"; shift 2
ENGINE="${RCC_ENGINE:-docker}"
case "$kind" in
musl) image="${RCC_PUBLISHED_IMAGE:-ghcr.io/bastistician/rcheck-musl:latest}" ;;
rchk) image="${RCC_PUBLISHED_IMAGE:-ghcr.io/r-hub/containers/rchk:latest}" ;;
*)    echo "$0: unknown kind '$kind'" >&2; exit 2 ;;
esac

"$ENGINE" pull -q "$image" >/dev/null
image_id="$("$ENGINE" image inspect --format '{{.Id}}' "$image")"

for tb in "$@"; do
    base="$(basename "$tb")"; pkg="${base%%_*}"
    dest="$out/$kind/$pkg"
    rm -rf "$dest"; mkdir -p "$dest/$pkg.Rcheck"
    stage="$(mktemp -d)"
    cp "$tb" "$stage/"; chmod 0755 "$stage"; chmod 0644 "$stage/$base"
    start=$SECONDS; rc=0
    case "$kind" in
    musl)
        log="$dest/$pkg.Rcheck/00install.out"
        timeout 3600 "$ENGINE" run --rm -v "$stage:/pkgs:ro" "$image" sh -c '
            r=https://cloud.r-project.org
            R -s -e "a <- available.packages(repos = \"$r\");
                     d <- unlist(tools::package_dependencies(\"'"$pkg"'\", a, c(\"Depends\", \"Imports\", \"LinkingTo\"), recursive = TRUE));
                     d <- setdiff(d, rownames(installed.packages()));
                     if (length(d)) install.packages(d, repos = \"$r\")" > /tmp/deps.log 2>&1 ||
                { echo "installing the dependencies failed"; tail -n 20 /tmp/deps.log; }
            R CMD INSTALL "/pkgs/'"$base"'"' > "$log" 2>&1 || rc=$?
        if grep -q "^\* DONE ($pkg)" "$log"; then status="OK"; else status="1 ERROR"; fi
        ;;
    rchk)
        log="$dest/$pkg.Rcheck/rchk.out"
        timeout 3600 "$ENGINE" run --rm -v "$stage:/check" "$image" r-check > "$log" 2>&1 || rc=$?
        if grep -qE '^\s*\[[A-Z]{2}\] ' "$log"; then status="1 NOTE"; else status="OK"; fi
        ;;
    esac
    # The container runs as root, so files it left behind may not be ours to
    # delete.
    rm -rf "$stage" 2>/dev/null || true
    {
        echo "Package: $pkg"
        echo "Tarball: $base"
        echo "Flavour: $kind"
        echo "Image: $image"
        echo "Image-ID: $image_id"
        echo "Engine: $ENGINE"
        echo "Elapsed-Seconds: $((SECONDS - start))"
        echo "Exit: $rc"
        echo "Status: $status"
    } > "$dest/manifest.dcf"
    printf '   %-20s %s (exit %s, %ss)\n' "$pkg" "$status" "$rc" "$((SECONDS - start))"
done
