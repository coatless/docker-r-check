# Pick the kinds of CRAN check issues the arms cover out of check_issues.rds
# and write targets.tsv, one row per package and kind, with the arm that
# matches the kind and the local file names for CRAN's logs. The LTO targets
# also come from the directory that holds CRAN's LTO logs.
#
#   Rscript targets.R [check_issues.rds]
#
# KINDS in the environment limits the kinds, for example KINDS="MKL BLIS".

args <- commandArgs(trailingOnly = TRUE)
rds <- if (length(args)) args[[1]] else "check_issues.rds"

# donttest has no arm of its own. Its packages are checked in the reference
# arm with the \donttest examples switched on.
arms <- c(OpenBLAS = "openblas", MKL = "mkl", BLIS = "blis", ATLAS = "atlas",
          clang23 = "clang23", noLD = "nold", donttest = "donttest", LTO = "lto",
          "gcc-ASAN" = "gccsan", "gcc-UBSAN" = "gccsan",
          "clang-ASAN" = "clangsan", "clang-UBSAN" = "clangsan",
          valgrind = "valgrind", "linux-arm64" = "arm64",
          # No arm is built for these two. Their packages run in the image
          # that the check's own maintainer publishes.
          musl = "musl", rchk = "rchk")
kinds <- strsplit(Sys.getenv("KINDS", paste(names(arms), collapse = " ")), " +")[[1]]
x <- readRDS(rds)
x <- x[x$kind %in% intersect(names(arms), kinds), c("Package", "Version", "kind", "href")]

# CRAN lists an LTO issue only while the package is on CRAN. The logs of
# packages archived since stay in the LTO directory, so add those, each with
# the version that was on CRAN when its log was written. A recent log names
# its version. For an older one take the newest tarball in CRAN's archive
# that is not younger than the log.
lto_logs <- function(dir = "https://www.stats.ox.ac.uk/pub/bdr/LTO/") {
    page <- readLines(dir, warn = FALSE)
    m <- regmatches(page, regexec('href="([^"?/]+)[.]out".*?([0-9]{4}-[0-9]{2}-[0-9]{2})', page))
    m <- do.call(rbind, m[lengths(m) == 3L])
    archive <- readRDS(url("https://cran.r-project.org/src/contrib/Meta/archive.rds"))
    version <- mapply(function(pkg, day) {
        log <- readLines(paste0(dir, pkg, ".out"), warn = FALSE)
        said <- grep("^[*][*] this is package .* version ", log, value = TRUE)
        if (length(said))
            return(sub("^.* version [^0-9]*([0-9][0-9.-]*).*$", "\\1", said[[1L]]))
        a <- archive[[pkg]]
        a <- a[as.Date(a$mtime) <= as.Date(day), , drop = FALSE]
        if (!NROW(a)) return(NA_character_)
        sub("^.*_(.*)[.]tar[.]gz$", "\\1", rownames(a)[which.max(a$mtime)])
    }, m[, 2L], m[, 3L])
    if (anyNA(version))
        cat("no archived version for:", m[is.na(version), 2L], "\n")
    data.frame(Package = m[, 2L], Version = unname(version), kind = "LTO",
               href = paste0(dir, m[, 2L], ".out"))[!is.na(version), ]
}
if ("LTO" %in% kinds) {
    more <- lto_logs()
    x <- rbind(x, more[!more$Package %in% x$Package[x$kind == "LTO"], ])
}

# The arm64 checks link to a directory on GitHub. Its check log is this file.
x$href <- sub("^https://github.com/(r-devel/linux-arm64-checks)/tree/HEAD/(.*)$",
              "https://raw.githubusercontent.com/\\1/HEAD/\\2/00check.log", x$href)

# A package can have two rows, one for CRAN's check log (.out) and one for
# its install log (.log). Keep one row, preferring the check log, and carry
# the install log's address along.
is_install <- grepl("[.]log$", x$href)
key <- paste(x$kind, x$Package)
install <- tapply(ifelse(is_install, x$href, NA), key, function(v) v[!is.na(v)][1])
x <- x[order(x$kind, x$Package, is_install), ]
x <- x[!duplicated(paste(x$kind, x$Package)), ]
x$arm <- unname(arms[x$kind])
# Two kinds can share an arm, so their logs are named after the kind.
shared <- x$arm %in% names(which(table(arms) > 1))
x$log <- file.path("logs", paste0(ifelse(shared, x$kind, x$arm), "-", x$Package, ".out"))
x$install_href <- unname(install[paste(x$kind, x$Package)])
x$install_href[is.na(x$install_href)] <- "-"

write.table(x, "targets.tsv", sep = "\t", quote = FALSE, row.names = FALSE)
cat(sprintf("%d packages: %s\n", nrow(x),
            paste(names(table(x$kind)), table(x$kind), sep = " ", collapse = ", ")))
