#!/usr/bin/env python3
"""Offline regression checks for the localization check's rejection paths."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


localization = module("check_localization", "check-localization.py")

TABLES = '''public enum Strings {
    public static func extraction(_ key: String, _ arguments: CVarArg...) -> String {
        lookup(key, table: "Extraction", arguments: arguments)
    }
}
'''
VIEW = '''Text(verbatim: wordmark)
Text(Strings.extraction("Ready"))
Text(Strings.extraction("Extracted %lld files", report.recoveredFiles))
'''


def plural(one, other):
    return {"variations": {"plural": {"one": {"stringUnit": {"value": one}}, "other": {"stringUnit": {"value": other}}}}}


def strings():
    return {"Ready": {"comment": "Status label."},
            "Extracted %lld files": {"comment": "Headline; %lld counts files.",
                                     "localizations": {"en": plural("Extracted %lld file", "Extracted %lld files")}}}


class LocalizationChecks(unittest.TestCase):
    def problems(self, view=VIEW, extraction=None, info_strings=None, info=None, extra=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for directory in ("Sources/UnsitDesktop", "Sources/UnsitApp", "packaging/Localization"):
                (root / directory).mkdir(parents=True)
            (root / "Sources/UnsitDesktop/Strings.swift").write_text(TABLES)
            (root / "Sources/UnsitApp/View.swift").write_text(view)
            plist = {"CFBundleDevelopmentRegion": "en", "CFBundleDocumentTypes": [{"CFBundleTypeName": "Classic StuffIt archive"}]}
            (root / "packaging/Info.plist").write_bytes(plistlib.dumps(plist if info is None else info))
            catalogs = {"Extraction": strings() if extraction is None else extraction,
                        "InfoPlist": {"Classic StuffIt archive": {"comment": "Finder kind."}} if info_strings is None else info_strings}
            catalogs.update(extra or {})
            for name, entries in catalogs.items():
                (root / "packaging/Localization" / (name + ".xcstrings")).write_text(
                    json.dumps({"sourceLanguage": "en", "strings": entries, "version": "1.0"}))
            return localization.check(root)[0]

    def assertProblem(self, pattern, **tree):
        found = self.problems(**tree)
        self.assertEqual(len(found), 1, found)
        self.assertRegex(found[0], pattern)

    def test_accepts_matching_source_and_catalogs(self):
        self.assertEqual(self.problems(), [])

    def test_reads_calls_past_nested_arguments_strings_and_comments(self):
        source = '''// Strings.extraction("In a comment")
let url = "https://unsit.invalid/help" // Strings.extraction("After a URL")
Strings.extraction("Cannot open: %@", String(cString: strerror(errno)))
Strings.updates("%1$@ (%2$@), then", describe(a, [b, c]), "x, \\(y(1, 2))")
Strings.menus(title)
'''
        self.assertEqual(localization.calls(source), [("extraction", "Cannot open: %@", 1, 3),
                                                      ("updates", "%1$@ (%2$@), then", 2, 4), ("menus", None, 0, 5)])

    def test_reads_format_arguments(self):
        self.assertEqual(localization.placeholders("100%% of %lld files in %@"), [(1, "lld"), (2, "@")])
        self.assertEqual(localization.placeholders("macOS %2$@ for %1$@"), [(1, "@"), (2, "@")])
        for unsafe in ("%d files", "%s", "%1$@ and %@"):
            with self.assertRaises(ValueError):
                localization.placeholders(unsafe)

    def test_rejects_source_and_catalog_drift(self):
        self.assertProblem('"Waiting" has no entry', view=VIEW + 'Text(Strings.extraction("Waiting"))\n')
        self.assertProblem('"Stopped" is not used', extraction=dict(strings(), Stopped={"comment": "Status label."}))
        self.assertProblem("must be a plain string literal", view=VIEW + "Text(Strings.extraction(job.status))\n")
        self.assertProblem("not a declared table", view=VIEW + 'Text(Strings.settings("Ready"))\n')
        self.assertProblem("given 0 format argument", view=VIEW + 'Text(Strings.extraction("Extracted %lld files"))\n')

    def test_rejects_literals_that_bypass_the_catalogs(self):
        for bare in ('Text("Ready")', 'Button("Stop", action: stop)', 'alert.messageText = "Quit?"',
                     'throw UpdateError("Too large.")', '.help("Save alongside")'):
            self.assertProblem("bypasses the string catalogs", view=VIEW + bare + "\n")
        self.assertProblem("Localizable.xcstrings must not exist", extra={"Localizable": {}})

    def test_rejects_entries_translators_cannot_work_from(self):
        entries = strings()
        entries["Ready"] = {}
        self.assertProblem("no translator comment", extraction=entries)
        entries = strings()
        del entries["Extracted %lld files"]["localizations"]
        self.assertProblem("needs 'one' and 'other' plural variations", extraction=entries)

    def test_rejects_translations_that_would_misread_their_arguments(self):
        entries = strings()
        entries["Extracted %lld files"]["localizations"]["fr"] = plural("Un fichier extrait", "%lld fichiers extraits")
        entries["Ready"]["localizations"] = {"fr": {"stringUnit": {"value": "Prêt"}}}
        info = {"Classic StuffIt archive": {"comment": "Finder kind.", "localizations": {"fr": {"stringUnit": {"value": "Archive StuffIt classique"}}}}}
        self.assertEqual(self.problems(extraction=entries, info_strings=info), [])
        entries["Extracted %lld files"]["localizations"]["fr"] = plural("%@ fichier extrait", "%lld fichiers extraits")
        self.assertProblem(r"\[fr \(one\)\] does not use the same format arguments", extraction=entries, info_strings=info)

    def test_rejects_a_language_missing_from_one_table(self):
        entries = strings()
        entries["Ready"]["localizations"] = {"fr": {"stringUnit": {"value": "Prêt"}}}
        self.assertProblem("InfoPlist.xcstrings lacks fr", extraction=entries)

    def test_rejects_info_plist_drift(self):
        named = {"Classic StuffIt archive": {"comment": "Finder kind."}}
        self.assertProblem("app name, which is never translated", info_strings=dict(named, CFBundleName={"comment": "Name."}))
        self.assertProblem("neither an Info.plist key nor a type name", info_strings=dict(named, Archive={"comment": "Kind."}))
        self.assertProblem('"Classic StuffIt archive" is shown by macOS', info_strings={})
        self.assertProblem("CFBundleDevelopmentRegion", info={"CFBundleDocumentTypes": [{"CFBundleTypeName": "Classic StuffIt archive"}]})
        copyright = {"comment": "About window.", "localizations": {"en": {"stringUnit": {"value": "Copyright 2025"}}}}
        self.assertProblem('English value of "NSHumanReadableCopyright" differs', info_strings=dict(named, NSHumanReadableCopyright=copyright),
                           info={"CFBundleDevelopmentRegion": "en", "NSHumanReadableCopyright": "Copyright 2026",
                                 "CFBundleDocumentTypes": [{"CFBundleTypeName": "Classic StuffIt archive"}]})


if __name__ == '__main__':
    unittest.main()
