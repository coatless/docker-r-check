#!/usr/bin/env python3
"""Compare the arms' check results with CRAN's check logs.

    report.py <oracle-dir> <results-dir> [<earlier-results-dir>] > report.md

<oracle-dir> holds targets.tsv, logs/ and run.txt from the targets job.
<results-dir> holds one directory per arm, or per arm and kernel setting
such as blis-haswell, each with one directory per package (manifest.dcf,
00check.log, 00install.out) and optional BUILD-FAILED and SKIPPED-* files. A directory such
as mkl@offline holds the same checks repeated under another condition.
<earlier-results-dir> holds the results of an earlier run to compare with.
"""
import csv
import os
import re
import sys

HEADING = re.compile(r"^\* (checking .*?) \.\.\.(.*)$")
RESULT = re.compile(r"(?:\[[^\]]*\]\s*)?(OK|NOTE|WARNING|ERROR)\s*$")
# R quotes names with ‘’ in a UTF-8 locale and with '' otherwise.
QUOTED = re.compile(r"\s*[‘'][^’']*[’']")
MISSING = re.compile(r"Packages? (?:required|suggested) but not available:?((?:\s*[‘'][^’']+[’'],?)+)")
COMPARING = re.compile(r"^\s*Comparing [‘']([^’']+)[’'] to [‘'][^’']+[’'] \.\.\.(.*)$")
FAILED = re.compile(r"^Running the tests in [‘']tests/([^’']+)[’'] failed")
# A link-time warning about one symbol, as GCC prints it.
LTO = re.compile(r"warning: (?:type of |type )?[‘']([^’']+)[’'] "
                 r"(?:does not match original declaration|violates the C\+\+ One Definition Rule) "
                 r"\[-W(lto-type-mismatch|odr)\]")


def problems(path):
    """Map each thing that did not end OK in a check log to its result.

    The keys are check steps with package names dropped, so that two logs can
    be compared. A failing test step is split by test file. An install log,
    which has no check steps, counts as a failed install. Missing
    dependencies are named in the result.
    """
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    lines = text.splitlines()
    if lines and lines[0].startswith("* installing *source* package"):
        return {"whether package can be installed": "ERROR"}

    found, files, current, in_tests = {}, [], None, False
    for line in lines:
        h = HEADING.match(line)
        if h:
            step = QUOTED.sub("", re.sub(r"\s+\[[^\]]*\]$", "", h.group(1))).replace("checking ", "", 1)
            in_tests = step == "tests"
            m = RESULT.search(h.group(2))
            if m and m.group(1) != "OK":
                found[step] = m.group(1)
            current = None if m else step
            continue
        if line.startswith("* "):
            current, in_tests = None, False
            continue
        if in_tests:
            c, f = COMPARING.match(line), FAILED.match(line)
            if c and not c.group(2).strip().endswith("OK"):
                files.append(c.group(1))
            if f:
                files.append(f.group(1))
        if current:
            m = re.match(r"^\s*" + RESULT.pattern, line)
            if m:
                if m.group(1) != "OK":
                    found[current] = m.group(1)
                current = None
    if "tests" in found and files:
        result = found.pop("tests")
        for f in dict.fromkeys(files):
            found[f"tests {f}"] = result
    if "package dependencies" in found:
        names = sorted({n for m in MISSING.finditer(text) for n in re.findall(r"[‘']([^’']+)[’']", m.group(1))})
        if names:
            found["package dependencies"] += " (needs " + ", ".join(names) + ")"
    return found


def lto_warnings(path):
    """Map each symbol with an LTO warning in an install log to the warning.

    CRAN's LTO logs are install logs, so an LTO issue is compared by the
    symbols the linker complains about, not by check steps.
    """
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    kinds = {"lto-type-mismatch": "type mismatch", "odr": "ODR"}
    return {m.group(1): kinds[m.group(2)] for m in LTO.finditer(text)}


def first_error(path):
    """The first compiler error in an install log, or None."""
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            if re.search(r"\berror:", line):
                return line.strip()[:160]
    except OSError:
        pass
    return None


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


