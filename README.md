# Unsit

Open classic StuffIt archives on macOS, with a drag-and-drop app or the `unsit`
command-line tool. Files keep their data forks, resource forks, type and creator
codes, Finder flags, and modification dates.

Unsit supports classic `SIT!` / `rLau` containers with stored and method-13
compression. StuffIt 5 containers, StuffIt X (`.sitx`), encrypted forks, and other
compression methods are outside its current scope.

## macOS app

Drop one or more `.sit` files into Unsit, or use **File → Open Archives**. Each
archive gets a fresh output folder beside the original. Use **Save To** to choose
another destination, then **Open Folder** to see the recovered files in Finder.
Existing archives and extracted files are preserved.

If you close the window, choose **Window → Show Unsit** (**⌘0**) or click Unsit
in the Dock to reopen it. Your extraction queue and results remain available.

When damage is detected, the app says **Unsit recovered N files despite archive
damage**, with complete, partial, and failed counts. It credits files recovered
beyond damaged records and makes their recovery folders visible in Finder.
**Details** explains problems; **Stop** stops the current extraction
and queued work while keeping files already recovered. The app uses the same
extractor as the CLI and does not require an installed command-line tool.

**Unsit → Check for Updates** checks GitHub releases. Stable release builds also
check automatically; choose every six hours, daily, or weekly, or turn checks off.
Unsit verifies the download before opening its installer. Finish extracting, quit
the app, and drag the new copy into Applications. See [updates](docs/updates.md).

Build the app with the Xcode command-line tools and Swift 5.7 or later:

```sh
make app
open dist/Unsit.app
```

The app requires macOS 12 or later. `make universal` builds an app and CLI with
both Apple silicon and Intel slices. Packaging produces an installer DMG, app ZIP,
CLI archive, source archive, and update/checksum manifests in `dist/`. App archives currently use ad hoc
signing; they are not Developer ID signed or notarized. See [builds and
releases](docs/releases.md) for installation, verification, and publication.

## Command line

The CLI targets macOS 11 or later:

```sh
swift build -c release --product unsit
.build/release/unsit archive.sit recovered-files
.build/release/unsit --list archive.sit
```

```text
unsit [options] <archive.sit> [output-directory]

  -l, --list        List contents without extracting
  -o, --output DIR  Extract into DIR
  -q, --quiet       Only warnings/errors during extraction
      --json        Extraction report on stdout, warnings on stderr
      --no-verify   Skip fork CRC checks, retain structural checks
      --self-test   Run built-in table/CRC checks
      --version     Show version
  -h, --help        Show help
      --           End options; remaining tokens are paths
```

Without an output directory, the CLI creates a folder named after the archive in
the current directory. Unlike the app, it uses the requested destination directly;
conflicting members are skipped. `--list --quiet` still prints the requested list.
Exit status is `0` for success, `1` for incomplete restoration or validation, and
`2` for invalid arguments.

## Recovery and integrity

Unsit validates entry headers, fork lengths, and CRC-16/ARC checksums. Damage to
one member does not automatically stop later recoverable members. A valid fork
can survive damage to the other fork, and safe decoder prefixes are retained.

Incomplete members use `NAME.partial-HEADER_OFFSET`. After a lost header makes
folder placement uncertain, identifiable files go into
`unsit-recovery-HEADER_OFFSET/NAME`. These names distinguish damaged bytes and
uncertain placement from fully restored members. Warnings and a nonzero exit
status remain available even in quiet mode.

Damage is reported as **possible bitrot**, with the number of files Unsit saved;
this does not claim to determine the cause or reconstruct missing bytes. An
unsupported method, a skipped count check, or a disk/metadata error is reported
as a warning without being called bitrot. Counts describe files Unsit identified;
unreadable archive regions can contain additional members it cannot count.

In a local compatibility comparison, the updated extractor recovered **1,095
members versus 290** from the initial implementation. All 290 earlier members'
data forks, resource forks, and file metadata were preserved; 805 additional
members were recovered. Of the new total, 56 members remain explicitly partial.
These are measured recovery results, not a promise that damaged bytes can be
repaired. See [verification and its limits](docs/verification.md).

Output uses native macOS forks and descriptor-based filesystem operations.
Existing files are preserved, symlink traversal is rejected, and members are
published atomically after their forks and metadata have been attempted. Folder
modification dates are restored after their children. APFS is recommended for
retaining native Mac metadata.

Default resource limits are 256 MiB input, 64 MiB per decoded fork, 512 MiB decoded
output, 100,000 records, 128 nested folders, and 1 MiB of recovery scanning. The
CLI provides `--max-input-bytes`, `--max-fork-bytes`, `--max-total-bytes`,
`--max-members`, `--max-depth`, and `--max-recovery-bytes` overrides. See
[extraction behavior](docs/behavior.md) for the full contract.

## Development and verification

```sh
swift test
make check
python3 scripts/verify-method13.py --binary .build/debug/unsit
```

The native suite covers malformed archives, both forks, every preset codebook,
dynamic Huffman tables, filesystem confinement, interrupted writes, resource
limits, dates, CLI actions, and the app's helper workflow. Synthetic fixtures have
frozen expected bytes or hashes. No private archive or network connection is
required. A custom `swift test --scratch-path DIR` uses the executable built beside
that test bundle; `UNSIT_TEST_BINARY` explicitly selects another executable.

The package contains the `unsit` and `UnsitApp` executable targets plus the
`UnsitDesktop` helper/updater library and shared `UnsitReport` schema. For development without packaging:

```sh
swift build
swift run --skip-build UnsitApp
```

[Contributing](CONTRIBUTING.md) · [Security reporting](SECURITY.md) ·
[Container format](docs/format.md) · [Method 13](docs/method-13.md) ·
[Changelog](CHANGELOG.md)

## License

Current source is licensed under [MIT](LICENSE). The method-13 implementation was
replaced with new Swift code using a canonical range decoder and bounded output
history. Fixed numeric codebooks are maintained separately as interoperability
data, with their provenance and reference notices retained in
[third-party notices](THIRD_PARTY_NOTICES.md). No GPL or LGPL implementation is
bundled or linked by the app or CLI. Historical revisions retain their original
licensing provenance.
