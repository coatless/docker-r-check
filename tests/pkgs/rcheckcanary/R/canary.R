## Signed integer overflow. Undefined behaviour in C; detected by UBSAN.
canary_overflow <- function(x = .Machine$integer.max)
    .Call(C_canary_overflow, as.integer(x))

## Heap read past the end of an allocation. Detected by AddressSanitizer and by
## valgrind; on an uninstrumented build it reads whatever the allocator left
## there and returns it, which is the whole point -- the bug is invisible
## without instrumentation.
canary_oob_read <- function()
    .Call(C_canary_oob_read)
