#!/usr/bin/env python3
"""Compare the arms' check results with CRAN's BLAS check logs.

    report.py <oracle-dir> <results-dir> > report.md

<oracle-dir> holds targets.tsv, logs/ and run.txt from the targets job.
<results-dir> holds one directory per arm, each with one directory per
package (manifest.dcf, 00check.log) and an optional BUILD-FAILED file.
"""
import csv
import os
import re
import sys

ARMS = ["reference", "openblas", "mkl", "blis", "atlas", "clang23"]
HEADING = re.compile(r"^\* (checking .*?) \.\.\.(.*)$")
RESULT = re.compile(r"(?:\[[^\]]*\]\s*)?(OK|NOTE|WARNING|ERROR)\s*$")
QUOTED = re.compile(r"\s*‘[^’]*’")
MISSING = re.compile(r"Packages? (?:required|suggested) but not available:?((?:\s*‘[^’]+’,?)+)")


def problems(path):
    """Map each check step that did not end OK to its result.

    Package names are dropped from the step names so that two logs can be
    compared. An install log, which has no check steps, counts as a failed
    install. Missing dependencies are named in the result.
    """
    found, current = {}, None
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    lines = text.splitlines()
    if lines and lines[0].startswith("* installing *source* package"):
        return {"checking whether package can be installed": "ERROR"}
    for line in lines:
        h = HEADING.match(line)
        if h:
            current = QUOTED.sub("", re.sub(r"\s+\[[^\]]*\]$", "", h.group(1)))
            m = RESULT.search(h.group(2))
            if m:
                if m.group(1) != "OK":
                    found[current] = m.group(1)
                current = None
            continue
        if line.startswith("* "):
            current = None
        elif current:
            m = re.match(r"^\s*" + RESULT.pattern, line)
            if m:
                if m.group(1) != "OK":
                    found[current] = m.group(1)
                current = None
    if "checking package dependencies" in found:
        names = sorted({n for m in MISSING.finditer(text) for n in re.findall(r"‘([^’]+)’", m.group(1))})
        if names:
            found["checking package dependencies"] += " (needs " + ", ".join(names) + ")"
    return found


def first_error(path):
    """The first compiler error in an install log, or None."""
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            if re.search(r"\berror:", line):
                return line.strip()[:160]
    except OSError:
        pass
    return None


def status(path):
    last = None
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            if line.startswith("Status: "):
                last = line[8:].strip()
    except OSError:
        pass
    return last


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


def ours(results, arm, pkg):
    d = os.path.join(results, arm, pkg)
    if not os.path.isdir(d):
        return None
    m = dcf(os.path.join(d, "manifest.dcf"))
    log = os.path.join(d, pkg + ".Rcheck", "00check.log")
    return {
        "status": m.get("Status") or status(log) or "did not complete",
        "problems": problems(log) or {},
        "tarball": m.get("Tarball", ""),
        "minutes": round(int(m.get("Elapsed-Seconds", "0") or 0) / 60),
        "core": m.get("OpenBLAS-Core", ""),
        "r_rev": m.get("Image-r_svn_rev", ""),
    }


def short(p):
    if not p:
        return "OK"
    return "; ".join(f"{k.replace('checking ', '')}: {v}" for k, v in sorted(p.items()))


def verdict(cran, arm, ref):
    if arm is None:
        return "not checked"
    if arm["status"] == "did not complete":
        return "check did not finish"
    c, a = set(cran), set(arm["problems"])
    if not a:
        v = "not reproduced"
    elif c and a == c:
        v = "reproduced"
    elif c & a:
        v = "partly reproduced"
    else:
        v = "different problem"
    if ref is not None and a and set(ref["problems"]) >= a:
        v += ", also in reference"
    return v


def main(oracle, results):
    out = []
    run = dcf(os.path.join(oracle, "run.txt"))
    out.append("# Evaluation run\n")
    for k in ["R-revision", "QA-revision", "CRAN-snapshot", "check_issues-Last-Modified"]:
        if k in run:
            out.append(f"- {k}: {run[k]}")
    built = {a: not os.path.exists(os.path.join(results, a, "BUILD-FAILED"))
             for a in ARMS if os.path.isdir(os.path.join(results, a))}
    out.append("- arms built: " + ", ".join(f"{a} {'yes' if ok else 'NO'}" for a, ok in built.items()))
    out.append("")

    targets = list(csv.DictReader(open(os.path.join(oracle, "targets.tsv")), delimiter="\t"))
    out.append("## CRAN's current BLAS and clang23 issues\n")
    out.append("| Package | Kind | CRAN result | Arm result | reference result | Verdict |")
    out.append("|---|---|---|---|---|---|")
    issues, errors = [], []
    for t in targets:
        pkg, arm = t["Package"], t["arm"]
        cran = problems(os.path.join(oracle, t["log"]))
        if cran is None:
            issues.append(f"{pkg} ({t['kind']}): CRAN's log could not be fetched")
            cran = {}
        a, r = ours(results, arm, pkg), ours(results, "reference", pkg)
        if a and t["Version"] not in a["tarball"]:
            issues.append(f"{pkg}: CRAN checked {t['Version']}, the arm checked {a['tarball']}")
        out.append(f"| {pkg} {t['Version']} | {t['kind']} | {short(cran)} | "
                   f"{short(a['problems']) if a else '-'} | {short(r['problems']) if r else '-'} | "
                   f"{verdict(cran, a, r)} |")
        theirs = first_error(os.path.join(oracle, t["log"][:-4] + ".install.log"))
        mine = first_error(os.path.join(results, arm, pkg, pkg + ".Rcheck", "00install.out"))
        if theirs or mine:
            errors.append(f"- {pkg}: CRAN `{theirs or 'no install log kept'}`, "
                          f"arm `{mine or ('installed' if a else 'not checked')}`")
    out.append("")
    if errors:
        out.append("First compiler error where an install failed\n")
        out.extend(errors)
        out.append("")

    others = sorted({p for a in ARMS for p in (os.listdir(os.path.join(results, a))
                                               if os.path.isdir(os.path.join(results, a)) else [])
                     if os.path.isdir(os.path.join(results, a, p))}
                    - {t["Package"] for t in targets})
    if others:
        out.append("## Other packages, every arm\n")
        out.append("| Package | " + " | ".join(ARMS) + " |")
        out.append("|---|" + "---|" * len(ARMS))
        for p in others:
            cells = []
            for a in ARMS:
                o = ours(results, a, p)
                cells.append("-" if o is None else o["status"])
            out.append(f"| {p} | " + " | ".join(cells) + " |")
        out.append("")

    for a in ARMS:
        d = os.path.join(results, a)
        if not os.path.isdir(d):
            continue
        f = os.path.join(d, "BUILD-FAILED")
        if os.path.exists(f):
            issues.append(f"{a}: the image did not build. " + open(f).read().strip().splitlines()[-1])
        for p in sorted(os.listdir(d)):
            o = ours(results, a, p) if os.path.isdir(os.path.join(d, p)) else None
            if o and o["status"] == "did not complete":
                issues.append(f"{a}/{p}: the check did not finish (see console.log)")
        for f in sorted(os.listdir(d)):
            if f.startswith("SKIPPED"):
                for line in open(os.path.join(d, f)):
                    issues.append(f"{a}: {line.strip()}")
    out.append("## Problems running the checks\n")
    out.extend(f"- {i}" for i in issues) if issues else out.append("None.")
    print("\n".join(out))


if __name__ == "__main__":
    main(*sys.argv[1:3])
