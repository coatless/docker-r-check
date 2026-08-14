# Architecture and decision record

What this repository is, and why each load-bearing choice was made. Decisions
are recorded rather than merely implemented so that a later maintainer can tell
a deliberate constraint from an accident.

## Shape

```
bin/rcheck              one command; everything below is reachable through it
flavors/*.conf          one file per check configuration; the whole contract
docker/Dockerfile       base -> build-r -> pkgcheck, unchanged in shape
docker/lib/flavor.sh    loads a flavor; used on the host AND in the container
docker/entry-*.sh       container entrypoints, flavor-aware
tools/                  pinning, result summarising, scoring against CRAN
pins/base-images.tsv    immutable base image digests
tests/                  runs with no container runtime, no R, no network
```

The data flow for one package:

```
flavors/nold.conf
   |
   |  base image + digest + sysdeps            (build time)
   v
docker build  ->  rchk-build-r:nold, rchk-pkgcheck:nold
   |
   |  CC/CXX/configure args via config.site    (R build time)
   v
entry-build-r.sh  ->  /build/bin/R  +  /build/rcheck-build.json
   |
   |  _R_CHECK_* via ~/.R/check.Renviron       (check time)
   |  ASAN_OPTIONS etc. via the environment
   v
entry-pkgcheck.sh  ->  check_CRAN_incoming  ->  *.Rcheck/
   |
   v
summarise-check.sh  ->  rcheck-result.json, rcheck-results.tsv
   |
   v
cran-compare.sh  ->  agreement rate against tools::CRAN_check_issues()
```

The flavor file is the only place a check configuration is written down. It is
read at three different times by two different machines, which is why the
loader is a single shared file rather than duplicated logic.

---

## ADR-0001 — OCI images, run by Docker, Podman or Apptainer

**Decision.** Build OCI images; support `docker` and `podman` interchangeably,
and `apptainer` for running an already-built image.

**Why.** The realistic hosts for this are a maintainer's laptop, a CI runner
and a university cluster. The first two have Docker or Podman; the third
usually forbids a root daemon outright, and Apptainer is the standard there.
Building OCI and running it rootless covers all three without a second image
format.

Podman is a genuine drop-in — same arguments, different binary. Apptainer is
not: it does not run image entrypoints, it mounts the host home directory by
default, and it cannot build these images. `bin/rcheck` therefore invokes the
entrypoint script explicitly and redirects `$HOME` into the build directory
(without which the container would create symlinks in the user's real home
that only resolve inside the container). Apptainer support is written but has
not been exercised on a real cluster.

**Rejected.** A Nix or Guix derivation would give stronger reproducibility than
any container: the whole dependency closure is content-addressed rather than
pinned by convention. But CRAN's checks are defined in terms of specific Debian
and Fedora toolchains, and the goal here is to agree with CRAN's verdict, not
to build the most reproducible R. A Nix rebuild is a different artefact, not a
more reproducible version of the same one.

---

## ADR-0002 — Build on this repository's Debian + CRAN QA script approach

**Decision.** Extend the existing scaffold rather than start from
r-hub/containers.

**Why.** The most valuable thing already here is easy to miss: the check is not
`check_packages_in_dir()`, it is CRAN's *own* QA scripts — `build-R` and
`check_CRAN_incoming`, checked out from
`svn.r-project.org/R-dev-web/trunk/CRAN/QA/Kurt`. That is a much shorter path
to "the same check CRAN runs" than any reimplementation, and it is the property
that distinguishes this from a generic check container.

(The `README` in the initial commit describes `check_packages_in_dir()`; the
final commit, "use CRAN scripts for checks", replaced it and the README was not
updated. Anyone planning from the README alone will plan the wrong thing.)

**Consequence.** We inherit a dependency on scripts we cannot read from outside
the image, which is where Q4 in `docs/open-questions.md` comes from.

---

## ADR-0003 — Two ways to build R, chosen per flavor

