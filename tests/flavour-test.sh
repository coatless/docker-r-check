#!/bin/bash
set -u
export DEBIAN_FRONTEND=noninteractive
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
say(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }

# Locate the scripts relative to this file, so the suite runs the same way from
# a bind mount, a checkout, or a CI container.  RCC_WIRING overrides.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
W="${RCC_WIRING:-$ROOT/docker/blas-wiring.sh}"
SETUP="${RCC_SETUP:-$ROOT/docker/flavour-setup.sh}"
FLAVOURS="${RCC_FLAVOURS:-$ROOT/docker/flavours}"

# Stop if the script under test is missing. Otherwise the cases that expect
# a failure would pass, because a missing script also fails.
for f in "$W" "$SETUP"; do
    [ -r "$f" ] || { echo "FATAL: not found: $f" >&2; exit 2; }
done
[ -d "$FLAVOURS" ] || { echo "FATAL: no flavours dir: $FLAVOURS" >&2; exit 2; }

S="sh $SETUP"
export RCC_WIRING="$W"
D="$FLAVOURS"

# The suite of the container the tests run in, found as flavour-setup.sh
# finds it. Some cases apply to one suite only.
case "$(cat /etc/debian_version 2>/dev/null)" in */sid) SUITE=testing ;; *) SUITE=stable ;; esac
echo "  suite: $SUITE"
# builds_here <arm> is true when the arm builds on this suite.
builds_here() {
    # shellcheck disable=SC1090
    ( . "$D/$1.env"; case " ${RCC_SUITES:-testing stable} " in *" $SUITE "*) exit 0 ;; esac; exit 1 )
}

apt-get update -qq 2>/dev/null
apt-get install -y -qq curl ca-certificates binutils >/dev/null 2>&1
# Same starting point as the real base, with pthread OpenBLAS and with
# liblapacke-dev, which rcheckserver depends on and which breaks ATLAS. On
# Debian stable libsuperlu-dev brings pthread OpenBLAS with it. On testing it
# does not, so it is named.
apt-get install -y -qq libsuperlu-dev liblapacke-dev libopenblas0-pthread >/dev/null 2>&1
echo "  base pulled in: $(dpkg -l 'libopenblas0*' 2>/dev/null | awk '/^ii/{print $2}' | tr '\n' ' ')"

say "F1 reference"
if $S reference "$D" >/tmp/o1 2>&1; then ok "setup exited 0"; else no "setup failed"; tail -15 /tmp/o1|sed 's/^/    /'; fi
r=$(readlink -f /usr/lib/x86_64-linux-gnu/libblas.so.3)
case "$r" in */blas/*) ok "blas -> reference";; *) no "blas -> $r";; esac

say "F2 openblas"
if $S openblas "$D" >/tmp/o2 2>&1; then ok "setup exited 0"; else no "setup failed"; tail -15 /tmp/o2|sed 's/^/    /'; fi
r=$(readlink -f /usr/lib/x86_64-linux-gnu/libopenblas.so.0)
case "$r" in *openblas-serial*) ok "libopenblas.so.0 -> serial (this is what -bo binds)";; *) no "-> $r";; esac
grep -q 'flavour: openblas' /etc/rcheck/flavour.txt && ok "manifest written" || no "no manifest"

if builds_here atlas; then
say "F3 atlas (fetch by URL + checksum + pin + hold)"
if $S atlas "$D" >/tmp/o3 2>&1; then ok "setup exited 0"; else no "setup failed"; tail -25 /tmp/o3|sed 's/^/    /'; fi
grep -q 'sha256 ok' /tmp/o3 && ok "checksums verified" || no "no checksum verification"
r=$(readlink -f /usr/lib/x86_64-linux-gnu/libblas.so.3);   case "$r" in */atlas/*) ok "blas -> atlas";; *) no "blas -> $r";; esac
r=$(readlink -f /usr/lib/x86_64-linux-gnu/liblapack.so.3); case "$r" in */atlas/*) ok "lapack -> atlas";; *) no "lapack -> $r";; esac
v=$(dpkg-query -W -f='${Version}' libatlas3-base 2>/dev/null)
[ "$v" = "3.10.3-13" ] && ok "real ATLAS installed ($v)" || no "got version '$v'"
apt-mark showhold | grep -q libatlas3-base && ok "held" || no "not held"
dpkg-query -W -f='${Status}' liblapacke 2>/dev/null | grep -q ' installed$' \
  && no "liblapacke still installed" || ok "liblapacke removed (it Breaks this ATLAS)"

say "F4 the pin survives an upgrade attempt"
apt-get update -qq 2>/dev/null
apt-get -s upgrade 2>/dev/null | grep -q 'libatlas3-base' && no "upgrade would touch atlas" || ok "upgrade leaves atlas alone"
[ "$(dpkg-query -W -f='${Version}' libatlas3-base)" = "3.10.3-13" ] && ok "still 3.10.3-13" || no "version changed"

say "F5 NEGATIVE: a tampered .deb must abort the build"
{ grep -v "^RCC_SYSDEB_SHA256=" "$D/atlas.env"; echo 'RCC_SYSDEB_SHA256="deadbeef deadbeef"'; } > /tmp/bad.env
mkdir -p /tmp/bad && cp /tmp/bad.env /tmp/bad/atlas.env
if $S atlas /tmp/bad >/tmp/o5 2>&1; then
  no "accepted a wrong checksum"
else
  grep -q 'checksum mismatch' /tmp/o5 && ok "rejected wrong checksum" || { no "failed but not on checksum"; tail -5 /tmp/o5|sed 's/^/    /'; }
fi
else
say "F3 to F5 skipped, atlas does not build on $SUITE"
mkdir -p /tmp/bad
fi

say "F6 NEGATIVE: arch gate"
sed 's/^RCC_ARCH=.*/RCC_ARCH=riscv64/' "$D/openblas.env" > /tmp/bad/openblas.env
if $S openblas /tmp/bad >/tmp/o6 2>&1; then no "built an arm for the wrong arch"; else
  grep -q 'riscv64-only' /tmp/o6 && ok "arch gate fired" || { no "failed for another reason"; tail -4 /tmp/o6|sed 's/^/    /'; }
