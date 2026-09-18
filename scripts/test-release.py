#!/usr/bin/env python3
"""Offline regression checks for release rejection paths."""
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


package = module("package", "package.py")
verify = module("verify_release", "verify-release.py")
publish = module("publish_release", "publish-release.py")


class DraftAPI:
    """A draft is visible to listing/ID lookups, never the published-tag API."""
    def __init__(self, release=None):
        self.release = release
        self.created = 0
        self.uploaded = []
        self.hashes = {"app.dmg": "a" * 64, "checksums.txt": "b" * 64}

    def call(self, *args):
        if args[:2] == ("api", "repos/example/unsit/releases?per_page=100"):
            return json.dumps([[{"tag_name": "v0.9.0"}], [self.release] if self.release else []])
        if args[:2] == ("api", "repos/example/unsit/releases/42"):
            return json.dumps(self.release)
        if args[:2] == ("release", "create"):
            self.created += 1
            self.release = {"id": 42, "tag_name": args[2], "draft": True, "assets": []}
            return "draft created"
        if args[:2] == ("release", "upload"):
            name = Path(args[3]).name
            self.uploaded.append(name)
            self.release["assets"].append({"name": name, "digest": "sha256:" + self.hashes[name]})
            return "uploaded"
        raise AssertionError("Unexpected API access: " + repr(args))

    def prepare(self):
        with patch.object(publish, "gh", side_effect=self.call):
            publish.prepare_draft("example/unsit", "v1.0.0", Path("dist"), self.hashes)


