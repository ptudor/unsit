# unsit

A command-line tool for macOS that extracts **classic StuffIt archives**
(`SIT!` / `rLau` signature — the StuffIt 1.5 / StuffIt Deluxe era, roughly
1990–2000, *not* the later StuffIt 5 `.sitx` format).

It reconstructs each member as a native macOS file: the data fork becomes the
file's contents, the resource fork is written to the file's `..namedfork/rsrc`,
and the original type/creator, Finder flags, and modification date are restored.

## Build

Requires the Swift toolchain (Xcode command-line tools).

```sh
cd unsit
swift build -c release
# binary at .build/release/unsit
```

## Usage

```sh
unsit [options] <archive.sit> [output-directory]

  -l, --list        List archive contents without extracting
  -o, --output DIR  Extract into DIR (default: a folder named after the archive)
  -q, --quiet       Only print warnings and errors
      --no-verify   Skip fork CRC verification
      --self-test   Run built-in table/CRC self-checks and exit
  -h, --help        Show this help
```

Example:

```sh
unsit "kan U haq.sit"          # extracts into ./kan U haq/
unsit -l Documents.sit         # list contents
```

## What it supports

- **Container**: the classic StuffIt format — 22-byte archive header, 112-byte
  per-entry headers, nested folders (start/end markers `0x20` / `0x21`).
- **Compression methods**: `0` (stored) and `13` (LZ + dynamic Huffman). These
  are the only methods present in the target archives; any other method is
  reported as an error rather than silently skipped.
- **Integrity**: every 112-byte entry header is validated against its stored
  **CRC-16/ARC**, and every decompressed fork is checked against the header's
  `rsrcCRC` / `dataCRC`. Mismatches are reported but do not stop extraction.

## Robustness: recovery past damaged members

These particular archives are ~30 years old and a handful of members are
physically damaged (their compressed data no longer matches the stored
checksums). The reference tool, `unar` (The Unarchiver), **aborts the whole
archive** at the first bad member — e.g. it stops at `fearth.gif` in
`Documents.sit` and extracts only the ~46 files before it.

