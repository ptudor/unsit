# Deep code review — unsit

Review date: 2026-09-06 (America/Los_Angeles). Source baseline: `de48bad3c1d3c7b29e11ae9bf834f977b3f70c14`, branch `main`. This is an analysis-only review: no source, package, or README changes are authorized or included. All locations refer to that baseline. IDs remain stable across review checkpoints.

## Scope and method

Read all 12 tracked files, 1,308 lines: `.gitignore`, `Package.swift`, `README.md`, and all nine Swift files in `Sources/unsit/`: `main.swift`, `SITArchive.swift`, `MacFileWriter.swift`, `StuffIt13.swift`, `StuffIt13Tables.swift`, `PrefixCode.swift`, `BitReaderLE.swift`, `CRC16.swift`, and `SelfTest.swift`. There are no other tracked targets, fixtures, dependencies, tests, CI workflows, or repository instruction files. The initial working tree was clean.

Traced command-line arguments → input bytes → archive/header recovery → folder state → fork slicing → Huffman/LZ decoding → length/CRC checks → data/resource fork writes → metadata → diagnostics and exit status. Reviewed list mode separately from extraction. The program is synchronous; concurrency exposure comes from other processes changing filesystem paths between pathname-based operations.

Validation uses the unchanged executable and temporary, CRC-valid synthetic archives under `/tmp/unsit-ra6x-review/`. Fixtures touch only disposable output trees. The review deliberately does not run an unbounded allocation attack or modify real user files. Reproduction recipes below specify the essential inputs; the final report will include a reusable fixture builder and a complete verification record.

Status of this checkpoint: filesystem confinement, output collisions, stream completeness, and container recovery findings recorded; decoder table validation, writer failure paths, metadata, CLI, and coverage findings are being completed.

## Findings

### RA6X-001 — A parent-directory folder entry escapes the output root

- **Severity:** High
- **Status:** Confirmed by executable reproduction.
- **Location:** `Sources/unsit/SITArchive.swift:82–91` (`decodeName`); `Sources/unsit/main.swift:114–124`; `Sources/unsit/MacFileWriter.swift:39–44`.
- **Problem:** Removing slashes and NULs does not make a name a safe path component. `..` survives and becomes an actual parent directory when concatenated to the extraction path. A crafted archive can overwrite accessible files outside the requested output directory and apply directory metadata there. Empty names and `.` also alias existing directories; NUL removal can manufacture any of these names.
- **Evidence:** A valid start-folder header named `..`, a stored file `escaped` containing `ESCAPE`, and an end-folder marker extract to the sibling of `out`, not inside `out`. The command exits 0 with no warning. `dirStack.append(root + "/..")` is the controlling data flow. Header CRC validation provides no protection because the archive author can calculate it.
- **Fix specification:** Validate the final decoded component before any filesystem operation. Reject or deterministically rename empty names, `.` and `..`, including names that become those values after normalization/NUL handling; diagnose the member and preserve folder traversal state without writing through its rejected path. Add a containment invariant for every output operation. Keep valid Mac Roman names and the intentional `/` → `:` Finder mapping. Do not interpret member names as relative paths or add support for archive symlinks. Coordinate descriptor-based confinement with RA6X-002.
- **Verification:** Extract nested `..`, `.`, empty, NUL-only, and `..\0` folder fixtures inside a disposable parent containing sentinel files. Assert no outside bytes, metadata, or directory entries change; all unsafe names are diagnosed; later safe siblings remain recoverable. Run with and without `--no-verify`.

### RA6X-002 — Existing directory symlinks redirect extraction outside the root

