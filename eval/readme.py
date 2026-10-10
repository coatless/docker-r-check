#!/usr/bin/env python3
"""Write the results of a run into README.md.

    readme.py <rows.tsv> <run.txt> <README.md> <state.tsv> [<run-url>]

<rows.tsv> is what `report.py --rows` wrote and <run.txt> what the targets
job wrote. The text between the two marker comments in <README.md> is
replaced with a table of the results, one row per package and list.
<state.tsv> keeps each job's verdicts from one run to the next, so that the
README can say what has changed since the run before. The new text is also
printed.
"""
import csv
import email.utils
import os
import re
import sys
import textwrap

START = "<!-- daily results, rewritten by the evaluate workflow: start -->"
END = "<!-- daily results: end -->"
# Lists come in this order, then any others by name.
ORDER = ["OpenBLAS", "MKL", "BLIS", "ATLAS", "clang23", "noLD"]
# A list longer than this gets one row of counts, not a row per package.
LONG = 15
# Verdicts from the best match with CRAN to the worst.
RANK = ["reproduced", "same step, different result", "partly reproduced", "different problem",
        "not reproduced", "check did not finish", "not checked"]
UNCHECKED = ("not checked", "check did not finish")


def dcf(path):
    out = {}
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            if ": " in line:
                k, v = line.rstrip("\n").split(": ", 1)
                out.setdefault(k, v)
    except OSError:
        pass
    return out


def base(verdict):
    """A verdict without what it says about the reference arm."""
    return re.split(", (?:all|part) of it|, but ", verdict)[0]


def rank(verdict):
    b = base(verdict)
    return RANK.index(b) if b in RANK else len(RANK)


def listed(names, code=True):
    """Names as "a, b and c"."""
    names = [f"`{n}`" if code else n for n in names]
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]


def collapse(rows):
    """One entry per list and package, and the jobs that gave no result at all.

    A package that several jobs check, as on the BLIS list, gets each
    verdict once with the jobs that gave it.
    """
    jobs = sorted({r["job"] for r in rows})
    silent = [j for j in jobs if all(r["verdict"] in UNCHECKED for r in rows if r["job"] == j)]
    entries = {}
    for r in rows:
        e = entries.setdefault((r["kind"], r["package"]),
                               {"version": r["version"], "cran": r["cran"], "by": {}, "jobs": {}})
        e["jobs"][r["job"]] = r["verdict"]
        # A job with no results says nothing about a package other jobs checked.
        if r["job"] in silent and len(jobs) > len(silent):
            e.setdefault("silent", r["verdict"])
            continue
        e["by"].setdefault(r["verdict"], []).append(r["job"])
    for e in entries.values():
        groups = sorted(e["by"].items(), key=lambda g: rank(g[0])) or [(e.get("silent", "not checked"), [])]
        e["first"] = base(groups[0][0])
        if len(groups) == 1:
            e["shown"] = groups[0][0]
        else:
            e["shown"] = "<br>".join(f"{v} ({', '.join(f'`{x}`' for x in j)})" for v, j in groups)
    return entries, silent


def read_state(path):
    """Each job's verdicts in the run before and that run's date, or nothing on the first run."""
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return {}, None
    m = re.match(r"# run of (\S+)", lines[0]) if lines else None
    old = {}
    for r in csv.DictReader([l for l in lines if not l.startswith("#")], delimiter="\t"):
        old.setdefault((r["kind"], r["package"]), {})[r["job"]] = r["verdict"]
    return old, m.group(1) if m else None


def write_state(path, entries, date):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(f"# run of {date}\n")
        w = csv.writer(f, delimiter="\t", lineterminator="\n")
        w.writerow(["kind", "package", "version", "job", "cran", "verdict"])
        for (kind, pkg), e in entries.items():
            w.writerows([kind, pkg, e["version"], job, e["cran"], v] for job, v in e["jobs"].items())


def changes(old, new):
    """A line for each entry that joined a list, left it or changed its verdict.

    Verdicts are compared job by job, and only where the job checked the
    package in both runs. The skx jobs run on some days and not on others,
    and that alone is not a change.
    """
    out = []
    for (kind, pkg), e in new.items():
        was = old.get((kind, pkg))
        if was is None:
            out.append(f"`{pkg}` joined the {kind} list.")
            continue
        moved = {}
        for job, v in e["jobs"].items():
            before = was.get(job)
            if before and before != v and base(before) not in UNCHECKED and base(v) not in UNCHECKED:
                moved.setdefault((before, v), []).append(job)
        for (before, v), jobs in moved.items():
            where = "" if len(e["jobs"]) == 1 else f" in {listed(jobs)}"
            out.append(f"`{pkg}` on the {kind} list went from \"{before}\" to \"{v}\"{where}.")
    out += [f"`{pkg}` left the {kind} list." for kind, pkg in old if (kind, pkg) not in new]
    return out