def ours(results, label, pkg, kind=None):
    d = os.path.join(results, label, pkg)
    if not os.path.isdir(d):
        return None
    m = dcf(os.path.join(d, "manifest.dcf"))
    found = problems(os.path.join(d, pkg + ".Rcheck", "00check.log"))
    then_failed = False
    if kind == "LTO":
        # The LTO warnings are in the install log, and they count even when
        # the package fails to load afterwards. A package that did not get
        # as far as linking keeps the step that stopped it.
        stopped = {k: v for k, v in (found or {}).items() if v.startswith("ERROR")
                   and k in ("package dependencies", "whether package can be installed")}
        warned = lto_warnings(os.path.join(d, pkg + ".Rcheck", "00install.out"))
        found = warned or stopped
        then_failed = bool(warned and stopped)
    return {
        "status": m.get("Status", "did not complete"),
        "problems": found or {},
        "tarball": m.get("Tarball", ""),
        "then_failed": then_failed,
    }


def short(p, most=None):
    """One line for a set of problems, naming at most `most` of them."""
    items = [f"{k}: {v}" for k, v in sorted(p.items())]
    if most and len(items) > most:
        items = items[:most] + [f"and {len(items) - most} more"]
    return "; ".join(items) if items else "OK"


def verdict(cran, arm, ref):
    if arm is None:
        return "not checked"
    if arm["status"] == "did not complete":
        return "check did not finish"
    c, a = set(cran), set(arm["problems"])
    if not a:
        v = "not reproduced"
    elif arm["problems"] == cran:
        v = "reproduced"
    elif a == c:
        v = "same step, different result"
    elif c & a:
        v = "partly reproduced"
    else:
        v = "different problem"
    if ref is not None and a:
        shared = {k for k in a if ref["problems"].get(k) == arm["problems"][k]}
        if shared == a:
            v += ", all of it also in reference"
        elif shared:
            v += ", part of it also in reference"
    return v


def same(results_a, label_a, results_b, label_b):
    """Compare two sets of results package by package.

    Returns the number of packages in both, and a line for each one whose
    status or problems differ.
    """
    a_dir, b_dir = os.path.join(results_a, label_a), os.path.join(results_b, label_b)
    both = sorted(p for p in os.listdir(a_dir)
                  if os.path.isdir(os.path.join(a_dir, p)) and os.path.isdir(os.path.join(b_dir, p)))
    differ = []
    for p in both:
        a, b = ours(results_a, label_a, p), ours(results_b, label_b, p)
        if (a["status"], a["problems"]) != (b["status"], b["problems"]):
            differ.append(f"{p}: {a['status']} ({short(a['problems'])}) against "
                          f"{b['status']} ({short(b['problems'])})")
    return len(both), differ


