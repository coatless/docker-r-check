# Pick the kinds of CRAN check issues the arms cover out of check_issues.rds
# and write targets.tsv, one row per package and kind, with the arm that
# matches the kind and the local file names for CRAN's logs.
#
#   Rscript targets.R [check_issues.rds]
#
# KINDS in the environment limits the kinds, for example KINDS="MKL BLIS".

args <- commandArgs(trailingOnly = TRUE)
rds <- if (length(args)) args[[1]] else "check_issues.rds"

# donttest has no arm of its own. Its packages are checked in the reference
# arm with the \donttest examples switched on.
arms <- c(OpenBLAS = "openblas", MKL = "mkl", BLIS = "blis", ATLAS = "atlas",
          clang23 = "clang23", noLD = "nold", donttest = "donttest")
kinds <- strsplit(Sys.getenv("KINDS", paste(names(arms), collapse = " ")), " +")[[1]]
x <- readRDS(rds)
x <- x[x$kind %in% intersect(names(arms), kinds), c("Package", "Version", "kind", "href")]

# A package can have two rows, one for CRAN's check log (.out) and one for
# its install log (.log). Keep one row, preferring the check log, and carry
# the install log's address along.
is_install <- grepl("[.]log$", x$href)
key <- paste(x$kind, x$Package)
install <- tapply(ifelse(is_install, x$href, NA), key, function(v) v[!is.na(v)][1])
x <- x[order(x$kind, x$Package, is_install), ]
x <- x[!duplicated(paste(x$kind, x$Package)), ]
x$arm <- unname(arms[x$kind])
x$log <- file.path("logs", paste0(x$arm, "-", x$Package, ".out"))
x$install_href <- unname(install[paste(x$kind, x$Package)])
x$install_href[is.na(x$install_href)] <- "-"

write.table(x, "targets.tsv", sep = "\t", quote = FALSE, row.names = FALSE)
cat(sprintf("%d packages: %s\n", nrow(x),
            paste(names(table(x$kind)), table(x$kind), sep = " ", collapse = ", ")))