- **Severity:** High
- **Status:** Confirmed for directory symlinks; pathname race exposure confirmed by source, race timing not exercised.
- **Location:** `Sources/unsit/main.swift:95–96, 114–124`; `Sources/unsit/MacFileWriter.swift:24–57, 76–87`.
- **Problem:** Valid-looking names are resolved through pre-existing directory symlinks. Each data, resource, and timestamp operation resolves a pathname again, allowing an external process to replace an ancestor between operations. Lexical name checks alone cannot confine writes. `XATTR_NOFOLLOW` protects only that specific xattr call's final component, not ancestor traversal or subsequent `open`/`utimes` calls.
- **Evidence:** Precreate `out/link` as a symlink to a disposable sibling directory. Extract a folder `link` containing file `escaped`. Its bytes appear in the sibling directory and the process exits 0. Control probes on this macOS showed that a final-component file symlink and a hard link were replaced by `createFile` without changing their original targets; this finding does not claim those two controls followed links.
- **Fix specification:** Establish an output-root directory descriptor and resolve/create each descendant relative to verified directory descriptors with no symlink following. Keep the descriptors through file creation, fork writes, and metadata restoration; use descriptor equivalents where available. Reject archive-member directory symlinks even when they already exist. Define root symlink handling explicitly: either reject it or resolve it once and anchor all writes to that opened directory. Do not rely on `realpath`/prefix checks followed by ordinary pathname writes. Preserve native macOS forks and successful extraction into ordinary directories.
- **Verification:** Repeat the directory-symlink fixture and assert the external sentinel and metadata are unchanged. Add a controlled ancestor-swap race between directory acquisition and file/fork writes, plus final-component symlink and hard-link controls. Verify safe extraction still works under an explicitly chosen ordinary root.

### RA6X-003 — Duplicate and colliding names silently destroy earlier output

- **Severity:** High
- **Status:** Confirmed by executable reproduction on the current case-insensitive filesystem.
- **Location:** `Sources/unsit/SITArchive.swift:82–91`; `Sources/unsit/main.swift:124–141`; `Sources/unsit/MacFileWriter.swift:24–28`.
- **Problem:** Every file is created at its final name with replacement behavior. Existing user files and earlier archive members are overwritten without warning or an explicit overwrite option. Mac Roman decoding/NUL removal and destination case/Unicode equivalence add collisions even when archive names differ. Success counters count processed entries rather than surviving files, concealing loss.
- **Evidence:** Two entries named `f` with contents `FIRST` and `SECOND` produce one file containing `SECOND`, while stdout says “Extracted 2 file(s)” and exit status is 0. The same happens with `File`/`file` and `f`/`f\0`. An existing `out/f` containing `ORIGINAL` becomes `REPLACED` without warning.
- **Fix specification:** Default to preserving existing output. Resolve collisions before committing a member: either keep both using deterministic unique names and report the mapping, or skip with a nonzero result. Use filesystem-aware, race-safe exclusive creation rather than only a Swift string set. Detect file/file, file/directory, duplicate-folder, case, normalization, and sanitized-name collisions. Explicitly protect the input archive if the chosen output location overlaps it. If overwrite support is introduced, require an explicit option and combine it with RA6X-016's member transaction. Preserve names for noncolliding members and native fork association; never silently merge unrelated archive folders.
- **Verification:** Test existing files, duplicate members with both forks, case-equivalent names, NUL-collapsed names, Unicode-equivalent names where supported, and file/directory collisions. Assert original bytes and metadata survive the default policy, no reported-success member disappears, and the input archive cannot be replaced accidentally.

### RA6X-004 — Compressed EOF is replaced with infinite zero bits and can pass CRC

- **Severity:** High
- **Status:** Confirmed by executable reproduction.
- **Location:** `Sources/unsit/BitReaderLE.swift:23–29`; `Sources/unsit/PrefixCode.swift:74–81`; `Sources/unsit/StuffIt13.swift:119–160`; `Sources/unsit/main.swift:135–138, 161–175`.
- **Problem:** Running out of compressed bytes is not surfaced as an error or recovery event. The reader supplies zeros indefinitely, and the decoder can fabricate the entire declared output from them. Fork CRC verification does not reliably expose this: CRC-16/ARC of any number of zero bytes is zero. This differs from the intentional zero-initialized LZ history window, which must not be removed indiscriminately.
- **Evidence:** A method-13 fork containing only selector byte `10` (hex), declared uncompressed length 4,096, and data CRC 0 produces 4,096 zero bytes, exits 0, and emits no warning. No encoded symbol exists after the selector. `fill` explicitly selects `0` whenever `bytePos >= data.count` and keeps incrementing the position.
- **Fix specification:** Track the actual compressed bit boundary and distinguish available bits from any bounded decoder lookahead padding. Consuming bits beyond the available stream must create a persistent truncation/recovery condition propagated to the fork and command result even when CRC matches or `--no-verify` is set. If preserving best-effort output, bound synthetic padding, mark it explicitly, and apply RA6X-015's resource budget. Keep correct LSB-first reading, valid byte-end padding, preset/dynamic decoding, and documented 64 KiB zero-initialized LZ history semantics.
- **Verification:** Reproduce selector-only input, every byte truncation of valid streams, and truncated dynamic tables/match extras. Assert no malformed stream is reported fully verified. Include CRC-0 all-zero expected output and `--no-verify`, plus valid streams ending at all eight bit alignments.

