# Changelog

## 1.0.0 — prepared

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

See [release notes](docs/release-notes/v1.0.0.md) and
[measured recovery results](docs/verification.md).