def section(entries, silent, run, old, old_date, url):
    kinds = run.get("Kinds", "").split() or sorted({k for k, _ in entries})
    kinds.sort(key=lambda k: (ORDER.index(k) if k in ORDER else len(ORDER), k))
    date = run.get("Fetched", "")[:10]
    try:
        when = email.utils.parsedate_to_datetime(run["check_issues-Last-Modified"])
        as_of = when.strftime("%Y-%m-%d %H:%M GMT")
    except (KeyError, TypeError, ValueError):
        as_of = date
    the_run = f"[run of {date}][daily-run]" if url else f"run of {date}"
    # Wrapped like the rest of README.md. A link is never split.
    para = lambda s: textwrap.fill(s, 78, break_long_words=False, break_on_hyphens=False)
    out = [START,
           para(f"The evaluate workflow repeats this comparison for CRAN's {listed(kinds, code=False)} "
                f"{'list' if len(kinds) == 1 else 'lists'} and rewrites this section. It is set to run every day. "
                f"The {the_run} used R-devel r{run.get('R-revision', '?')}, "
                f"the CRAN snapshot of {run.get('CRAN-snapshot', '?')} and CRAN's lists as of {as_of}."),
           "",
           "| CRAN's list | Package | CRAN's result | Result here |",
           "|---|---|---|---|"]
    cell = lambda s: s.replace("|", "\\|")
    for kind in kinds:
        mine = [(pkg, e) for (k, pkg), e in entries.items() if k == kind]
        if not mine:
            out.append(f"| {kind} | none listed | | |")
        elif len(mine) > LONG:
            counts = {}
            for _, e in mine:
                counts[e["first"]] = counts.get(e["first"], 0) + 1
            tally = ", ".join(f"{n} {v}" for v, n in sorted(counts.items(), key=lambda c: rank(c[0])))
            out.append(f"| {kind} | {len(mine)} packages | | {tally} |")
        else:
            out += [f"| {kind} | `{pkg}` {e['version']} | {cell(e['cran'])} | {cell(e['shown'])} |"
                    for pkg, e in mine]
    out.append("")
    if any("`blis" in e["shown"] for e in entries.values()):
        out += [para("A BLIS entry is checked once for each BLIS build and kernel set. `blis-zen3` is "
                     "Debian's BLIS with the zen3 kernels, and `blis-fedora-haswell` is Fedora's binary "
                     "with the haswell kernels."), ""]
    if silent:
        out += [para(f"No results came from {listed(silent)} this time."), ""]
    if old_date:
        changed = changes(old, entries)
        if changed:
            out.append(f"These entries changed since the run of {old_date}.")
            out.append("")
            out += [textwrap.fill(line, 78, initial_indent="- ", subsequent_indent="  ",
                                  break_long_words=False, break_on_hyphens=False)
                    for line in changed[:12]]
            if len(changed) > 12:
                out.append(f"- {len(changed) - 12} more are in the run's report.")
        else:
            out.append(f"Nothing has changed since the run of {old_date}.")
        out.append("")
    if url:
        out += [f"[daily-run]: {url}", ""]
    if out[-1] == "":
        out.pop()
    out.append(END)
    return "\n".join(out)


def main(rows_path, run_path, readme_path, state_path, url=None):
    rows = list(csv.DictReader(open(rows_path, encoding="utf-8"), delimiter="\t"))
    run = dcf(run_path)
    entries, silent = collapse(rows)
    old, old_date = read_state(state_path)
    text = section(entries, silent, run, old, old_date, url)
    readme = open(readme_path, encoding="utf-8").read()
    if readme.count(START) != 1 or readme.count(END) != 1:
        sys.exit(f"{readme_path} does not have the two marker comments exactly once")
    head, rest = readme.split(START)
    tail = rest.split(END)[1]
    with open(readme_path, "w", encoding="utf-8") as f:
        f.write(head + text + tail)
    write_state(state_path, entries, run.get("Fetched", "")[:10])
    print(text)


if __name__ == "__main__":
    main(*sys.argv[1:6])
