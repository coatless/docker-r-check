#!/bin/bash
# Test blas-wiring.sh against real Debian packages, including the negative case.
set -u
export DEBIAN_FRONTEND=noninteractive
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
no()  { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# Locate the scripts relative to this file, so the suite runs the same way from
# a bind mount, a checkout, or a CI container.  RCC_WIRING overrides.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
W="${RCC_WIRING:-$ROOT/docker/blas-wiring.sh}"
SETUP="${RCC_SETUP:-$ROOT/docker/flavour-setup.sh}"
FLAVOURS="${RCC_FLAVOURS:-$ROOT/flavours}"

# Abort if the thing under test is missing.  Without this the NEGATIVE cases
# below pass for the wrong reason -- a missing script "fails" exactly like a
# script that correctly rejects bad input, and the suite reports green.
for f in "$W" "$SETUP"; do
    [ -r "$f" ] || { echo "FATAL: not found: $f" >&2; exit 2; }
done
[ -d "$FLAVOURS" ] || { echo "FATAL: no flavours dir: $FLAVOURS" >&2; exit 2; }


apt-get update -qq 2>/dev/null
# The realistic base: pthread present because libsuperlu-dev pulls it in.
apt-get install -y -qq libopenblas0-serial libopenblas0-pthread libblas3 liblapack3 libgfortran5 curl >/dev/null 2>&1

say "state before any wiring (pthread wins on priority)"
sh $W show | sed 's/^/  /'

say "T1  openblas: apply must move ALL THREE groups to serial"
if sh $W apply openblas >/dev/null 2>&1; then ok "apply exited 0"; else no "apply exited nonzero"; fi
r=$(readlink -f /usr/lib/x86_64-linux-gnu/libopenblas.so.0)
case "$r" in *openblas-serial*) ok "libopenblas.so.0 -> serial  ($r)";;
             *) no "libopenblas.so.0 -> $r";; esac
r=$(readlink -f /usr/lib/x86_64-linux-gnu/libblas.so.3)
case "$r" in *openblas-serial*) ok "libblas.so.3 -> serial";; *) no "libblas.so.3 -> $r";; esac
r=$(readlink -f /usr/lib/x86_64-linux-gnu/liblapack.so.3)
case "$r" in *openblas-serial*) ok "liblapack.so.3 -> serial";; *) no "liblapack.so.3 -> $r";; esac

say "T2  verify agrees with the state it just set"
if sh $W verify openblas >/dev/null 2>&1; then ok "verify openblas -> 0"; else no "verify openblas nonzero"; fi

say "T3  NEGATIVE: verify must FAIL when something flips the arm underneath it"
update-alternatives --set libopenblas.so.0-x86_64-linux-gnu \
  /usr/lib/x86_64-linux-gnu/openblas-pthread/libopenblas.so.0 >/dev/null 2>&1
if sh $W verify openblas >/dev/null 2>&1; then
  no "verify returned 0 with libopenblas.so.0 on pthread -- THE BUG IS BACK"
else
  ok "verify caught pthread substitution"
fi
sh $W apply openblas >/dev/null 2>&1

say "T4  reference: back to Debian's reference BLAS/LAPACK"
if sh $W apply reference >/dev/null 2>&1; then ok "apply exited 0"; else no "apply exited nonzero"; fi
r=$(readlink -f /usr/lib/x86_64-linux-gnu/libblas.so.3)
case "$r" in */blas/*) ok "libblas.so.3 -> reference ($r)";; *) no "libblas.so.3 -> $r";; esac
r=$(readlink -f /usr/lib/x86_64-linux-gnu/liblapack.so.3)
case "$r" in */lapack/*) ok "liblapack.so.3 -> reference";; *) no "liblapack.so.3 -> $r";; esac
if sh $W verify reference >/dev/null 2>&1; then ok "verify reference -> 0"; else no "verify reference nonzero"; fi

say "T5  NEGATIVE: an arm whose packages are absent must fail loudly, not silently"
if sh $W apply atlas >/dev/null 2>&1; then
  no "apply atlas returned 0 with no ATLAS installed"
else
  ok "apply atlas failed with ATLAS absent"
fi

say "T6  atlas, with the real thing installed"
apt-get install -y -qq libgfortran5 >/dev/null 2>&1
printf 'Package: libatlas3-base libatlas-base-dev\nPin: version 3.10.3-13\nPin-Priority: 1001\n' \
  > /etc/apt/preferences.d/atlas
cd /tmp
P=http://deb.debian.org/debian/pool/main/a/atlas
curl -fsS -O "$P/libatlas3-base_3.10.3-13_amd64.deb" && curl -fsS -O "$P/libatlas-base-dev_3.10.3-13_amd64.deb"
dpkg -i ./libatlas3-base_3.10.3-13_amd64.deb ./libatlas-base-dev_3.10.3-13_amd64.deb >/dev/null 2>&1
apt-mark hold libatlas3-base libatlas-base-dev >/dev/null 2>&1
if sh $W apply atlas >/dev/null 2>&1; then ok "apply atlas exited 0"; else no "apply atlas nonzero"; fi
r=$(readlink -f /usr/lib/x86_64-linux-gnu/libblas.so.3)
case "$r" in */atlas/*) ok "libblas.so.3 -> atlas ($r)";; *) no "libblas.so.3 -> $r";; esac
r=$(readlink -f /usr/lib/x86_64-linux-gnu/liblapack.so.3)
case "$r" in */atlas/*) ok "liblapack.so.3 -> atlas";; *) no "liblapack.so.3 -> $r";; esac
if sh $W verify atlas >/dev/null 2>&1; then ok "verify atlas -> 0"; else no "verify atlas nonzero"; fi

say "T7  NEGATIVE: atlas with only liblapack switched is the silent-pairing trap"
update-alternatives --set libblas.so.3-x86_64-linux-gnu \
  /usr/lib/x86_64-linux-gnu/openblas-serial/libblas.so.3 >/dev/null 2>&1
if sh $W verify atlas >/dev/null 2>&1; then
  no "verify passed with ATLAS LAPACK on OpenBLAS BLAS"
else
  ok "verify caught the split pairing"
fi

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
