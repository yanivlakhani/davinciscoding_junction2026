#!/usr/bin/env python3
"""Fail if the backend's pinned dependencies have drifted from the code.

The fall server declares its runtime packages as arguments to
uv_pip_install() inside backend/fall_server.py. There is no manifest for a
scanner to read, so this repository keeps one alongside the evidence:

    backend-requirements.in    the declarations, copied out of the code
    backend-requirements.txt   every package they resolve to, pinned and hashed

A copy is only worth something while it is true. This script reads the
declarations back out of fall_server.py and checks, in order:

  1. backend-requirements.in lists exactly what the code declares
  2. backend-requirements.txt pins every one of them, at a version the
     declaration allows
  3. (optional) another copy of the declarations, such as the one the
     companion app's Trust panel is built from, lists the same packages

Usage:
    check_backend_pins.py --source product/backend/fall_server.py \\
        --declared supply-chain/backend-requirements.in \\
        --pins supply-chain/backend-requirements.txt \\
        [--mirror app/supply-chain/backend-declared.txt]

Standard library only, so it runs before anything has been installed.
Exit status is 0 when everything agrees and 1 otherwise.
"""

import argparse
import ast
import pathlib
import re
import sys

INSTALL_CALLS = ("uv_pip_install", "pip_install")
OPERATORS = ("~=", "==", "!=", "<=", ">=", "<", ">")


class Unsupported(Exception):
    """A requirement this checker cannot evaluate. Never treated as a pass."""


def canonical_name(name):
    """PEP 503: case and runs of - _ . do not distinguish package names."""
    return re.sub(r"[-_.]+", "-", name).lower()


def parse_requirement(text):
    """'fastapi[standard]>=0.1,<1' -> (name, extras, [(op, version), ...])."""
    text = text.strip()
    if ";" in text or "@" in text:
        raise Unsupported(
            f"{text!r}: environment markers and direct URLs are not supported by this "
            "checker. Extend check_backend_pins.py before relying on it."
        )
    match = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)\s*(\[[^\]]*\])?\s*(.*)$", text)
    if not match:
        raise Unsupported(f"{text!r}: not a requirement this checker understands")
    name, extras, rest = match.groups()
    extras = tuple(sorted(canonical_name(e.strip()) for e in (extras or "[]")[1:-1].split(",") if e.strip()))
    clauses = []
    for clause in filter(None, (c.strip() for c in rest.split(","))):
        for op in OPERATORS:
            if clause.startswith(op):
                clauses.append((op, clause[len(op):].strip()))
                break
        else:
            raise Unsupported(f"{text!r}: cannot read the version clause {clause!r}")
    return canonical_name(name), extras, tuple(sorted(clauses))


def release(version):
    """Leading numeric part of a version as a tuple: '4.14.0.94' -> (4, 14, 0, 94)."""
    match = re.match(r"^\d+(\.\d+)*", version)
    if not match:
        raise Unsupported(f"cannot read a release number from version {version!r}")
    return tuple(int(part) for part in match.group(0).split("."))


def satisfies(pinned, op, wanted):
    """Does the pinned version satisfy one clause? Release numbers only."""
    have = release(pinned)
    if wanted.endswith(".*"):
        if op not in ("==", "!="):
            raise Unsupported(f"wildcard {wanted!r} is only meaningful with == or !=")
        prefix = release(wanted[:-2])
        same = have[: len(prefix)] == prefix
        return same if op == "==" else not same
    want = release(wanted)
    width = max(len(have), len(want))
    a = have + (0,) * (width - len(have))
    b = want + (0,) * (width - len(want))
    if op == "==":
        return a == b
    if op == "!=":
        return a != b
    if op == "<":
        return a < b
    if op == "<=":
        return a <= b
    if op == ">":
        return a > b
    if op == ">=":
        return a >= b
    if op == "~=":  # compatible release: >= wanted, and same up to the last part
        if len(want) < 2:
            raise Unsupported(f"~={wanted} needs at least two release parts")
        return a >= b and have[: len(want) - 1] == want[:-1]
    raise Unsupported(f"operator {op!r}")


