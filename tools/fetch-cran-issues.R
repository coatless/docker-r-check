#!/usr/bin/env Rscript
## Fetch CRAN's published "additional issues" table and write it as CSV.
##
## This is the ground truth `rcheck compare` is scored against: for each
## package, which additional issue kinds CRAN currently reports. tools ships
## the accessor, so there is no scraping and no HTML parsing here.
##
## Usage: fetch-cran-issues.R [out.csv]
##
## Two properties of the source are worth knowing before trusting a comparison
## made against it:
##
##  * It lists CURRENT issues only. A package CRAN flagged last month and whose
##    maintainer has since fixed it is simply absent, so a container run against
##    an older pinned snapshot can legitimately disagree.
##  * It reflects Ripley's filtering. Not every sanitizer report CRAN's machines
##    produce ends up published, so "we found something CRAN does not list" is
##    weaker evidence of a false positive than the reverse is of a false
##    negative.

args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) >= 1L) args[[1L]] else "cran-issues.csv"

if (!exists("CRAN_check_issues", envir = asNamespace("tools"))) {
    stop("tools::CRAN_check_issues() is not available in this R (needs a recent R); ",
         "cannot fetch CRAN's published additional issues", call. = FALSE)
}

issues <- tools::CRAN_check_issues()
issues <- as.data.frame(issues, stringsAsFactors = FALSE)

wanted <- c("Package", "Version", "Kind")
missing <- setdiff(wanted, names(issues))
if (length(missing)) {
    stop("unexpected columns from tools::CRAN_check_issues(): missing ",
         paste(missing, collapse = ", "), call. = FALSE)
}

issues <- issues[, wanted, drop = FALSE]
issues <- issues[order(issues$Package, issues$Kind), , drop = FALSE]

write.csv(issues, out, row.names = FALSE)

message(sprintf("wrote %s: %d issue rows, %d packages, %d distinct kinds",
                out, nrow(issues),
                length(unique(issues$Package)),
                length(unique(issues$Kind))))
