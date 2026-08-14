\name{canary_overflow}
\alias{canary_overflow}
\alias{canary_oob_read}
\title{Trigger Undefined Behaviour on Purpose}
\usage{
canary_overflow(x = .Machine$integer.max)
canary_oob_read()
}
\arguments{
  \item{x}{integer; overflow occurs when it is \code{.Machine$integer.max}.}
}
\value{An integer, whose value is meaningless by construction.}
\description{
  \code{canary_overflow} performs signed integer overflow, which UBSAN reports.
  \code{canary_oob_read} reads one element past a heap allocation, which
  AddressSanitizer and valgrind report.
}
\examples{
## Not run on purpose: these functions are undefined behaviour by design.
\donttest{canary_overflow(1L)}
}
\keyword{internal}
