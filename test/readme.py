#!/usr/bin/env python3
"""Every YAML example in the README is in a workflow of this repository word for word, so that
each one runs as printed, on every push and with every new release.

    python3 test/readme.py README.md .github/workflows/*.yml

An example may stand anywhere in a workflow, at any indentation, as long as all its lines are
there in order, each with the same indentation added. Exits 1, naming the example, when one is
missing. Only the standard library is used.
"""
import re
import sys


def blocks(markdown):
    return [b.rstrip("\n").split("\n") for b in re.findall(r"^```ya?ml\n(.*?)^```", markdown, re.M | re.S)]


def indent(line):
    return len(line) - len(line.lstrip(" "))


def found(example, lines):
    for i, line in enumerate(lines):
        extra = indent(line) - indent(example[0])
        if line.lstrip(" ") != example[0].lstrip(" ") or extra < 0 or len(lines) - i < len(example):
            continue
        if all(lines[i + k] == (" " * extra + want if want else "") for k, want in enumerate(example)):
            return True
    return False


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    with open(sys.argv[1], encoding="utf-8") as f:
        examples = blocks(f.read())
    lines = []
    for path in sys.argv[2:]:
        with open(path, encoding="utf-8") as f:
            lines += f.read().split("\n") + [""]
    missing = [e for e in examples if not found(e, lines)]
    for e in missing:
        print(f"::error file={sys.argv[1]}::This example is in no workflow, so nothing runs it:%0A" + "%0A".join(e))
    print(f"{len(examples) - len(missing)} of {len(examples)} examples in {sys.argv[1]} run as printed")
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