### RA6X-005 — Fork length mismatches are accepted as successful extraction

- **Severity:** High
- **Status:** Confirmed for stored forks and early method-13 end markers.
- **Location:** `Sources/unsit/SITArchive.swift:158–168`; `Sources/unsit/StuffIt13.swift:108–110, 139–140, 153–164`; `Sources/unsit/main.swift:161–175`.
- **Problem:** There is no invariant that a decoded fork contains its advertised number of bytes. Stored data ignores the uncompressed length; the method-13 end marker returns a short buffer; a final match is silently clipped. CRC checks are independent of length and are skipped altogether when the declared uncompressed length is zero. Truncated or contradictory files therefore appear complete.
- **Evidence:** A stored fork containing `A`, declared length 20, and CRC of `A` writes one byte and exits 0. A stored fork with five bytes, declared length 0, and deliberately wrong CRC also exits 0. Method-13 bytes `10 16` encode an immediate preset-1 end marker; declaring length 20 with CRC 0 writes an empty file and exits 0.
- **Fix specification:** Validate stored compressed/uncompressed length equality and require the actual decoded length to equal the declared length for a clean result. Classify premature end markers and contradictory zero-length declarations as structural damage independently of optional CRC checks. Record whether the expected-length boundary is reached in the middle of a match and validate the format's allowed terminal behavior before changing valid stream handling. Keep recoverable bytes under the explicit partial-output policy; do not silently pad, truncate, or rewrite header lengths to make verification pass. Do not require an additional terminator if the valid format allows length-delimited completion.
- **Verification:** Cover shorter/longer stored forks, zero/nonzero length contradictions, early end markers, exact output, final matches crossing the declared boundary, and both CRC modes. All length mismatches must be diagnosed and return nonzero even when the CRC of the returned bytes matches.

### RA6X-006 — Archive boundaries and incomplete traversal are not validated

- **Severity:** High
- **Status:** Confirmed by executable reproduction.
- **Location:** `Sources/unsit/SITArchive.swift:61–68, 130–152`; `Sources/unsit/main.swift:109–111, 153–157, 178–204`.
- **Problem:** The parser checks only `SIT!`, ignores `rLau` and archive length, stores but never uses the declared count, and silently stops on a partial final header or failed resynchronization. List mode never validates payload extents. Successfully resynchronized damage is omitted from extraction's final error condition, and list mode always returns 0 after warnings. Scripts cannot distinguish an intact archive from missing members or unexplained trailing data.
- **Evidence:** A 22-byte header declaring one missing entry, a 60-byte partial entry, and a final header with bad CRC each list zero files and exit 0 without warning. `SIT!` with `NOPE` instead of `rLau` is accepted. List mode reports a member whose compressed length exceeds EOF without error. A second valid entry appended beyond the header's declared archive length is extracted. A 17-byte resync gap emits warnings but returns 0. `onResync` is never called when no later header is found.
- **Fix specification:** Parse and validate both signatures and the declared archive extent, distinguish expected EOF from incomplete headers/payloads, and return a traversal report containing corruption, terminal gaps, and incomplete-member information to both CLI modes. Bound ordinary parsing to the declared archive extent; any deliberate salvage beyond it must be explicit and diagnosed. Verify the format/version meaning of `numFiles` (including folder counting) before enforcing it, then report applicable discrepancies rather than silently ignoring them. Preserve continuing past recoverable damaged members, but return nonzero whenever bytes/members are lost or completeness is uncertain. `--no-verify` must affect fork CRC only.
- **Verification:** Test every header/payload truncation boundary, missing final members, unrecoverable tail CRC damage, valid empty archives, wrong secondary signature, declared lengths shorter/longer than the physical file, count semantics for nested folders, appended valid-looking entries, and successful resync. Check diagnostics and exit codes in list, extraction, quiet, and no-verify modes.

