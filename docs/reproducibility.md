# Reproducibility

The goal is that the same package, checked with the same flavor, gives the same
verdict on a laptop, a CI runner and a cluster — today and in a year.

Containers alone do not deliver that. A `Dockerfile` that says
`FROM debian:unstable` and `apt-get install` produces a different image every
day. This page lists what moves, what pins it, and what is still unpinned.

## The four moving targets

| What moves | Pinned by | Effect if unpinned |
|---|---|---|
| The base image behind a tag | `pins/base-images.tsv`, applied as `@sha256:...` | Rebuilding gives a different OS |
| The packages apt installs into it | `--snapshot` → `snapshot.debian.org` | Different compiler and libc versions |
| The R sources | `--r-svn-rev` | Different R, so different check behaviour |
| The CRAN package graph | `--p3m` → a P3M snapshot date | A dependency changes and the verdict flips |

A fully pinned run:

```sh
bin/rcheck \
  --snapshot 20260801T000000Z \
  --p3m 2026-08-01 \
  --r-svn-rev 90210 \
  run nold mypkg_1.0.tar.gz
```

Leave any of them out and `rcheck` says so on every invocation. That is
deliberate: an unpinned run is perfectly good for triaging a package now, and
worthless as evidence later, and the difference should not be silent.

## How each pin works

**Base image digest.** `tools/pin-images.sh` resolves every
`BASE_IMAGE:BASE_TAG` used by a flavor to its manifest digest and records it in
`pins/base-images.tsv`. `bin/rcheck build` passes it as `BASE_DIGEST_SUFFIX`, so
the `FROM` line resolves to an immutable image.

It talks to the registry API rather than using `docker pull`, so it runs on a
machine with no container runtime. Refreshing pins is a reviewable commit, never
something CI does on its own — the `pin-drift` job in `ci.yml` reports movement
and changes nothing.

**Apt snapshot.** `docker/apt-setup.sh` rewrites the sources to
`snapshot.debian.org/archive/debian/<stamp>/` and disables the
`Check-Valid-Until` test, which a frozen archive necessarily fails. That check
is the one apt guarantee knowingly traded away; signature verification is
unaffected.

This runs as the first step of the build, before `ca-certificates` exists,
which is why snapshot URLs are http. Integrity is unaffected — apt verifies the
archive signature against the Debian keyring either way — and doing it first is
what makes the pin govern every package in the image rather than only the ones
installed after the first layer.

**R sources.** `--r-svn-rev` passes `R_SVN_REV` into the container, and
`docker/entry-build-r.sh` uses it for both the initial checkout and the update.
The revision actually built is recorded in `/build/rcheck-build.json` via
`svnversion`, so a result can be attributed even if the flag was forgotten.

**R packages.** `--p3m` sets `P3M_SNAPSHOT`, and `entry-pkgcheck.sh` turns it
into `https://packagemanager.posit.co/cran/<date>` as the repository. P3M
snapshots go back to 2017-10-10. Without it, dependencies come from whatever
CRAN holds today, and a check that passes this week can fail next week for
reasons that have nothing to do with the package.

## What is still not pinned

Being explicit about this matters more than the list being short.

* **`rcheckserver` from `statmath.wu.ac.at/AASC/debian`.** Not a snapshot
  archive, so the version installed is whatever is current. See Q7.
* **Recommended packages.** The image runs `tools/rsync-recommended`, which
  fetches the recommended package tarballs matching the R sources at build
  time. Pinned in practice by `R_SVN_REV`, but not by a digest.
* **The CPU.** Numerical results depend on the instruction set — this is the
  point of the noLD check, and OpenBLAS reductions sum in thread-dependent
  order. `flavors/openblas.conf` pins `OPENBLAS_NUM_THREADS=1` for exactly this
  reason, and no flavor uses `-march=native` or `-mtune=native` (enforced by
  `tests/test-flavors.sh`). Some divergence across microarchitectures remains
  irreducible, which is why the evaluation protocol reports agreement per host
  rather than only in aggregate.
* **Build timestamps in the image.** Layers are not bit-reproducible;
  `SOURCE_DATE_EPOCH` and reproducible-builds handling of the image itself has
  not been done. The *contents* are pinned, which is what affects a check
  verdict; byte-identical images are a stronger property nothing here needs yet.
* **Time-dependent package behaviour.** A package whose tests depend on the
  current date will still diverge. That is a property of the package.

## Recording what a result came from

Every R build writes `/build/rcheck-build.json`: the full flavor definition, the
R and QA SVN revisions actually checked out, the build method, and the image's
own record of its base image, digest suffix, apt snapshot and components
(`/etc/rcheck/image.json`, written at image build time).

A result without that file is a result nobody can attribute. It is written
whenever a flavor is in use, not on request.
