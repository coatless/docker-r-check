\name{rcheckcanary-package}
\alias{rcheckcanary-package}
\alias{rcheckcanary}
\docType{package}
\title{Deliberately Undefined Behaviour for Verifying Check Flavors}
\description{
  A test fixture. Its C code contains deliberate undefined behaviour so that a
  sanitizer or valgrind flavor can be shown to detect something. A flavor that
  reports this package clean is not instrumented.
}
\keyword{package}