### RA6X-007 — Resynchronization trusts a 16-bit CRC without structural plausibility

- **Severity:** High
- **Status:** Confirmed by executable reproduction.
- **Location:** `Sources/unsit/SITArchive.swift:75–79, 94–102, 133–150`.
- **Problem:** Any 112-byte block whose first 110 bytes match the last two is accepted as a member header. A CRC match in damaged/compressed data is not enough to establish a boundary. Bogus lengths are then used to jump over genuine later entries; empty names, impossible name lengths, and contradictory folder markers are accepted. This undermines the repository's central promise of recovering members after damage.
- **Evidence:** A block of 112 zero bytes is accepted as an empty-name file because its CRC is zero. A 17-byte gap followed by a CRC-valid header with name length 255, method 255, and compressed length 10,000 is selected as the recovered member; a genuine `good` entry after it is never visited. List mode exits 0. No name, kind, or payload-bound check participates in `isValidHeader`.
- **Fix specification:** Separate checksum checking from a structural candidate validator. During recovery require a plausible name field, coherent marker/flag interpretation, and checked payload bounds within the selected archive extent; reject impossible candidates and keep scanning. Use next-boundary/folder consistency as corroborating evidence where available, and explicitly report ambiguous recovery rather than declaring it trustworthy. Do not filter out every unsupported compression method: a real unsupported member still has to be identified, diagnosed, and skipped by its validated extent so later supported members remain reachable. Preserve valid empty end-marker names if the format permits them.
- **Verification:** Place zero-filled blocks and CRC-valid but impossible headers before real members. Assert the real members are recovered, false candidates do not control offsets or paths, unsupported real members are still reported, and valid folder markers remain recognized. Include malformed lengths near EOF and random damaged spans with deterministic seeds.

### RA6X-008 — Recovery retains an untrustworthy folder stack and misplaces files

- **Severity:** High
- **Status:** Confirmed by executable reproduction.
- **Location:** `Sources/unsit/main.swift:102–124, 178–195`; `Sources/unsit/SITArchive.swift:130–152`.
- **Problem:** A damaged folder start/end marker can disappear during resync, but the caller keeps using its old stack as though hierarchy were intact. Missing end markers put later root files inside an earlier folder; missing starts flatten children. Extra end markers are silently clamped at root and unclosed folders are never diagnosed. This corrupts the recovered directory layout and can combine with name collisions to lose bytes.
- **Evidence:** Start `dir`, file `inside`, an end `dir` header with one CRC bit flipped, then root file `root_file`. Extraction skips the bad end marker and writes `out/dir/root_file`, exits 0, and issues only a skipped-bytes warning. An unclosed folder and an extra root-level end marker also complete without a structure warning. List mode mirrors the wrong hierarchy.
- **Fix specification:** Make hierarchy state and uncertainty explicit across parser and extraction/list consumers. Detect unmatched starts/ends. After a resync that could omit structural records, do not assign later files to the prior path without corroboration; use validated parent information if supported, otherwise place uncertain recoveries in a clearly reported collision-safe recovery directory keyed by offsets. Keep intact archive hierarchy and continue recovering independently identifiable files. Do not “fix” this merely by resetting depth to zero: that guesses a different potentially wrong path. Integrate with RA6X-003, RA6X-006, and RA6X-007.
- **Verification:** Damage a start, an end, and multiple nested markers independently; include identically named members in different folders. Verify no uncertain member is silently attached to a trusted directory, no outputs overwrite one another, unbalanced archives return nonzero, and list/extraction agree on recovery status and paths.

## Summary and suggested fix order (checkpoint)

| Severity | Count | Findings |
|---|---:|---|
| Critical | 0 | None |
| High | 8 | RA6X-001–RA6X-008 |
| Medium | 0 | None recorded in this checkpoint |
| Low | 0 | None recorded in this checkpoint |
| **Total** | **8** | |

Suggested initial dependency order: confine output paths (RA6X-001, RA6X-002), preserve colliding/existing files (RA6X-003), make compressed EOF and lengths explicit (RA6X-004, RA6X-005), establish trustworthy traversal outcomes and candidate bounds (RA6X-006, RA6X-007), then repair hierarchy recovery (RA6X-008). Later checkpoints will extend this order for the remaining findings.