**Decision.** `R_BUILD_METHOD` is either `cran-qa` (CRAN's `build-R`) or
`configure` (our own `./configure && make`).

**Why.** `build-R` is higher fidelity — it is literally what CRAN runs — but it
drives its own `configure` invocation, so a flavor that must control the
compiler driver or pass a configure option cannot go through it. noLD needs
`--disable-long-double`; every sanitizer needs `-fsanitize=...` baked into `CC`
and `CXX`.

Forcing one method would mean either giving up the sanitizers or giving up
CRAN's build script for the flavors that do not need to override anything.
Neither is worth it, and the cost of both is one `case` statement.

The failure mode this creates — a flavor that sets `CC` but asks for `cran-qa`,
and therefore silently builds an uninstrumented R — is caught by
`tests/test-flavors.sh`, not left to review.

---

## ADR-0004 — Configure flavors through channels R reads natively

**Decision.** Build-time settings go through `config.site` (`CONFIG_SITE`);
check-time settings go through `~/.R/check.Renviron`. Command line arguments to
the check driver are the last resort.

**Why.** `R CMD check` reads `check.Renviron` itself, and `configure` reads
`CONFIG_SITE` itself. Settings delivered that way work no matter how the
surrounding CRAN QA script chooses to invoke them, and they keep working if
that script changes. An extra command line argument only works if the driver
forwards it, which we cannot currently verify (Q4).

Exactly one flavor is forced onto the fragile channel — valgrind, whose
`--use-valgrind` has no environment equivalent — and that is precisely the
flavor whose results are treated as `INCONCLUSIVE` unless valgrind's own output
is found (ADR-0007).

Sanitizer flags go in `CC`/`CXX` rather than `CFLAGS`/`CXXFLAGS`, deliberately:
R records the compiler command at configure time and `R CMD INSTALL` reuses it,
so a package that overrides `CFLAGS` in its own `Makevars` — most compiled
packages of any size — would otherwise drop the instrumentation silently.

---

## ADR-0005 — Debian family only; Fedora is a declared gap

**Decision.** `BASE_FAMILY` exists in the schema with values `debian` and
`fedora`; only `debian` is implemented, and loading a `fedora` flavor is a hard
error rather than a silent fallback.

**Why.** CRAN runs gcc-ASAN, gcc-UBSAN, valgrind, noSuggests and the BLAS
checks on Fedora. This repository is Debian, so every one of those flavors has
a real fidelity gap, recorded in its `NOTES` rather than glossed.

There is direct evidence this matters: the r-hub project documents that an
ATLAS build on Ubuntu did not reproduce CRAN's ATLAS issues and that they moved
to Fedora to get agreement. `flavors/atlas.conf` is Tier 3 for that reason.

Building a second OS family is a substantial piece of work — a second base
stage, Fedora equivalents of `build-dep r-base`, and no `snapshot.debian.org`
equivalent for pinning. Declaring the gap in the schema keeps the flavor format
stable for whoever does it.

---

## ADR-0006 — Pin four things, and say so when they are not pinned

**Decision.** Base image digest, apt archive snapshot, R source revision and
R package snapshot are all pinnable, and `rcheck` warns on every run that
leaves any of them unset.

**Why.** "Reproducible regardless of where it is executed" fails for four
independent reasons, and fixing three of them is not much better than fixing
none. See `docs/reproducibility.md` for what each one pins and what remains
unpinned.

The warning matters as much as the mechanism. An unpinned run is still useful
for triaging a package today; it is just not evidence of anything six months
from now, and the tool should say which kind of run you are doing rather than
let you assume the better one.

---

## ADR-0007 — A verdict is ISSUE, OK or INCONCLUSIVE

**Decision.** Results carry a verdict distinct from the `R CMD check` status,
with a third value for "this run tested nothing".

**Why.** Two failure modes make the naive reading wrong in opposite directions.

A UBSAN finding does not change the exit status: the sanitizer prints
`runtime error:` to stderr and the check reports `Status: OK`. Reading the
status alone would report agreement with CRAN while detecting nothing. So the
summariser scans the whole `.Rcheck` tree for the instrumentation's own output.

And if `--use-valgrind` never reaches `R CMD check`, the run also reports OK —
indistinguishable from "valgrind ran and found nothing" unless you look for
valgrind's output. Folding that into `OK` would inflate the agreement rate with
runs that tested nothing, so it is `INCONCLUSIVE` and excluded from the
denominator.

`tests/pkgs/rcheckcanary` exists for the same reason from the other direction:
a package with deliberate undefined behaviour that an instrumented flavor must
flag. If it comes back clean, the instrumentation is not live. That assertion
is what the `canary` job in `.github/workflows/images.yml` enforces.

---

## ADR-0008 — macOS and Windows are out of scope

**Decision.** No M1mac, no Windows flavors, and none planned.

**Why.** macOS cannot be containerised portably at all: Apple's licence permits
virtualisation only on Apple hardware and there is no macOS container analogous
to a Linux one. Delivering "portable isolation" for M1mac would mean
orchestrating VMs on Apple silicon, which is a different project.

Windows containers run only on Windows hosts, so they are not portable to the
Linux and macOS hosts this is meant to serve, and win-builder already covers
that ground.

Stating this is part of the deliverable: a reader comparing this repository
against CRAN's list of issue kinds should find a reason, not a gap.
