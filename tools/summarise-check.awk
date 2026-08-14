#!/usr/bin/awk -f
#
# Parse one R CMD check 00check.log into tab-separated records.
#
# Emitted records (first field is the record type):
#
#   package        <name>
#   version        <version>
#   status         OK | NOTE | WARNING | ERROR | INCOMPLETE
#   count          error|warning|note   <n>
#   check          <result>  <title>        (one per non-OK check)
#
# Kept separate from the surrounding shell driver so that it can be tested
# against fixture logs without a container, an R installation or a network --
# see tests/test-summarise.sh.
#
# Portability: no gawk extensions, and quoted values are extracted by replacing
# the quote characters with a sentinel rather than by counting offsets, because
# R writes directional quotes in UTF-8 and awk implementations disagree about
# whether substr() counts bytes or characters.

function unquote(line,   tmp, parts, n) {
    tmp = line
    gsub(/\xe2\x80\x98|\xe2\x80\x99|\xe2\x80\x9c|\xe2\x80\x9d|'|"/, "\001", tmp)
    n = split(tmp, parts, "\001")
    if (n < 2) return ""
    return parts[2]
}

function emit_pending(result) {
    if (pending == "") return
    if (result != "OK" && result != "SKIPPED")
        printf "check\t%s\t%s\n", result, pending
    pending = ""
}

BEGIN {
    pkg = ""; ver = ""
    nerr = 0; nwarn = 0; nnote = 0
    seen_status = 0
    pending = ""
}

## "* this is package 'foo' version '1.2-3'"
/^\* this is package / {
    pkg = unquote($0)
    tmp = $0
    sub(/^.*version /, "", tmp)
    ver = unquote(tmp)
    next
}

## Fallback for logs that lack the line above: "* using log directory '/x/foo.Rcheck'"
/^\* using log directory / {
    if (pkg == "") {
        dir = unquote($0)
        sub(/^.*\//, "", dir)
        sub(/\.Rcheck$/, "", dir)
        pkg = dir
    }
    next
}

## "* checking <title> ... <RESULT>", or "* checking <title> ..." with the
## result on a following line (which is how failing tests and examples appear).
/^\* checking / {
    emit_pending("ERROR")   ## a new check starting means the previous one never
                            ## reported; treat that as a failure rather than
                            ## silently dropping it
    line = $0
    title = line
    sub(/^\* checking /, "", title)

    if (match(line, /\.\.\.[ ]*(OK|NOTE|WARNING|ERROR|SKIPPED|INFO|NONE)[ ]*$/)) {
        result = substr(line, RSTART, RLENGTH)
        sub(/^\.\.\.[ ]*/, "", result)
        sub(/[ ]*$/, "", result)
        sub(/[ ]*\.\.\.[ ]*(OK|NOTE|WARNING|ERROR|SKIPPED|INFO|NONE)[ ]*$/, "", title)
        if (result != "OK" && result != "SKIPPED" && result != "INFO" && result != "NONE")
            printf "check\t%s\t%s\n", result, title
    } else if (line ~ /\.\.\.[ ]*$/) {
        sub(/[ ]*\.\.\.[ ]*$/, "", title)
        pending = title
    }
    next
}

## The deferred result of a multi-line check.
pending != "" && /^[ ]*(OK|NOTE|WARNING|ERROR|SKIPPED)[ ]*$/ {
    result = $0
    gsub(/[ ]/, "", result)
    emit_pending(result)
    next
}

## "Status: 1 ERROR, 2 NOTEs" / "Status: OK"
/^Status: / {
    seen_status = 1
    line = $0
    if (match(line, /[0-9]+ ERROR/))   { s = substr(line, RSTART, RLENGTH); sub(/ .*/, "", s); nerr  = s + 0 }
    if (match(line, /[0-9]+ WARNING/)) { s = substr(line, RSTART, RLENGTH); sub(/ .*/, "", s); nwarn = s + 0 }
    if (match(line, /[0-9]+ NOTE/))    { s = substr(line, RSTART, RLENGTH); sub(/ .*/, "", s); nnote = s + 0 }
    next
}

END {
    emit_pending("ERROR")

    if (pkg != "") printf "package\t%s\n", pkg
    if (ver != "") printf "version\t%s\n", ver

    if (!seen_status) {
        ## No Status: line means the check did not run to completion. That is
        ## materially different from a clean run and must not be reported as OK.
        status = "INCOMPLETE"
    } else if (nerr > 0) {
        status = "ERROR"
    } else if (nwarn > 0) {
        status = "WARNING"
    } else if (nnote > 0) {
        status = "NOTE"
    } else {
        status = "OK"
    }

    printf "status\t%s\n", status
    printf "count\terror\t%d\n", nerr
    printf "count\twarning\t%d\n", nwarn
    printf "count\tnote\t%d\n", nnote
}
