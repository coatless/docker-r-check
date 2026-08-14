# Evaluation protocol

How to measure whether these containers actually reproduce CRAN's verdicts, and
what would make the resulting number meaningless.

This is a protocol, not a result. Nothing here has been run yet: no image in
this repository has been built, because the environment it was developed in has
no container runtime. The tooling the protocol depends on
(`tools/summarise-check.sh`, `tools/cran-compare.sh`) is implemented and tested
against fixtures; the measurement is not done.

## The question

For a package CRAN publishes an additional issue for, does the corresponding
container flavor find that issue? And for a package CRAN publishes nothing for,
does it stay quiet?

Both halves are needed. A flavor that flags everything scores perfectly on the
first and is useless; one that flags nothing scores perfectly on the second and
is worse than useless, because it looks like it works.

## Sampling

Draw from `tools::CRAN_check_issues()` — fetched into a CSV by
`tools/fetch-cran-issues.R` — stratified per flavor:

* **Known positives**: packages CRAN currently lists under that issue kind.
  Aim for 20–30 per flavor, or all of them if there are fewer.
* **Known negatives**: packages CRAN lists nothing for. Weight heavily toward
  compiled packages (C/C++/Fortran) — a pure-R package cannot exercise a
  sanitizer, so a sample full of them inflates the agreement rate with cases
  that were never at risk.
* **Historically flaky**: a handful known to fail intermittently, kept
  separate (see below).

100–200 packages in total across the Tier 1 flavors is the right order of
magnitude for a milestone-scale evaluation. `tools/cran-compare.sh` warns below
20 scored packages, and warns again if a sample contains no known positives at
all, because either makes the headline number meaningless.

## Hosts

The same pinned images, the same package set, on at least:

1. x86_64 Linux, Docker
2. x86_64 Linux, Podman rootless
3. arm64 Linux
4. macOS with Docker Desktop
5. A cluster with Apptainer, no root
6. GitHub Actions

Hosts 3 and 4 are where disagreement is most likely: arm64 has a different
instruction set, and Docker Desktop on Apple silicon runs a Linux VM whose CPU
is emulated for x86_64 images. Both are legitimate findings about the limits of
portability, not bugs to hide.

## Running it

Per flavor and host, with everything pinned:

```sh
bin/rcheck --snapshot 20260801T000000Z --p3m 2026-08-01 --r-svn-rev 90210 \
           build nold
bin/rcheck --snapshot 20260801T000000Z --p3m 2026-08-01 --r-svn-rev 90210 \
           --jobs 8 build-r nold
bin/rcheck --pkg-dir ./sample check nold
bin/rcheck summarise nold
bin/rcheck compare nold --issues cran-issues.csv
```

Run the **canary first**, on every host, before any real package:

```sh
tar czf sample/rcheckcanary_0.1.0.tar.gz -C tests/pkgs rcheckcanary
bin/rcheck check gcc-ubsan sample/rcheckcanary_0.1.0.tar.gz
bin/rcheck summarise gcc-ubsan     # must report ISSUE
```

If the canary comes back `OK` under an instrumented flavor, that host's
instrumentation is not live and every other result from it is worthless. This
takes minutes and invalidates entire runs, so it goes first.

Always run the `debian-gcc` control flavor over the same sample. It separates
"this package is broken" from "this package is broken *under this
instrumentation*", and only the second is what the additional checks are about.

## The metric

`tools/cran-compare.sh` classifies each package:

| | CRAN lists an issue | CRAN lists none |
|---|---|---|
| **we flag it** | `AGREE_ISSUE` | `EXTRA` |
| **we do not** | `MISSED` | `AGREE_CLEAR` |

plus `EXCLUDED` for `INCONCLUSIVE` runs.

```
agreement rate = (AGREE_ISSUE + AGREE_CLEAR) / (total - EXCLUDED)
```

Report per flavor **and** per host. A single aggregate number hides exactly the
variation the experiment exists to measure.

`EXTRA` and `MISSED` are not symmetric and must not be reported as if they
were:

* **`MISSED`** — CRAN sees it, we do not. A defect in this project. Every one
  needs a cause.
* **`EXTRA`** — we see it, CRAN does not. Could be a false positive; could
  equally be an issue fixed after our pinned snapshot, or one CRAN chose not to
  publish (the published list is filtered by human judgement). Investigate
  before calling it a false positive.

## Excluding rather than scoring

Some outcomes say nothing about agreement and must not be counted as it:

* **`INCONCLUSIVE`** — the flavor did not apply. Excluded automatically.
* **Flavor artefacts** — e.g. a package failing to link under `clang-asan`
  because a system library was built against libstdc++. Excluded manually,
  with the reason recorded.
* **Network failures** — likeliest under `donttest`, which by design runs the
  examples maintainers marked as too network-dependent for routine checking.

Every exclusion is a chance to flatter the result, so each one needs a written
reason and a count in the report. An evaluation that excludes half its sample
has not measured agreement, whatever the surviving fraction says.

## Flaky checks

Run the flaky subset N=5 times per host and report a stability score (the
fraction of runs agreeing with the modal verdict) rather than a single verdict.
Keep them out of the headline agreement rate and report them separately: a
package that gives three different answers on one host is a finding about the
package, and folding it into an average destroys that information.

## Reporting

The report should state, per flavor and host: sample size, the four
classification counts, exclusions with reasons, the agreement rate, and the
pins used (base digest, apt snapshot, R revision, P3M date). Without the pins
the numbers cannot be reproduced, which would be an odd way to end a
reproducibility project.
