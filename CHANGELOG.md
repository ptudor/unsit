# Changelog

## 1.2.0

- Translate the app into 83 additional languages and regional variants, from
  Afrikaans to Zulu, including Arabic, Chinese (Simplified and Traditional),
  French, German, Hindi, Japanese, Korean, Portuguese, Russian, and Spanish.
  macOS picks the language from System Settings; the CLI, the Details sheet,
  the `(extracted)` folder suffix, and Help stay English.
- Prepare the app for translation: route every interface string, menu, alert,
  status, and update error through String Catalogs with translator comments, and
  give counts real plural forms instead of English-only "file/files" wording.
- Compile the catalogs into the app bundle, declare English as the development
  language, and localize the Finder file kind and copyright line.
- Add `scripts/check-localization.py` to `make check` and CI, and require every
  bundled language to carry every string table during release verification.
- Rename the update sheet's "Check" menu to "Check frequency".

See [release notes](docs/release-notes/v1.2.0.md) and
[localization](docs/localization.md).

## 1.0.0

- Add a native macOS app with drag-and-drop, multiple-archive queues, destination
  selection, cancellation, recovery details, and Finder access to output.
- Add scheduled GitHub update checks and verified installer downloads, with
  interval preferences, cancellation, compatibility checks, and retry backoff.
- Replace the method-13 decoder, bit reader, and Huffman tree with new MIT Swift
  implementations; document wire-format facts and fixed numeric data provenance.
- Recover additional members after damaged headers while keeping uncertain
  hierarchy and partial files explicit. Preserve independently recoverable forks.
- Credit Unsit for recovering files despite damage, show complete/partial/failed
  counts, keep recovery folders visible, and add a versioned `--json` report.
- Accept nonzero folder summary lengths and restore folder dates after children.
- Preserve existing output, reject unsafe paths and symlink traversal, bound
  resources, and publish members atomically with checked writes and metadata.
- Fix CLI argument actions and quiet output; add `--version`.
- Make scratch-build tests select the executable from their own build directory.
- Add comprehensive preset probes verified against an external decoder, native
  app-helper and updater tests, DMG/ZIP packaging, CI, checksums, source archives, attestations,
  MIT licensing, contribution guidance, and security reporting.
- Add the repeatable `RELEASE.md` runbook, Developer ID signing with Hardened
  Runtime, app and DMG notarization/stapling, final package verification,
  notarization receipts, and checks of the published feed through the real updater.

See [release notes](docs/release-notes/v1.0.0.md) and
[measured recovery results](docs/verification.md).
