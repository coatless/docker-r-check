#!/bin/bash
set -u
export DEBIAN_FRONTEND=noninteractive
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
say(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }
S="sh /w/docker/flavour-setup.sh"
export RCC_WIRING=/w/docker/blas-wiring.sh
D=/w/flavours
apt-get update -qq 2>/dev/null
apt-get install -y -qq curl ca-certificates binutils >/dev/null 2>&1
# realistic base: pthread present via libsuperlu-dev's dependency
apt-get install -y -qq libsuperlu-dev >/dev/null 2>&1
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

say "F3 atlas (fetch by URL + checksum + pin + hold)"
if $S atlas "$D" >/tmp/o3 2>&1; then ok "setup exited 0"; else no "setup failed"; tail -25 /tmp/o3|sed 's/^/    /'; fi
grep -q 'sha256 ok' /tmp/o3 && ok "checksums verified" || no "no checksum verification"
r=$(readlink -f /usr/lib/x86_64-linux-gnu/libblas.so.3);   case "$r" in */atlas/*) ok "blas -> atlas";; *) no "blas -> $r";; esac
r=$(readlink -f /usr/lib/x86_64-linux-gnu/liblapack.so.3); case "$r" in */atlas/*) ok "lapack -> atlas";; *) no "lapack -> $r";; esac
v=$(dpkg-query -W -f='${Version}' libatlas3-base 2>/dev/null)
[ "$v" = "3.10.3-13" ] && ok "real ATLAS installed ($v)" || no "got version '$v'"
apt-mark showhold | grep -q libatlas3-base && ok "held" || no "not held"

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

say "F6 NEGATIVE: arch gate"
sed 's/^RCC_ARCH=.*/RCC_ARCH=riscv64/' "$D/openblas.env" > /tmp/bad/openblas.env
if $S openblas /tmp/bad >/tmp/o6 2>&1; then no "built an arm for the wrong arch"; else
  grep -q 'riscv64-only' /tmp/o6 && ok "arch gate fired" || { no "failed for another reason"; tail -4 /tmp/o6|sed 's/^/    /'; }
fi

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
