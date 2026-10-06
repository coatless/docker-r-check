#!/bin/bash
# assert-r-lto.sh against a stand-in for R, so this needs a C compiler and no
# R build. The stand-in answers RHOME and, for CMD SHLIB, compiles with the
# flags in FAKE_FLAGS, which lets a case pretend that the toolchain ignored
# -flto.
set -u
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
say(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
A="${RCC_ASSERT_LTO:-$ROOT/docker/assert-r-lto.sh}"
# Stop if the script under test is missing. Otherwise the cases that expect
# a failure would pass, because a missing script also fails.
[ -r "$A" ] || { echo "FATAL: not found: $A" >&2; exit 2; }

CC="${CC:-gcc}"
if ! command -v "$CC" >/dev/null 2>&1; then
    apt-get update -qq 2>/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gcc >/dev/null 2>&1
fi
command -v "$CC" >/dev/null 2>&1 || { echo "FATAL: no C compiler" >&2; exit 2; }

T="$(mktemp -d)"
mkdir -p "$T/flavours" "$T/home/etc"
printf 'RCC_RCONF_FLAGS="-bi --enable-lto AR=gcc-ar RANLIB=gcc-ranlib"\n' > "$T/flavours/with.env"
printf 'RCC_RCONF_FLAGS="-bi --disable-long-double"\n' > "$T/flavours/without.env"
cat > "$T/R" <<FAKE
#!/bin/sh
# R RHOME, or R CMD SHLIB -o <out> <sources>
if [ "\$1" = RHOME ]; then echo "$T/home"; exit 0; fi
shift 3; out="\$1"; shift
exec $CC -shared -fPIC \$FAKE_FLAGS -o "\$out" "\$@"
FAKE
chmod +x "$T/R"

# run <flavour> <the LTO line of Makeconf> <flags the compiler really gets>
run(){
    echo "LTO = $2" > "$T/home/etc/Makeconf"
    RCC_FLAVOURS="$T/flavours" FAKE_FLAGS="$3" sh "$A" "$1" "$T/R" >"$T/out" 2>&1
}

say "L1 an arm that does not ask for LTO is left alone"
if run without "" ""; then ok "exited 0"; else no "failed"; sed 's/^/    /' "$T/out"; fi
[ ! -s "$T/out" ] && ok "said nothing" || no "printed: $(head -n 1 "$T/out")"

say "L2 an LTO arm whose compiler does LTO"
if run with "-flto" "-flto"; then ok "exited 0"; else no "failed"; sed 's/^/    /' "$T/out"; fi
grep -q 'lto: -flto' "$T/out" && ok "reported the flags" || no "flags not reported"

say "L3 NEGATIVE: R was configured without LTO"
if run with "" "-flto"; then no "accepted an R with no LTO flags"; else ok "rejected"; fi
grep -q 'no LTO flags' "$T/out" && ok "said why" || no "message: $(tail -n 2 "$T/out")"

say "L4 NEGATIVE: the flags are recorded but the compiler did no LTO"
if run with "-flto" ""; then no "accepted a build without LTO"; else ok "rejected"; fi
grep -q 'did not report the type mismatch' "$T/out" && ok "said why" || no "message: $(tail -n 2 "$T/out")"

rm -rf "$T"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
