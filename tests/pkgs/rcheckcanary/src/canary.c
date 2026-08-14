/* Deliberate undefined behaviour, used to verify that a check flavor's
 * instrumentation is actually active.
 *
 * Both functions below are bugs on purpose. They are written so that an
 * optimising compiler cannot fold them away -- a constant-folded overflow
 * would produce no runtime diagnostic and the canary would silently stop
 * working, which is the one failure mode it exists to prevent.
 */

#include <R.h>
#include <Rinternals.h>
#include <stdlib.h>

/* Signed overflow: UBSAN reports "signed integer overflow". */
SEXP canary_overflow(SEXP x)
{
    volatile int v = INTEGER(x)[0];
    volatile int one = 1;
    int r = v + one;            /* UB when v == INT_MAX */
    return ScalarInteger(r);
}

/* Read one element past a heap allocation: ASAN reports
 * "heap-buffer-overflow", valgrind reports "Invalid read of size 4".
 * A read rather than a write, so that on an uninstrumented build it is
 * harmless in practice. */
SEXP canary_oob_read(void)
{
    int *p = (int *) malloc(4 * sizeof(int));
    volatile int seen;
    int i;
    if (p == NULL) error("allocation failed");
    for (i = 0; i < 4; i++) p[i] = i;
    seen = p[4];                /* one past the end */
    free(p);
    return ScalarInteger((int) seen);
}