fi

say "F7 blis (BLIS 2.1 and the reference LAPACK; from apt on testing, by URL + checksum + hold on stable)"
if $S blis "$D" >/tmp/o7 2>&1; then ok "setup exited 0"; else no "setup failed"; tail -25 /tmp/o7|sed 's/^/    /'; fi
if [ "$SUITE" = stable ]; then
  grep -q 'sha256 ok' /tmp/o7 && ok "checksums verified" || no "no checksum verification"
else
  grep -q 'fetch: ' /tmp/o7 && no "fetched a .deb by URL on testing" || ok "installed from apt"
fi
r=$(readlink -f /usr/lib/x86_64-linux-gnu/libblas.so.3);   case "$r" in */blis-serial/*) ok "blas -> blis";; *) no "blas -> $r";; esac
r=$(readlink -f /usr/lib/x86_64-linux-gnu/liblapack.so.3); case "$r" in */lapack/*) ok "lapack -> reference";; *) no "lapack -> $r";; esac
v=$(dpkg-query -W -f='${Version}' libblis4-serial 2>/dev/null)
if [ "$SUITE" = stable ]; then
  [ "$v" = "2.1-1" ] && ok "BLIS 2.1-1 installed" || no "got version '$v'"
  apt-mark showhold | grep -q libblis4-serial && ok "held" || no "not held"
else
  case "$v" in 2.*) ok "BLIS $v installed" ;; *) no "got version '$v'" ;; esac
  apt-mark showhold | grep -q libblis4-serial && no "held on testing" || ok "not held, so it follows testing"
fi

say "F8 mkl (Intel's apt repository and signing key)"
if $S mkl "$D" >/tmp/o8 2>&1; then ok "setup exited 0"; else no "setup failed"; tail -25 /tmp/o8|sed 's/^/    /'; fi
[ -s /etc/apt/sources.list.d/rcc-mkl.sources ] && ok "apt source written" || no "no apt source"
for l in libmkl_gf_lp64.so libmkl_core.so libmkl_sequential.so; do
  [ -e "/opt/intel/oneapi/mkl/2026.1/lib/$l" ] && ok "$l present" || no "$l missing"
done
[ -d /opt/intel/oneapi/mkl/2026.1/share/doc/mkl/licensing ] && ok "MKL license files present" || no "no MKL license files"
r=$(readlink -f /usr/lib/x86_64-linux-gnu/libblas.so.3); case "$r" in */blas/*) ok "alternatives back on reference";; *) no "blas -> $r";; esac
grep -q 'flavour: mkl' /etc/rcheck/flavour.txt && ok "manifest written" || no "no manifest"

say "F9 NEGATIVE: an arm refuses a suite it does not build on"
other=stable; [ "$SUITE" = stable ] && other=testing
sed "s/^RCC_SUITES=.*/RCC_SUITES=\"$other\"/" "$D/openblas.env" > /tmp/bad/openblas.env
if $S openblas /tmp/bad >/tmp/o9 2>&1; then no "set up an arm on a suite it does not name"; else
  grep -q "builds on Debian $other only" /tmp/o9 && ok "suite gate fired" || { no "failed for another reason"; tail -4 /tmp/o9|sed 's/^/    /'; }
fi
grep -q "^suite: $SUITE\$" /etc/rcheck/flavour.txt && ok "flavour.txt records the suite" || no "no suite in flavour.txt"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
