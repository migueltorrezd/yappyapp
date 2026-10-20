#!/usr/bin/env python3
"""L10N (YA-42): every L10n.tr / L10n.plural key in Sources must exist in the
English table (Localizable.strings or .stringsdict), and every language must
carry the same keys. Run from anywhere: python3 scripts/check_l10n_keys.py
"""
import os
import plistlib
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "Sources", "YappYapp")
TABLES = os.path.join(SOURCES, "Resources")
LANGUAGES = ["en", "fr", "es", "nl"]


def literals(line):
    """Top-level string literals as (start, end, text, interpolated)."""
    out, i, n = [], 0, len(line)
    while i < n:
        if line.startswith("//", i) or line.startswith('"""', i):
            break
        if line[i] == '"':
            end, interp = scan(line, i + 1)
            if end is None:
                break
            out.append((i, end + 1, line[i + 1:end], interp))
            i = end + 1
            continue
        i += 1
    return out


def scan(line, i):
    interp, n = False, len(line)
    while i < n:
        c = line[i]
        if c == "\\":
            if line.startswith("\\(", i):
                interp, depth, i = True, 1, i + 2
                while i < n and depth:
                    if line[i] == '"':
                        end, _ = scan(line, i + 1)
                        if end is None:
                            return None, interp
                        i = end + 1
                        continue
                    depth += {"(": 1, ")": -1}.get(line[i], 0)
                    i += 1
                continue
            i += 2
            continue
        if c == '"':
            return i, interp
        i += 1
    return None, interp


def unescape(text):
    text = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), text)
    return text.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def used_keys():
    keys = {}
    for name in sorted(os.listdir(SOURCES)):
        if not name.endswith(".swift") or name.startswith("SelfTests"):
            continue
        for number, line in enumerate(open(os.path.join(SOURCES, name), encoding="utf-8"), 1):
            found = literals(line)
            for call in re.finditer(r"L10n\.(tr|plural)\(", line):
                # First argument only; it may be a ternary of literals.
                depth, j = 1, call.end()
                spans = {start: end for start, end, _, _ in found}
                while j < len(line) and depth:
                    if j in spans:
                        j = spans[j]
                        continue
                    depth += {"(": 1, ")": -1}.get(line[j], 0)
                    if line[j] == "," and depth == 1:
                        break
                    j += 1
                for start, _, text, interp in found:
                    if call.end() <= start < j and not interp:
                        keys.setdefault(unescape(text), f"{name}:{number}")
    return keys


def main():
    tables, plurals = {}, {}
    for language in LANGUAGES:
        folder = os.path.join(TABLES, f"{language}.lproj")
        with open(os.path.join(folder, "Localizable.strings"), "rb") as handle:
            tables[language] = parse_strings(handle.read().decode("utf-8"))
        with open(os.path.join(folder, "Localizable.stringsdict"), "rb") as handle:
            plurals[language] = plistlib.load(handle)
    errors = 0
    english = set(tables["en"]) | set(plurals["en"])
    for key, where in sorted(used_keys().items(), key=lambda item: item[1]):
        if key not in english:
            print(f"MISSING {where}: {key!r}")
            errors += 1
    for language in LANGUAGES[1:]:
        for kind, table in (("strings", tables), ("stringsdict", plurals)):
            missing = set(table["en"]) - set(table[language])
            extra = set(table[language]) - set(table["en"])
            for key in sorted(missing):
                print(f"MISSING {language}.{kind}: {key!r}")
            for key in sorted(extra):
                print(f"EXTRA {language}.{kind}: {key!r}")
            errors += len(missing) + len(extra)
    if errors:
        print(f"{errors} localization problem(s).")
        return 1
    print(f"Localization keys verified: {len(tables['en'])} strings, {len(plurals['en'])} plurals, {len(LANGUAGES)} languages.")
    return 0


def parse_strings(text):
    """Minimal .strings reader for the "key" = "value"; lines these tables use."""
    pattern = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')
    result = {}
    for line in text.splitlines():
        match = pattern.match(line)
        if match:
            result[unescape(match.group(1))] = unescape(match.group(2))
    return result


if __name__ == "__main__":
    sys.exit(main())