`unsit` instead validates each entry position with the header CRC and, on a
mismatch, **resyncs forward** to the next valid header, so it recovers the
members *after* the damage too (136 files from `Documents.sit` vs. unar's 46).
The genuinely-corrupt forks are still emitted on a best-effort basis and clearly
flagged with a CRC warning.

### Correctness

For every member that both tools extract, `unsit`'s output — data fork *and*
resource fork — is **byte-for-byte identical to `unar`**, verified across all
three sample archives (`kan U haq.sit`, `Documents.sit`, `desk.sit`). On the
damaged forks, `unsit` reproduces exactly the same best-effort bytes the
reference decoder produces (it uses the same zero-initialized 64 KiB circular
window semantics), so no tool can do better with the data that survives.

The 20 forks (out of ~290) that fail CRC across the three archives are damaged
at the source; `unar` produces identical corrupt output for them where it
reaches them at all.

## Format notes (verified)

Per-entry header (112 bytes, big-endian), offsets that were confirmed by
validating the stored header CRC:

| Offset | Size | Field                          |
|-------:|-----:|--------------------------------|
| 0      | 1    | resource-fork compression method |
| 1      | 1    | data-fork compression method     |
| 2      | 1    | filename length (≤ 31)           |
| 3      | 31   | filename (Mac Roman)             |
| 66     | 4    | file type (OSType)               |
| 70     | 4    | creator (OSType)                 |
| 74     | 2    | Finder flags                     |
| 76     | 4    | creation date (Mac 1904 epoch)   |
| 80     | 4    | modification date                |
| 84     | 4    | resource fork uncompressed length|
| 88     | 4    | data fork uncompressed length    |
| 92     | 4    | resource fork compressed length  |
| 96     | 4    | data fork compressed length      |
| 100    | 2    | resource fork CRC-16/ARC         |
| 102    | 2    | data fork CRC-16/ARC             |
| 110    | 2    | header CRC-16/ARC (over bytes 0–109) |

Folders are marked when either method byte is `0x20` (start) or `0x21` (end) and
carry no fork payload. For a file, the compressed resource fork immediately
follows the header, then the compressed data fork.

## Provenance and licensing

The StuffIt **method 13** decompression algorithm and its constant Huffman
tables (the five preset code-length tables and the metacode) were derived from
[XADMaster](https://github.com/MacPaw/XADMaster)'s `XADStuffIt13Handle.m`, which
is licensed **LGPL-2.1**. The Swift code here is an independent reimplementation;
the numeric tables are format constants (like a CRC polynomial) required for
interoperability. If you redistribute this tool, treat it as an LGPL-2.1
derivative and retain this attribution.

The container parser, CRC-16/ARC implementation, and the macOS fork/metadata
writer are original and were validated against the sample archives.

## Automated verification

Run `swift test` on macOS from a clean checkout. The native suite builds the CLI,
uses isolated temporary directories, and includes redistributable synthetic
archives with explicit expected bytes. See `Tests/unsitTests/Fixtures/README.md`
for fixture provenance and the separate historical-corpus/minimum-platform gates.

Extraction preserves existing destinations: conflicting files or folders are
skipped with a warning and a nonzero result. Unrelated archive folders are never
merged. Unsafe empty, `.` and `..` member names are rejected; descendants of a
blocked folder are skipped until its closing marker. Output roots and their
path components must be ordinary directories, without symlinks. Member data,
resource forks, and metadata use the same opened descriptors. Displayed control
characters are escaped; safe Mac Roman names and `/` to `:` mapping are retained.

Resource limits apply before allocation/output: input 256 MiB, decoded fork
64 MiB, aggregate decoded output 512 MiB, 100,000 member records, nesting 128,
and 1 MiB of recovery scanning. Deliberately override individual limits with
`--max-input-bytes N`, `--max-fork-bytes N`, `--max-total-bytes N`,
`--max-members N`, `--max-depth N`, or `--max-recovery-bytes N` (nonnegative
integers, bytes where applicable). Input is read in bounded chunks; at most the
bounded input, a compressed fork copy, and the two bounded decoded forks are
retained. Reservations include damaged stored output and are not refunded for
failed members. List mode enforces input, member, nesting, and recovery limits.

Compressed EOF, invalid Huffman tables, contradictory fork lengths, and premature
end markers are structural errors even with `--no-verify`. Zero/zero fork lengths
mean an absent fork regardless of the unused method byte. Method 13 preserves the
reference's 64 KiB zero-initialized history and length-delimited completion,
including a terminal match spanning the declared boundary; no extra terminator
is required. Dynamic lengths -1 and zero denote omitted symbols.

Both archive signatures and the declared extent are validated. Bytes outside the
declared extent are diagnosed and not parsed. Incomplete headers/payloads,
resynchronization and unbalanced folders return nonzero in list and extraction
modes. Version-1 header counts are checked against root files plus root folders
(each complete folder counts once). Count enforcement for other classic header
versions is unverified and explicitly diagnosed with a nonzero result.

Recovery candidates require structural plausibility in addition to CRC. After a
lost header, hierarchy remains uncertain: independently identified files go to
`.unsit-recovery-HEADER_OFFSET/NAME` under the output root. These directories use
exclusive creation; a collision is reported and skipped. List mode reports the
same intended recovery paths. Folder flags `0x10` (contains encrypted children)
and `0x80` are separated from `0x20`/`0x21` marker values in either method field;
encrypted nonempty file forks remain unsupported.

Each member is built as a unique `.unsit-tmp-UUID` sibling, then both native
forks are flushed, metadata is attempted independently, and close is checked
before exclusive atomic publication. A damaged fork or failed restoration uses
`NAME.partial-HEADER_OFFSET` with per-fork/operation warnings and a nonzero
result. Complete and partial members are counted separately. An independently
valid fork and safe decoder prefixes survive a failure in the other fork; a
failed fork is never described as an absent clean fork. CRC-damaged bytes remain
recoverable under this partial-name policy. Existing complete or partial output
is preserved even if publication collides.

Handled failures clean up their temporary pathname within the opened directory.
Abrupt termination can leave a clearly named `.unsit-tmp-UUID` orphan; it cannot
appear as a completed member. The tool does not automatically delete preexisting
orphans. File `fsync` and close are checked; atomic visibility is guaranteed for
publication, but crash/power-loss durability of the directory entry is not
promised. Resource forks use bounded positional `fsetxattr` on the member's
file descriptor, avoiding a second pathname-based resource open/close.
