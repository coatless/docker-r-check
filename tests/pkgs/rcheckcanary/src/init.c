#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

extern SEXP canary_overflow(SEXP);
extern SEXP canary_oob_read(void);

static const R_CallMethodDef CallEntries[] = {
    {"C_canary_overflow", (DL_FUNC) &canary_overflow, 1},
    {"C_canary_oob_read", (DL_FUNC) &canary_oob_read, 0},
    {NULL, NULL, 0}
};

void R_init_rcheckcanary(DllInfo *dll)
{
    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
}