class ReleaseChecks(unittest.TestCase):
    def test_creates_and_populates_draft_without_published_tag_lookup(self):
        api = DraftAPI()
        api.prepare()
        self.assertEqual(api.created, 1)
        self.assertEqual(set(api.uploaded), api.hashes.keys())
        self.assertTrue(api.release["draft"])

    def test_resumes_paginated_draft_without_replacing_matching_assets(self):
        api = DraftAPI({"id": 42, "tag_name": "v1.0.0", "draft": True,
                        "assets": [{"name": "app.dmg", "digest": "sha256:" + "a" * 64}]})
        api.prepare()
        self.assertEqual(api.created, 0)
        self.assertEqual(api.uploaded, ["checksums.txt"])

    def test_published_release_cannot_be_replaced(self):
        api = DraftAPI({"id": 42, "tag_name": "v1.0.0", "draft": False, "assets": []})
        with self.assertRaisesRegex(SystemExit, "already published"):
            api.prepare()
        self.assertEqual((api.created, api.uploaded), (0, []))

    def test_mismatching_draft_asset_stops_before_upload(self):
        api = DraftAPI({"id": 42, "tag_name": "v1.0.0", "draft": True,
                        "assets": [{"name": "app.dmg", "digest": "sha256:" + "c" * 64}]})
        with self.assertRaisesRegex(SystemExit, "Existing draft asset differs"):
            api.prepare()
        self.assertEqual((api.created, api.uploaded), (0, []))

    def test_duplicate_tagged_drafts_are_ambiguous(self):
        pages = [[{"tag_name": "v1.0.0"}], [{"tag_name": "v1.0.0"}]]
        with patch.object(publish, "gh", return_value=json.dumps(pages)):
            with self.assertRaisesRegex(SystemExit, "Multiple releases"):
                publish.find_release("example/unsit", "v1.0.0")

    def test_rejects_development_identity(self):
        listing = '1) ' + 'A' * 40 + ' "Apple Development: Example (0123456789)"'
        with self.assertRaises(ValueError):
            package.developer_identity('A' * 40, listing)

    def test_selects_exact_developer_id_identity(self):
        name = 'Developer ID Application: Example (0123456789)'
        listing = '1) ' + 'A' * 40 + ' "' + name + '"'
        self.assertEqual(package.developer_identity(name, listing), ('A' * 40, name, '0123456789'))
        self.assertEqual(package.developer_identity('a' * 40, listing)[0], 'A' * 40)
        with self.assertRaises(ValueError):
            package.developer_identity('Example', listing)

    def test_rejects_ambiguous_identity(self):
        name = 'Developer ID Application: Example (0123456789)'
        listing = '\n'.join(str(i) + ') ' + c * 40 + ' "' + name + '"' for i, c in [(1, 'A'), (2, 'B')])
        with self.assertRaises(ValueError):
            package.developer_identity(name, listing)

    def test_requires_accepted_notary_status_and_identifier(self):
        submission = {'id': '01234567-89ab-cdef-0123-456789abcdef', 'status': 'Accepted'}
        self.assertEqual(package.accepted_submission(submission), submission)
        for value in [None, {}, dict(submission, status='Invalid'), dict(submission, status='In Progress'),
                      dict(submission, id=''), dict(submission, id=None)]:
            with self.assertRaises(ValueError):
                package.accepted_submission(value)

    def test_manifest_detects_altered_download(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            asset = directory / 'Sample.dmg'
            asset.write_bytes(b'original')
            manifest = directory / 'checksums.txt'
            manifest.write_text(verify.sha256(asset) + '  Sample.dmg\n')
            self.assertIn('Sample.dmg', verify.verify_checksums(directory, manifest))
            asset.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'Checksum mismatch'):
                verify.verify_checksums(directory, manifest)

    def test_manifest_rejects_escape_duplicate_and_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            asset = directory / 'Sample.dmg'
            asset.write_bytes(b'original')
            line = verify.sha256(asset) + '  Sample.dmg\n'
            manifest = directory / 'checksums.txt'
            for contents in [line + line, line.replace('Sample.dmg', '../Sample.dmg'), '']:
                manifest.write_text(contents)
                with self.assertRaises(ValueError):
                    verify.verify_checksums(directory, manifest)
            (directory / 'Link.dmg').symlink_to(asset)
            manifest.write_text(line.replace('Sample.dmg', 'Link.dmg'))
            with self.assertRaises(ValueError):
                verify.verify_checksums(directory, manifest)

    def test_zip_rejects_unsafe_paths_before_extraction(self):
        for name in ['../escape', '/absolute', 'Unsit.app/../../escape', 'Unsit.app/..\\escape', 'Other.app/file']:
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, 'w') as archive:
                archive.writestr(name, b'data')
            with zipfile.ZipFile(stream) as archive:
                with self.assertRaises(ValueError):
                    verify.check_zip_paths(archive)

    def test_development_language_table_holds_every_key_but_plural_rules(self):
        catalog = {'sourceLanguage': 'en', 'strings': {
            'Ready': {'comment': 'Status.'},
            'Details': {'comment': 'Button.', 'localizations': {'fr': {'stringUnit': {'value': 'Détails'}}}},
            'NSHumanReadableCopyright': {'localizations': {'en': {'stringUnit': {'value': 'Copyright 2026'}}}},
            'Extracted %lld files': {'localizations': {'en': {'variations': {'plural': {
                'one': {'stringUnit': {'value': 'Extracted %lld file'}}, 'other': {'stringUnit': {'value': 'Extracted %lld files'}}}}}}}}}
        self.assertEqual(package.source_table(catalog, 'en'),
                         ({'Ready': 'Ready', 'Details': 'Details', 'NSHumanReadableCopyright': 'Copyright 2026'}, True))
        del catalog['strings']['Extracted %lld files']
        self.assertEqual(package.source_table(catalog, 'en')[1], False)
        with self.assertRaises(ValueError):
            package.source_table(catalog, 'fr')

    def test_zip_requires_every_string_table_in_every_language(self):
        def bundle(languages):
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, 'w') as archive:
                for language, files in languages.items():
                    archive.writestr('Unsit.app/Contents/Resources/' + language + '.lproj/', b'')
                    for name in files:
                        archive.writestr('Unsit.app/Contents/Resources/' + language + '.lproj/' + name, b'data')
            return zipfile.ZipFile(stream)
        tables = [name + '.strings' for name in ('Extraction', 'InfoPlist', 'Menus', 'Updates')]
        info = {'CFBundleDevelopmentRegion': 'en'}
        verify.check_localizations(bundle({'en': tables, 'pt-BR': tables + ['Extraction.stringsdict']}), info)
        for languages in [{}, {'fr': tables}, {'en': tables, 'fr': tables[:3]}, {'en': tables, 'zh': []},
                          {'en': tables, 'zh': ['Extraction.stringsdict']}]:
            with self.assertRaises(ValueError):
                verify.check_localizations(bundle(languages), info)
        with self.assertRaises(ValueError):
            verify.check_localizations(bundle({'en': tables}), {})
        with self.assertRaisesRegex(ValueError, r'fr has Extraction, InfoPlist, Menus; zh has none'):
            verify.check_localizations(bundle({'en': tables, 'fr': tables[:3], 'zh': ['Extraction.stringsdict']}), info)

    def test_zip_rejects_symlinks_before_extraction(self):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as archive:
            info = zipfile.ZipInfo('Unsit.app/Contents/link')
            info.create_system = 3
            info.external_attr = 0o120777 << 16
            archive.writestr(info, '/outside')
        with zipfile.ZipFile(stream) as archive:
            with self.assertRaises(ValueError):
                verify.check_zip_paths(archive)


if __name__ == '__main__':
    unittest.main()
