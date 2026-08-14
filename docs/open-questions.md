# Open questions

Things this repository currently guesses at, where a short answer from someone
on the CRAN team would replace a guess with a fact. They are written to be
answerable in a sentence or two each, because the people who can answer them
are the people with the least time.

Each question says what we do *today* in the absence of an answer, so that
nothing is blocked waiting for one. Flavor definitions and code reference these
by number.

---

## Q1 — Which checks are worth reproducing, and which are already served?

r-hub/containers already publishes daily images for most containerisable
additional checks. Duplicating them would be the main way this work could end
up worthless.

Which additional issue kinds would you actually use a container for, and which
do you consider adequately served already?

*Today:* we prioritise noLD, the four sanitizers, noSuggests and donttest
(Tier 1 in `docs/qa-improvement-plan.md`), on the assumption that memory and
numerical checks generate the most maintainer correspondence.

---

## Q2 — Does CRAN's clang-ASAN/UBSAN build use libc++ for package code?

`flavors/clang-asan.conf` and `flavors/clang-ubsan.conf` set
`-stdlib=libc++` on `CXX`, so that package C++ code is compiled against libc++
and not only R itself.

Is that what CRAN does? It is the single riskiest setting in those files: with
it, some packages fail to link against libstdc++-built system libraries and the
failure is a flavor artefact rather than a package bug; without it, clang-ASAN
becomes a near-duplicate of gcc-ASAN and most of its value disappears.

*Today:* libc++ is on, and a link failure of that shape is documented as
something to exclude from the agreement rate rather than count as a
disagreement.

---

## Q3 — On-demand per package, or integrated into the incoming pipeline?

Two quite different products:

* a maintainer or CRAN volunteer runs one package through one flavor on demand;
* the additional checks run as a stage of the incoming submission pipeline.

*Today:* built for the first. The second needs decisions about where results
go and who reads them that are not ours to make.

---

## Q4 — Does `check_CRAN_incoming` forward unknown options to `R CMD check`?

This is the one that blocks a working flavor.

Almost every flavor setting travels through a channel `R CMD check` reads
itself: `config.site` at build time and `~/.R/check.Renviron` at check time.
Those work regardless of how the surrounding driver script is invoked.

valgrind is the exception. `--use-valgrind` is a command line option with no
environment equivalent we know of, so `flavors/valgrind.conf` puts it in
`CHECK_EXTRA_ARGS` and `docker/entry-pkgcheck.sh` passes it to
`check_CRAN_incoming`. If that script does not forward unknown options, the
check runs happily *without valgrind* and reports OK — a clean bill of health
from a test that never ran.

Two things would help:

1. Does `check_CRAN_incoming` forward extra arguments to `R CMD check`?
2. For noSuggests, does it install suggested packages, and can that be turned
   off? `_R_CHECK_SUGGESTS_ONLY_` makes `R CMD check` behave correctly, but
   full fidelity also needs those packages absent from the library.

*Today:* rather than trust it, `tools/summarise-check.sh` looks for valgrind's
own output and reports `INCONCLUSIVE` when it is missing, so a silently
un-instrumented run can never be scored as agreement. That is a safety net,
not a fix.

---

## Q5 — How should the R sources be pinned?

`rcheck --r-svn-rev` pins the R checkout to an SVN revision, and the R package
graph is pinned separately to a Posit Public Package Manager snapshot date via
`--p3m`.

Is an SVN revision the right handle, or do you work from dated tarballs? And is
a P3M snapshot acceptable as the package source for a check whose verdict is
meant to be comparable with CRAN's, or does that itself introduce a difference?

*Today:* SVN revision plus P3M date, with `rcheck` warning on any run that
leaves either unset.

---

## Q6 — What result format is ingestible into your existing triage?

Every run writes `rcheck-result.json` per package and `rcheck-results.tsv` per
run, with a verdict of `ISSUE` / `OK` / `INCONCLUSIVE` alongside the raw
`R CMD check` status.

That shape was chosen to be diffable against `tools::CRAN_check_issues()`. If
your triage wants something else, the format is one script
(`tools/summarise-check.sh`) and is cheap to change.

---

## Q7 — Any constraints on where images may be published?

Two specific cases:

* The base images install `rcheckserver` from `statmath.wu.ac.at/AASC/debian`.
  Is redistributing an image containing it fine?
* `flavors/mkl.conf` needs Debian's `non-free` component. An MKL image is a
  licensing question, not a build question, which is why that flavor ships as
  `STATUS=planned` rather than as something that merely fails to build.

*Today:* nothing is published anywhere. Images are built locally by
`bin/rcheck`.

---

## Q8 — Is r-hub/containers an acceptable upstream to build on?

The reproducibility work here (digest pinning, apt snapshot pinning, dated
image tags) is largely orthogonal to what r-hub does and would apply to their
images too. Contributing it upstream would mean it stays maintained after this
milestone; keeping it separate means CRAN controls the stack.

*Today:* separate, building on the Debian and CRAN-QA-script approach already
in this repository, with no fork of r-hub.
