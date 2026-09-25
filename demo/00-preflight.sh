#!/bin/bash
# Check that this host can build and run the amd64 check images, and say
# whether it will do so natively or under emulation.
#
#   demo/00-preflight.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"

command -v "$ENGINE" >/dev/null || die "$ENGINE not found (RCC_ENGINE=podman to use Podman)"
"$ENGINE" info >/dev/null 2>&1 || die "$ENGINE is installed but its daemon/machine is not running"

echo "host       : $(uname -s) $(uname -m)"
echo "engine     : $ENGINE $("$ENGINE" version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"

probe="$("$ENGINE" run --rm --platform "$PLATFORM" debian:trixie-slim sh -c \
    'echo "$(uname -m)|$(sed -n "s/^model name[[:space:]]*: //p" /proc/cpuinfo | head -n 1)|$(grep -c ^processor /proc/cpuinfo)"')" \
    || die "cannot run $PLATFORM containers on this host"
arch="${probe%%|*}"; rest="${probe#*|}"; cpu="${rest%%|*}"; ncpu="${rest##*|}"
echo "container  : $arch, $ncpu CPUs, '$cpu'"

case "$(uname -m):$cpu" in
x86_64:*|amd64:*)
    echo "mode       : native amd64" ;;
*:*VirtualApple*)
    echo "mode       : emulated through Rosetta -- usable for building and for trying things out" ;;
*)
    echo "mode       : emulated through QEMU -- expect this to be several times slower than Rosetta"
    echo "             (Docker Desktop: Settings > General > 'Use Rosetta for x86_64/amd64 emulation')" ;;
esac

if [ "$ENGINE" = docker ]; then
    mem="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
    echo "engine RAM : $((mem / 1024 / 1024 / 1024)) GiB"
    [ "$mem" -ge $((6 * 1024 * 1024 * 1024)) ] || echo "  WARNING: give the engine at least 8 GiB; building R and checking packages with compiled code needs it"
fi

free_gb="$(df -Pk "$ROOT" | awk 'NR == 2 {print int($4 / 1024 / 1024)}')"
echo "host disk  : ${free_gb} GiB free"
[ "$free_gb" -ge 40 ] || echo "  WARNING: the shared base layer alone is ~17 GB and needs ~22 GB while it is being built"
