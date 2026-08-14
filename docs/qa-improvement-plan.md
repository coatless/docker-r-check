# Plan: containerising CRAN's additional checks

## The problem

CRAN's nightly checks run on 13 flavors. Separately, a layer of "additional
issues" catches memory-safety, numerical and compiler-strictness bugs that
ordinary checks cannot: sanitizers, valgrind, no-long-double, alternative BLAS,
static analysis. Almost all of them run on one person's Fedora hardware.

That layer is the least reproducible part of CRAN QA. A maintainer told their
package has a gcc-UBSAN issue usually cannot reproduce it, because reproducing
it means building an instrumented R first. Nor can most of the CRAN team.

The goal is a testing stage in portable isolation: a package can be run through
one of these checks on any ordinary machine, and get the verdict CRAN would
give.

## What "reproducible" has to mean here

Two properties, and the second is the harder one:

1. **Same result on any host.** A laptop, a CI runner and a cluster agree.
2. **Same result at any time.** A rerun in a year gives the same answer, or
   says why it cannot.

The second fails silently by default: `FROM debian:unstable` and `apt-get
install` name different software every day, and CRAN's package graph changes
daily. `docs/reproducibility.md` lists the four things that move and how each
is pinned; `bin/rcheck` warns on any run that leaves one unpinned rather than
letting the distinction go unnoticed.

## Scope

Tiered by value × feasibility. Tier assignments live in the flavor files
themselves, so `bin/rcheck flavors` is always the current answer.

**Tier 1 — implemented.** `noLD`, `gcc-ASAN`, `gcc-UBSAN`, `clang-ASAN`,
`clang-UBSAN`, `noSuggests`, `donttest`, plus a `debian-gcc` control flavor.
These generate most maintainer correspondence and are all containerisable.

**Tier 2 — implemented, lower confidence.** `valgrind` (feasible per package,
too slow for a sweep, and dependent on Q4), `OpenBLAS`.

**Tier 3 — declared, not recommended.** `ATLAS` (r-hub found an Ubuntu build
did not reproduce CRAN's ATLAS issues; Debian is unlikely to differ), `MKL`
(needs Debian non-free, and CRAN uses Intel's oneAPI distribution instead).

**Reuse, do not rebuild.** `rchk`/`rcnst`/`rlibro` — kalibera/rchk already
ships a working image and needs a specific LLVM and a bitcode build of R. The
effort-to-value ratio is the worst of any check and the prior art is good.

**Out of scope, permanently.** macOS/M1mac and Windows. See ADR-0008.

## Status

Implemented and covered by 190 tests that need no container runtime:

* Twelve flavor definitions covering Tier 1–3, each recording the CRAN issue
  kind it reproduces, the OS CRAN actually uses, and its own fidelity gaps.
* `bin/rcheck` — one command from tarball to verdict, over Docker, Podman or
  Apptainer.
* Pinning of base image digest, apt snapshot, R source revision and R package
  snapshot, with a warning whenever a run is not fully pinned.
* Result summarising that does not trust the `R CMD check` status line, because
  a sanitizer finding does not change it.
* Scoring against `tools::CRAN_check_issues()` with an explicit `INCONCLUSIVE`
  class, so a run that tested nothing cannot be scored as agreement.
* A canary package with deliberate undefined behaviour, and a CI job that fails
  if an instrumented flavor reports it clean.

**Not done, and the honest gap:** no image in this repository has been built.
The development environment has no container runtime, so every flavor except
the two inherited unchanged from the upstream scaffold is marked
`STATUS=experimental`, and `rcheck` says so before each run. The compiler flag
sets are drawn from the R-admin manual and are plausible; they are not
validated against CRAN's actual configuration. The `images` workflow performs
that validation on a real runner.

Also not done: the cross-host agreement experiment
(`docs/evaluation-protocol.md` is the protocol, not a result), the Fedora
family (ADR-0005), and publishing images anywhere (Q7).

## Sequence from here

1. **Run `.github/workflows/images.yml`.** The canary job is the gate: if
   `gcc-ubsan` reports the canary clean, the instrumentation is not live and
   nothing else matters. Everything downstream depends on this.
2. **Answer Q4** (`docs/open-questions.md`). It decides whether the valgrind
   flavor works at all and whether noSuggests is faithful at the library level.
3. **Promote flavors from `experimental` to `implemented`** as each is
   validated against a package CRAN publishes a known issue for. `STATUS` is
   a claim about evidence, not about whether the code runs.
4. **Fedora family** for the checks CRAN runs on Fedora — the largest
   remaining fidelity gap, and the one that most affects whether an agreement
   rate is worth publishing.
5. **Run the evaluation** across the six hosts and report per flavor and host.
6. **Publish images**, once Q7 is answered, tagged by snapshot date and not
   only `latest`, so a result stays reproducible after the next rebuild.

## What would make this work worthless

Worth stating plainly, because it is the main risk:

**Duplicating r-hub/containers.** It already publishes daily-built images for
nearly every containerisable additional check, maintained by the R Consortium
and Posit. Rebuilding that is effort spent on something that exists.

The distinctive contribution here is not image coverage. It is:

* using CRAN's own QA scripts rather than a reimplementation of the check;
* pinning for reproducibility over *time*, which daily-rebuilt images by
  construction cannot offer;
* measuring agreement with CRAN rather than assuming it, including the
  discipline that a run which tested nothing is not agreement;
* rootless/Apptainer delivery for cluster hosts.

Each of those would apply equally to r-hub's images. If they would take it,
contributing the pinning work upstream is a better outcome for CRAN than a
second stack — see Q8.
