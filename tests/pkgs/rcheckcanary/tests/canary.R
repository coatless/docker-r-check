library(rcheckcanary)

## Runs on every flavor. Under gcc-UBSAN or clang-UBSAN this line makes the
## sanitizer print a "runtime error: signed integer overflow" diagnostic --
## without changing the exit status, which is exactly why the result summariser
## scans the output instead of trusting Status:.
invisible(canary_overflow(.Machine$integer.max))

## Under ASAN this aborts the process and the check fails; under valgrind it is
## reported as an invalid read; on an uninstrumented build it silently returns
## whatever was in memory. Set RCHECKCANARY_OOB=0 to skip it when checking a
## flavor where an abort would be unhelpful.
if (!identical(Sys.getenv("RCHECKCANARY_OOB"), "0"))
    invisible(canary_oob_read())

cat("canary ran\n")
