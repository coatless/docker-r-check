# Pick CRAN's current BLAS check issues out of check_issues.rds and write
# targets.tsv, one row per package and BLAS kind, with the arm that matches
# the kind and the local file name for CRAN's log.
#
#   Rscript targets.R [check_issues.rds]

args <- commandArgs(trailingOnly = TRUE)
rds <- if (length(args)) args[[1]] else "check_issues.rds"

arms <- c(OpenBLAS = "openblas", MKL = "mkl", BLIS = "blis", ATLAS = "atlas")
x <- readRDS(rds)
x <- x[x$kind %in% names(arms), c("Package", "Version", "kind", "href")]
x <- x[order(x$kind, x$Package), ]
x$arm <- unname(arms[x$kind])
x$log <- file.path("logs", paste0(x$arm, "-", x$Package, ".out"))

write.table(x, "targets.tsv", sep = "\t", quote = FALSE, row.names = FALSE)
cat(sprintf("%d rows: %s\n", nrow(x),
            paste(names(table(x$kind)), table(x$kind), sep = " ", collapse = ", ")))