def declared_in_source(path):
    """String arguments of every uv_pip_install()/pip_install() call."""
    tree = ast.parse(pathlib.Path(path).read_text(), filename=str(path))
    found = []
    for node in ast.walk(tree):
        if (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr in INSTALL_CALLS
        ):
            for arg in node.args:
                if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                    found.append(arg.value)
                else:
                    raise Unsupported(
                        f"{path}:{arg.lineno}: an argument to {node.func.attr}() is not a plain "
                        "string, so the declared packages cannot be read from the code"
                    )
    return found


def listed_in_file(path):
    """Non-comment lines of a requirements-style file."""
    lines = []
    for raw in pathlib.Path(path).read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            lines.append(line)
    return lines


def pinned_in_lock(path):
    """{canonical name: version} for every 'name==version' line in a lock file."""
    pins = {}
    for raw in pathlib.Path(path).read_text().splitlines():
        match = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)(?:\[[^\]]*\])?==([^\s\\;]+)", raw)
        if match:
            pins[canonical_name(match.group(1))] = match.group(2)
    return pins


def compare_lists(label_a, a, label_b, b):
    """Problems, if two requirement lists do not declare the same things."""
    parsed_a = {parse_requirement(r): r for r in a}
    parsed_b = {parse_requirement(r): r for r in b}
    problems = []
    for key in sorted(set(parsed_a) - set(parsed_b)):
        problems.append(f"{parsed_a[key]!r} is in {label_a} but not in {label_b}")
    for key in sorted(set(parsed_b) - set(parsed_a)):
        problems.append(f"{parsed_b[key]!r} is in {label_b} but not in {label_a}")
    return problems


def check(source, declared, pins, mirror=None):
    """Return (report lines, problems)."""
    report, problems = [], []

    in_code = declared_in_source(source)
    if not in_code:
        return report, [
            f"{source} has no uv_pip_install()/pip_install() call with string arguments. "
            "If the server's dependencies moved to a manifest, point the workflow at it instead."
        ]
    in_file = listed_in_file(declared)
    problems += compare_lists(str(source), in_code, str(declared), in_file)

    lock = pinned_in_lock(pins)
    report.append(f"{len(in_code)} packages declared in {source}; {len(lock)} pinned in {pins}")
    for requirement in in_code:
        name, _extras, clauses = parse_requirement(requirement)
        version = lock.get(name)
        if version is None:
            problems.append(f"{requirement!r} is declared but {pins} has no pin for {name}")
            continue
        broken = [f"{op}{wanted}" for op, wanted in clauses if not satisfies(version, op, wanted)]
        if broken:
            problems.append(
                f"{name} is pinned at {version}, which does not satisfy {', '.join(broken)} from {requirement!r}"
            )
        else:
            report.append(f"  {requirement:<28} -> {name}=={version}")

    if mirror is not None:
        problems += compare_lists(str(declared), in_file, str(mirror), listed_in_file(mirror))
        report.append(f"{mirror} lists the same declarations")

    return report, problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--source", required=True, help="fall_server.py to read declarations from")
    parser.add_argument("--declared", required=True, help="backend-requirements.in")
    parser.add_argument("--pins", required=True, help="backend-requirements.txt")
    parser.add_argument("--mirror", help="another copy of the declarations to hold to the same list")
    args = parser.parse_args(argv)

    try:
        report, problems = check(args.source, args.declared, args.pins, args.mirror)
    except Unsupported as error:
        report, problems = [], [str(error)]
    except (OSError, SyntaxError) as error:
        report, problems = [], [f"could not read an input: {error}"]

    for line in report:
        print(line)
    if problems:
        print("\nThe backend's pinned dependencies no longer match the code:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        print(
            "\nUpdate supply-chain/backend-requirements.in to match fall_server.py, regenerate "
            "backend-requirements.txt (the command is at the top of the .in file), and commit both.",
            file=sys.stderr,
        )
        return 1
    print("Pins match the code.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
