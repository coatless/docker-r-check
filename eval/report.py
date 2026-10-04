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

ARMS = ["reference", "openblas", "mkl", "blis", "atlas"]
HEADING = re.compile(r"^\* (checking .*?) \.\.\.(.*)$")
RESULT = re.compile(r"(?:\[[^\]]*\]\s*)?(OK|NOTE|WARNING|ERROR)\s*$")
RANK = {"OK": 0, "NOTE": 1, "WARNING": 2, "ERROR": 3}


def problems(path):
    """Map each check step that did not end OK to its result."""
    found, current = {}, None
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return None
    for line in lines:
        h = HEADING.match(line)
        if h:
            current = re.sub(r"\s+\[[^\]]*\]$", "", h.group(1))
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
    return found


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
    out.append("## CRAN's current BLAS issues\n")
    out.append("| Package | Kind | CRAN result | Arm result | reference result | Verdict |")
    out.append("|---|---|---|---|---|---|")
    issues = []
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
                cells.append("-" if o is None else f"{o['status']} ({o['minutes']} min)")
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
        skipped = os.path.join(d, "SKIPPED")
        if os.path.exists(skipped):
            for line in open(skipped):
                issues.append(f"{a}: {line.strip()}")
    out.append("## Problems running the checks\n")
    out.extend(f"- {i}" for i in issues) if issues else out.append("None.")
    print("\n".join(out))


if __name__ == "__main__":
    main(*sys.argv[1:3])
