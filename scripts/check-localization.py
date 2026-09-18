#!/usr/bin/env python3
"""Check that the app's source, Info.plist, and String Catalogs agree.

The catalogs in packaging/Localization are maintained by hand and by the
translation pipeline; nothing extracts keys from the Swift source. This check
is what keeps a string from shipping untranslatable, a dead key from being
translated forever, and a translation's placeholders from crashing the app.
"""
import json
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
LOOKUP = re.compile(r"\bStrings\.(\w+)\(")
TABLE = re.compile(r'static func (\w+)\(_ key: String[^{]*\{\s*lookup\(key, table: "(\w+)"')
SPECIFIER = re.compile(r"%(?:(\d+)\$)?(lld|@|%|[A-Za-z]+)")
# A literal handed straight to one of these would be looked up in a
# "Localizable" table that does not exist, or not looked up at all.
BARE = re.compile(r'''(?x)
      \b(?:Text|Button|Toggle|Picker|Menu|Label|Link|Section|TextField|SecureField|Stepper|GroupBox
           |DisclosureGroup|NavigationLink|ProgressView)\(\s*"
    | \.(?:help|navigationTitle|accessibilityLabel|accessibilityHint|accessibilityValue)\(\s*"
    | \b(?:title|withTitle|messageText|informativeText|prompt|message|nameFieldLabel|toolTip)\s*[:=]\s*"
    | \b(?:UpdateError|Failure|AppMessage)\(\s*(?:text:\s*)?"
''')
NEVER_TRANSLATED = {"CFBundleName", "CFBundleDisplayName"}
ESCAPES = {'"': '"', "\\": "\\", "n": "\n", "t": "\t", "r": "\r", "0": "\0", "'": "'"}


def skip_string(text, start):
    """Index just past the string literal that opens at text[start]."""
    if text.startswith('"""', start):
        raise ValueError("multi-line string literals are not supported in localized calls")
    index = start + 1
    while text[index] != '"':
        if text[index] == "\n":
            raise ValueError("unterminated string literal")
        if text[index] == "\\":
            index = skip_group(text, index + 1) if text[index + 1] == "(" else index + 2
        else:
            index += 1
    return index + 1


def skip_group(text, start):
    """Index just past the bracket that closes the one at text[start]."""
    depth, index = 0, start
    while True:
        character = text[index]
        if character == '"':
            index = skip_string(text, index)
            continue
        if character in "([{":
            depth += 1
        elif character in ")]}":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1


def strip_comments(text):
    """Blank out comments, keeping strings and line numbers intact."""
    result, index = [], 0
    while index < len(text):
        if text[index] == '"' and not text.startswith('"""', index):
            end = skip_string(text, index)
        elif text.startswith("//", index):
            end = text.find("\n", index)
            end = len(text) if end < 0 else end
            result.append(" " * (end - index))
            index = end
            continue
        elif text.startswith("/*", index):
            end = text.find("*/", index) + 2
            result.append(re.sub(r"[^\n]", " ", text[index:end]))
            index = end
            continue
        else:
            end = index + 1
        result.append(text[index:end])
        index = end
    return "".join(result)


def arguments(text, start):
    """The top-level arguments of the call whose "(" is at text[start]."""
    end = skip_group(text, start)
    pieces, depth, index, begin = [], 0, start + 1, start + 1
    while index < end - 1:
        character = text[index]
        if character == '"':
            index = skip_string(text, index)
            continue
        if character in "([{":
            depth += 1
        elif character in ")]}":
            depth -= 1
        elif character == "," and depth == 0:
            pieces.append(text[begin:index].strip())
            begin = index + 1
        index += 1
    pieces.append(text[begin:end - 1].strip())
    return pieces


