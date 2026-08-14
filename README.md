# docker-r-check

Containers for reproducing CRAN's
[additional issue checks](https://cran.r-project.org/web/checks/check_issue_kinds.html)
— the sanitizer, valgrind, no-long-double and BLAS checks that ordinary
`R CMD check` does not perform, and that most people cannot reproduce because
reproducing them means building an instrumented R first.

Inside the container the check is run by CRAN's own QA scripts (`build-R` and
`check_CRAN_incoming`, from the R-dev-web SVN tree), not by a reimplementation.

```sh
bin/rcheck run nold mypkg_1.0.tar.gz
```

builds the image, builds R the way the `noLD` flavor needs it, checks the
package, and writes a verdict you can diff against what CRAN publishes.

> **Status.** Working code, unvalidated configurations. No image here has been
> built yet — the environment this was developed in has no container runtime —
> so most flavors are marked `experimental` and `rcheck` tells you so before it
> runs one. The compiler flag sets come from the R-admin manual; they have not
> been checked against CRAN's actual setup. See
> [docs/qa-improvement-plan.md](docs/qa-improvement-plan.md) for what is done
> and what is not.

## Getting started

```sh
bin/rcheck flavors                # what can be checked
bin/rcheck describe gcc-ubsan     # exactly how, and how it differs from CRAN
bin/rcheck run gcc-ubsan pkg_1.0.tar.gz
```

`run` is `build` + `build-r` + `check`. On a real machine you want them
separate, because building R takes a while and one build serves many packages:

```sh
bin/rcheck build gcc-ubsan
bin/rcheck --jobs 16 build-r gcc-ubsan
bin/rcheck check gcc-ubsan pkg_1.0.tar.gz other_2.1.tar.gz
bin/rcheck summarise gcc-ubsan
```

Needs Docker or Podman (`--runtime podman`). Apptainer can run an already-built
image (`--runtime apptainer --image ...`) but cannot build one.

## Reading a result

Each checked package gets an `rcheck-result.json` next to its `.Rcheck`
directory, and each run gets an `rcheck-results.tsv`:

```
package  verdict       status
mypkg    ISSUE         OK
```

`verdict` and `status` disagreeing like that is normal and is the reason the
verdict exists. UBSAN prints its findings to stderr and lets the check finish,
so `R CMD check` says `OK` while the sanitizer has found a real bug. Reading
the status line alone would report a clean package.

Three verdicts:

| | |
|---|---|
| `ISSUE` | this flavor found something CRAN would list |
| `OK` | it did not |
| `INCONCLUSIVE` | the flavor did not actually apply — nothing was tested |

`INCONCLUSIVE` is never folded into `OK`. A valgrind run where valgrind never
started looks exactly like a clean one unless you check, and scoring it as
agreement would be scoring a test that did not run.

To score results against CRAN:

```sh
Rscript tools/fetch-cran-issues.R cran-issues.csv
bin/rcheck compare gcc-ubsan --issues cran-issues.csv
```

## Reproducibility

A container is not automatically reproducible. `debian:unstable` means
something different every day, and so does CRAN. Four things need pinning:

```sh
bin/rcheck --snapshot 20260801T000000Z \  # apt, via snapshot.debian.org
           --p3m 2026-08-01 \             # the R package graph, via P3M
           --r-svn-rev 90210 \            # the R sources
           run nold mypkg_1.0.tar.gz      # base image digest: pins/base-images.tsv
```

Any run missing one of these still works and still gives a valid verdict — it
just cannot be reproduced later, and `rcheck` says so rather than letting you
assume otherwise. [docs/reproducibility.md](docs/reproducibility.md) covers what
each pin does and what remains unpinned.

## Adding or changing a flavor

Everything about a check lives in one file, `flavors/<id>.conf`, described by
[`flavors/SCHEMA`](flavors/SCHEMA). Copy the nearest existing one, edit, then:

```sh
bin/rcheck lint
tests/run-tests.sh
```

The tests enforce more than syntax. A flavor that sets `CC` but asks for CRAN's
`build-R` script — which would silently build an *uninstrumented* R and then
agree with CRAN on every clean package — fails the suite, as does a flavor
using `-march=native`, or one whose notes do not say how it differs from CRAN.

Flavors are bind-mounted into the container, so editing one takes effect
without rebuilding the image.

## Is the instrumentation actually working?

The failure mode that matters is a sanitizer flavor that builds, runs, and
detects nothing — it agrees with CRAN on every clean package and looks healthy.

`tests/pkgs/rcheckcanary` is a package containing deliberate undefined
behaviour. An instrumented flavor must flag it:

```sh
tar czf /tmp/rcheckcanary_0.1.0.tar.gz -C tests/pkgs rcheckcanary
bin/rcheck run gcc-ubsan /tmp/rcheckcanary_0.1.0.tar.gz
bin/rcheck summarise gcc-ubsan     # must be ISSUE, not OK
```

Run this first on any new host. The `canary` job in
`.github/workflows/images.yml` enforces it in CI.

## Tests

```sh
tests/run-tests.sh
```

190 tests, no container runtime, no R and no network needed. They cover the
flavor definitions, the check-log parser, the CRAN scoring arithmetic and the
CLI's container invocations (via `--dry-run`). What they cannot tell you is
whether the images build or whether a flavor agrees with CRAN — that needs
`.github/workflows/images.yml` and
[docs/evaluation-protocol.md](docs/evaluation-protocol.md).

## Documentation

| | |
|---|---|
| [qa-improvement-plan.md](docs/qa-improvement-plan.md) | scope, tiers, status, what would make this work worthless |
| [architecture.md](docs/architecture.md) | design and the decision record |
| [reproducibility.md](docs/reproducibility.md) | what moves, what pins it, what is still unpinned |
| [evaluation-protocol.md](docs/evaluation-protocol.md) | how to measure agreement with CRAN |
| [open-questions.md](docs/open-questions.md) | what we currently guess at |

## The original scripts

`build-images.sh`, `build-R.sh` and `chk-pkgs.sh` still work as before:

```sh
./build-images.sh unstable openblas libopenblas-dev
./build-R.sh unstable openblas -bo
( mkdir -p build/pkg && cd build/pkg && curl -LO https://rforge.net/Cairo/snapshot/Cairo_1.7-1.tar.gz )
./chk-pkgs.sh unstable openblas
```

They take a Debian tag and a free-form sysdeps string rather than a flavor
name; `bin/rcheck` is the same thing driven from a checked-in definition, with
digest pinning and machine-readable results. The Docker build context is now
the repository root (the image carries `flavors/` and `tools/`), which is the
only change to how they are invoked.

The `docker/Dockerfile` targets are unchanged in shape:

* **`base`** — Debian plus `rcheckserver` and R's build dependencies.
* **`build-r`** — adds the build user and the R/QA SVN checkouts; the
  entrypoint builds R into `/build`.
* **`pkgcheck`** — adds the check entrypoint.

Both `build-r` and `pkgcheck` accept `RCHECK_FLAVOR` at run time; without it
they behave exactly as they did before flavors existed.