def main(oracle, results, earlier=None):
    every = sorted(d for d in os.listdir(results) if os.path.isdir(os.path.join(results, d)))
    labels = [d for d in every if "@" not in d]
    labels.sort(key=lambda d: d != "reference")
    out = ["# Evaluation run\n"]
    run = dcf(os.path.join(oracle, "run.txt"))
    for k in ["R-revision", "QA-revision", "CRAN-snapshot", "check_issues-Last-Modified", "Baseline-run"]:
        if k in run:
            out.append(f"- {k}: {run[k]}")
    built = [f"{d} {'NO' if os.path.exists(os.path.join(results, d, 'BUILD-FAILED')) else 'yes'}"
             for d in labels]
    out.append("- arms built: " + ", ".join(built))
    out.append("")

    targets = list(csv.DictReader(open(os.path.join(oracle, "targets.tsv")), delimiter="\t"))
    out.append("## CRAN's current issues\n")
    out.append("| Package | Kind | Arm | CRAN result | Arm result | reference result | Verdict |")
    out.append("|---|---|---|---|---|---|---|")
    issues, errors, tally = [], [], {}
    for t in targets:
        pkg, arm = t["Package"], t["arm"]
        lto = t["kind"] == "LTO"
        cran = (lto_warnings if lto else problems)(os.path.join(oracle, t["log"]))
        if cran is None:
            issues.append(f"{pkg} ({t['kind']}): CRAN's log could not be fetched")
            cran = {}
        ref = None if lto else ours(results, "reference", pkg)
        most = 3 if lto else None
        variants = [d for d in labels if d == arm or d.startswith(arm + "-")] or [arm]
        for label in variants:
            a = ours(results, label, pkg, t["kind"])
            v = verdict(cran, a, ref)
            if a and a["then_failed"]:
                v += ", but the install failed afterwards"
            tally.setdefault(label, {}).setdefault(re.split(", (?:all|part) of it", v)[0], []).append(pkg)
            if a and t["Version"] not in a["tarball"]:
                issues.append(f"{pkg}: CRAN checked {t['Version']}, {label} checked {a['tarball']}")
            out.append(f"| {pkg} {t['Version']} | {t['kind']} | {label} | {short(cran, most)} | "
                       f"{short(a['problems'], most) if a else '-'} | "
                       f"{short(ref['problems']) if ref else '-'} | {v} |")
            theirs = first_error(os.path.join(oracle, t["log"][:-4] + ".install.log"))
            mine = first_error(os.path.join(results, label, pkg, pkg + ".Rcheck", "00install.out"))
            if theirs or mine:
                errors.append(f"- {pkg} ({label}): CRAN `{theirs or ('installed' if lto else 'no install log kept')}`, "
                              f"arm `{mine or ('installed' if a else 'not checked')}`")
    out.append("")
    out.append("Counts per arm\n")
    for label, counts in tally.items():
        out.append(f"- {label}: " + ", ".join(f"{len(v)} {k}" for k, v in sorted(counts.items())))
    out.append("")
    if errors:
        out.append("First compiler error where an install failed\n")
        out.extend(errors)
        out.append("")

    listed = {t["Package"] for t in targets}
    others = sorted({p for d in labels for p in os.listdir(os.path.join(results, d))
                     if os.path.isdir(os.path.join(results, d, p))} - listed)
    if others:
        out.append("## Other packages, every arm\n")
        out.append("| Package | " + " | ".join(labels) + " |")
        out.append("|---|" + "---|" * len(labels))
        for p in others:
            cells = [(o["status"] if o else "-") for o in (ours(results, d, p) for d in labels)]
            out.append(f"| {p} | " + " | ".join(cells) + " |")
        out.append("")

    repeats = [d for d in every if "@" in d and d.split("@")[0] in labels]
    if repeats:
        out.append("## The same image under other conditions\n")
        out.append("| Arm | Condition | Packages | Same result | Different |")
        out.append("|---|---|---|---|---|")
        notes = []
        for d in repeats:
            base, condition = d.split("@", 1)
            n, differ = same(results, base, results, d)
            out.append(f"| {base} | {condition} | {n} | {n - len(differ)} | {len(differ)} |")
            notes += [f"- {base}, {condition}, {line}" for line in differ]
        out.append("")
        out.extend(notes + [""] if notes else [])

    if earlier and os.path.isdir(earlier):
        out.append(f"## Against the earlier run {run.get('Baseline-run', '')}\n".replace(" \n", "\n"))
        out.append("| Arm | Packages in both | Same result | Different |")
        out.append("|---|---|---|---|")
        notes = []
        for d in labels:
            if not os.path.isdir(os.path.join(earlier, d)):
                continue
            n, differ = same(results, d, earlier, d)
            out.append(f"| {d} | {n} | {n - len(differ)} | {len(differ)} |")
            notes += [f"- {d}, {line}" for line in differ]
        out.append("")
        out.extend(notes + [""] if notes else [])

    for d in labels:
        path = os.path.join(results, d)
        failed = os.path.join(path, "BUILD-FAILED")
        if os.path.exists(failed):
            issues.append(f"{d}: the image did not build. " + open(failed).read().strip().splitlines()[-1])
        for f in sorted(os.listdir(path)):
            if f.startswith("SKIPPED"):
                issues.extend(f"{d}: {line.strip()}" for line in open(os.path.join(path, f)))
            o = ours(results, d, f)
            if o and o["status"] == "did not complete":
                issues.append(f"{d}/{f}: the check did not finish")
    out.append("## Problems running the checks\n")
    out.extend(f"- {i}" for i in issues) if issues else out.append("None.")
    print("\n".join(out))


if __name__ == "__main__":
    main(*sys.argv[1:4])