def literal(source):
    """The value of a plain Swift string literal, or None for anything else."""
    if not re.fullmatch(r'"(?:[^"\\]|\\.)*"', source) or "\\(" in source:
        return None
    body = source[1:-1]
    body = re.sub(r"\\u\{([0-9A-Fa-f]{1,8})\}", lambda m: chr(int(m.group(1), 16)), body)
    return re.sub(r"\\(.)", lambda m: ESCAPES.get(m.group(1), m.group(1)), body)


def calls(text):
    """Every Strings.<table>(...) lookup as (function, key or None, argument count, line)."""
    text = strip_comments(text)
    found = []
    for match in LOOKUP.finditer(text):
        pieces = arguments(text, match.end() - 1)
        found.append((match.group(1), literal(pieces[0]), len(pieces) - 1, text.count("\n", 0, match.start()) + 1))
    return found


def placeholders(text):
    """The format arguments a string consumes, as sorted (position, type) pairs."""
    found = [(m.group(1), m.group(2)) for m in SPECIFIER.finditer(text) if m.group(2) != "%"]
    for _, kind in found:
        if kind not in ("@", "lld"):
            raise ValueError("unsupported format specifier %" + kind + "; use %@ or %lld")
    numbered = [position is not None for position, _ in found]
    if any(numbered) and not all(numbered):
        raise ValueError("mixes numbered and unnumbered format specifiers")
    return sorted((int(position) if position else index + 1, kind) for index, (position, kind) in enumerate(found))


def values(localization):
    """(description, text, is a plural form) for every string a localization carries."""
    unit = localization.get("stringUnit")
    if unit:
        yield "", unit.get("value", ""), False
    for quantity, form in localization.get("variations", {}).get("plural", {}).items():
        yield " (" + quantity + ")", form.get("stringUnit", {}).get("value", ""), True


def check_entry(table, key, entry, source):
    problems = []
    where = table + ': "' + key + '"'
    if not entry.get("comment", "").strip():
        problems.append(where + " has no translator comment")
    try:
        expected = placeholders(key)
    except ValueError as error:
        return problems + [where + " " + str(error)]
    if len(expected) > 1 and "$" not in key:
        problems.append(where + " takes several arguments; number them (%1$@, %2$lld) so translations can reorder them")
    localizations = entry.get("localizations", {})
    if any(kind == "lld" for _, kind in expected):
        forms = localizations.get(source, {}).get("variations", {}).get("plural", {})
        if not {"one", "other"} <= forms.keys():
            problems.append(where + " counts something, so its English needs 'one' and 'other' plural variations")
    if not expected:
        return problems
    for locale, localization in sorted(localizations.items()):
        for form, text, plural in values(localization):
            try:
                actual = placeholders(text)
            except ValueError as error:
                problems.append(where + " [" + locale + form + "] " + str(error))
                continue
            # A plural form may spell its count out ("One file") when the count is the only argument.
            if actual != expected and not (plural and len(expected) == 1 and not actual):
                problems.append(where + " [" + locale + form + "] does not use the same format arguments as its key")
    return problems


def check_info(catalog, info, source):
    problems = []
    strings = catalog.get("strings", {})
    if info.get("CFBundleDevelopmentRegion") != source:
        problems.append("Info.plist: CFBundleDevelopmentRegion must be the catalogs' source language, " + source)
    names = {entry[field] for group, field in (("CFBundleDocumentTypes", "CFBundleTypeName"),
                                               ("UTImportedTypeDeclarations", "UTTypeDescription"),
                                               ("UTExportedTypeDeclarations", "UTTypeDescription"))
             for entry in info.get(group, []) if field in entry}
    for name in sorted(names | ({"NSHumanReadableCopyright"} & info.keys())):
        if name not in strings:
            problems.append('InfoPlist: "' + name + '" is shown by macOS but has no catalog entry')
    for key, entry in strings.items():
        english = entry.get("localizations", {}).get(source, {}).get("stringUnit", {}).get("value")
        if key in NEVER_TRANSLATED:
            problems.append('InfoPlist: "' + key + '" is the app name, which is never translated')
        elif isinstance(info.get(key), str):
            if english != info[key]:
                problems.append('InfoPlist: the English value of "' + key + '" differs from Info.plist')
        elif key not in names:
            problems.append('InfoPlist: "' + key + '" is neither an Info.plist key nor a type name in it')
    return problems


def check(root):
    """(problems, number of source keys, translated languages) for the tree at root."""
    problems = []
    catalogs = root / "packaging/Localization"
    declared = dict(TABLE.findall((root / "Sources/UnsitDesktop/Strings.swift").read_text(encoding="utf-8")))
    if not declared:
        return ["Sources/UnsitDesktop/Strings.swift declares no string tables"], 0, []
    used = {table: {} for table in declared.values()}
    for path in sorted((root / "Sources").rglob("*.swift")):
        name = path.relative_to(root).as_posix()
        text = path.read_text(encoding="utf-8")
        try:
            found = calls(text)
        except (ValueError, IndexError) as error:
            problems.append(name + ": cannot read its localized calls: " + str(error))
            continue
        for function, key, count, line in found:
            where = name + ":" + str(line)
            if function not in declared:
                problems.append(where + ": Strings." + function + " is not a declared table")
            elif key is None:
                problems.append(where + ": the key must be a plain string literal so that this check can see it")
            else:
                used[declared[function]].setdefault(key, []).append((where, count))
        if name != "Sources/UnsitDesktop/Strings.swift":
            stripped = strip_comments(text)
            for match in BARE.finditer(stripped):
                problems.append(name + ":" + str(stripped.count("\n", 0, match.start()) + 1)
                                + ": user-facing literal bypasses the string catalogs; use Strings.<table>(...)")
    if (catalogs / "Localizable.xcstrings").exists():
        problems.append("Localizable.xcstrings must not exist: tables are named for what they hold, and a default "
                        "table would hide bare SwiftUI literals from this check")
    on_disk = {path.stem for path in catalogs.glob("*.xcstrings")}
    for table in sorted((on_disk ^ (set(used) | {"InfoPlist"})) - {"Localizable"}):
        problems.append(table + ".xcstrings: every table needs both a catalog and a declaration in Strings.swift")
    locales = {}
    for table in sorted(on_disk):
        try:
            catalog = json.loads((catalogs / (table + ".xcstrings")).read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            problems.append(table + ".xcstrings is not valid JSON: " + str(error))
            continue
        source = catalog.get("sourceLanguage", "")
        strings = catalog.get("strings", {})
        locales[table] = {locale for entry in strings.values() for locale in entry.get("localizations", {})} - {source}
        for key, entry in strings.items():
            problems += check_entry(table, key, entry, source)
        if table == "InfoPlist":
            problems += check_info(catalog, plistlib.loads((root / "packaging/Info.plist").read_bytes()), source)
            continue
        for key, sites in sorted(used.get(table, {}).items()):
            if key not in strings:
                problems.append(sites[0][0] + ': "' + key + '" has no entry in ' + table + ".xcstrings")
                continue
            for where, count in sites:
                if count != len(placeholders(key)):
                    problems.append(where + ': "' + key + '" is given ' + str(count) + " format argument(s)")
        for key in sorted(strings.keys() - used.get(table, {}).keys()):
            problems.append(table + ': "' + key + '" is not used by the source; retire it in the pipeline, then delete it')
    everywhere = set().union(*locales.values()) if locales else set()
    for table, present in sorted(locales.items()):
        if present != everywhere:
            problems.append(table + ".xcstrings lacks " + ", ".join(sorted(everywhere - present))
                            + ": every table must carry the same languages, or the app mixes them")
    return problems, sum(len(keys) for keys in used.values()), sorted(everywhere)


def main():
    problems, keys, languages = check(ROOT)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        raise SystemExit("Localization check failed: " + str(len(problems)) + " problem(s)")
    print("Localization OK: " + str(keys) + " source keys, translated into " + str(len(languages)) + " language(s)")


if __name__ == "__main__":
    main()
